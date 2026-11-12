import AgentHubCore
import XCTest

@testable import AgentHub

final class TokenFormattingTests: XCTestCase {
    func testCompactSwitchesUnitWhereRoundingWould() {
        XCTAssertEqual(TokenUsage.compact(950), "950")
        XCTAssertEqual(TokenUsage.compact(12_400), "12.4K")
        XCTAssertEqual(TokenUsage.compact(999_949), "999.9K")
        XCTAssertEqual(TokenUsage.compact(999_960), "1.0M")
        XCTAssertEqual(TokenUsage.compact(31_236_351), "31.2M")
    }

    func testSummaryLeavesOutCacheWhenThereIsNone() {
        XCTAssertEqual(TokenUsage(input: 2_000, output: 500).summary, "2.5K tokens · 500 out")
        XCTAssertEqual(TokenUsage(input: 2_000, cachedInput: 1_500, output: 500).summary, "2.5K tokens · 1.5K cached · 500 out")
    }
}

final class UsageDisplayTests: XCTestCase {
    func testRemainingSourcesShowWhatsLeft() {
        let window = UsageWindow(id: "m", label: "M", usedFraction: 0.25, resetsAt: nil)
        XCTAssertEqual(window.shownFraction(remaining: false), 0.25)
        XCTAssertEqual(window.shownFraction(remaining: true), 0.75)
        XCTAssertNil(UsageWindow(id: "m", label: "M", usedFraction: nil, resetsAt: nil).shownFraction(remaining: true))
    }

    @MainActor
    func testMenuBarSummary() {
        let claude = AgentUsage(
            id: .claude, name: "Claude",
            windows: [
                UsageWindow(id: "s", label: "5-hour session", usedFraction: 0.14, resetsAt: nil),
                UsageWindow(id: "w", label: "Week, all models", usedFraction: 0.47, resetsAt: nil),
            ])
        XCTAssertEqual(MenuBarContent.summary(claude), "Claude: 5h 14% · week 47%")

        let antigravity = AgentUsage(
            id: .antigravity, name: "Antigravity", reportsRemaining: true,
            windows: [UsageWindow(id: "g", label: "Gemini", usedFraction: 0.1, resetsAt: nil)])
        XCTAssertEqual(MenuBarContent.summary(antigravity), "Antigravity: Gemini 90% left")

        // An API key sign-in: tokens only, and nothing at all before the first reply of the day.
        var codex = AgentUsage(id: .codex, name: "Codex", tokensToday: TokenUsage(input: 1_200_000, output: 300_000))
        XCTAssertEqual(MenuBarContent.summary(codex), "Codex: today 1.5M tokens")
        codex.tokensToday = TokenUsage()
        XCTAssertNil(MenuBarContent.summary(codex))
    }
}

@MainActor
final class NotchAlertTests: XCTestCase {
    private let session = AgentSession(agent: .claude, pid: 42, cwd: "/w/app", name: "fix-login", state: .idle)

    func testSessionEventsBecomeAlerts() throws {
        let waiting = try XCTUnwrap(IslandAlert(.waiting(session, reason: "permission")))
        XCTAssertEqual(waiting.kind, .waiting)
        XCTAssertTrue(waiting.persistent)
        XCTAssertEqual(waiting.title, "Claude needs permission")
        XCTAssertEqual(waiting.pid, 42)

        let finished = try XCTUnwrap(IslandAlert(.finished(session)))
        XCTAssertFalse(finished.persistent)
        XCTAssertNil(IslandAlert(.resumed(sessionID: session.id)))
    }

    func testResolvingShowsTheNextPendingAlert() throws {
        let store = NotchStore()
        let first = try XCTUnwrap(IslandAlert(.waiting(session, reason: nil)))
        let other = AgentSession(agent: .codex, pid: 7, cwd: "/w/api", state: .idle)
        let second = try XCTUnwrap(IslandAlert(.waiting(other, reason: nil)))
        store.show(first)
        store.show(second)
        XCTAssertEqual(store.alert?.id, second.id)
        XCTAssertTrue(store.isVisible)

        store.resolve(second.id)
        XCTAssertEqual(store.alert?.id, first.id)
        store.resolve(IslandAlert.waitingID(session.id))
        XCTAssertNil(store.alert)
        XCTAssertFalse(store.isVisible)
    }

    func testExpandingAsksForFreshLimitsOnce() {
        let store = NotchStore()
        var expansions = 0
        store.onExpand = { expansions += 1 }
        store.expand()
        store.expand()
        XCTAssertEqual(expansions, 1)
        store.collapse()
        store.expand()
        XCTAssertEqual(expansions, 2)
    }
}
