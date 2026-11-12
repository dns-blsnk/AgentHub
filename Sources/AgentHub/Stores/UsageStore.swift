import AgentHubCore
import Foundation
import Observation

/// Limits of every agent that reports them, re-read every few minutes while the app runs.
@MainActor
@Observable
final class UsageStore {
    var usages: [AgentUsage] = []
    var loading = false
    var lastRefresh: Date?

    /// Event: a limit window crossed `alertThreshold` between two reads.
    @ObservationIgnored var onLimitCrossed: (AgentUsage, UsageWindow) -> Void = { _, _ in }
    static let alertThreshold = 0.8

    /// The sources are rate-limited services; once every five minutes is plenty for a menu bar glance.
    private static let interval: Duration = .seconds(300)
    private var isPreview = false

    init() {
        Task {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: Self.interval)
            }
        }
    }

    private init(preview: Void) {
        isPreview = true
        let now = Date()
        usages = [
            AgentUsage(
                id: .claude, name: "Claude", plan: "pro",
                windows: [
                    UsageWindow(id: "s", label: "5-hour session", usedFraction: 0.14, resetsAt: now.addingTimeInterval(2 * 3600)),
                    UsageWindow(id: "w", label: "Week, all models", usedFraction: 0.47, resetsAt: now.addingTimeInterval(3 * 86_400)),
                    UsageWindow(id: "f", label: "Week, Fable", usedFraction: 0.92, resetsAt: now.addingTimeInterval(3 * 86_400)),
                ]),
            AgentUsage(
                id: .codex, name: "Codex", plan: "API key",
                note: "Signed in with an API key: billed per token, no plan limits. Sign in with ChatGPT to see them."),
            AgentUsage(
                id: .antigravity, name: "Antigravity", plan: "free-tier", account: "me@example.com",
                windows: [
                    UsageWindow(
                        id: "c", label: "Claude Sonnet 4.6 (Thinking)", usedFraction: 0, resetsAt: now.addingTimeInterval(7 * 86_400)),
                    UsageWindow(id: "g", label: "Gemini Pro / Flash", usedFraction: 1, resetsAt: now.addingTimeInterval(5 * 86_400)),
                ]),
        ]
        lastRefresh = now
    }

    static func preview() -> UsageStore { UsageStore(preview: ()) }

    /// Used when the notch panel opens: fresh numbers, without hitting the services on every quick hover.
    func refresh(ifOlderThan seconds: TimeInterval) async {
        if let lastRefresh, Date().timeIntervalSince(lastRefresh) < seconds { return }
        await refresh()
    }

    func refresh() async {
        guard !isPreview, !loading else { return }
        loading = true
        let fresh = await Task.detached { await UsageReader(runner: CommandRunner.detect()).readAll() }.value
        // The first read only sets the baseline, so launching near a limit doesn't alert every time.
        if lastRefresh != nil { reportCrossings(from: usages, to: fresh) }
        usages = fresh
        lastRefresh = Date()
        loading = false
    }

    private func reportCrossings(from old: [AgentUsage], to new: [AgentUsage]) {
        for usage in new {
            let before = old.first { $0.id == usage.id }
            for window in usage.windows {
                guard let used = window.usedFraction, used >= Self.alertThreshold else { continue }
                let previous = before?.windows.first { $0.id == window.id }?.usedFraction ?? 0
                if previous < Self.alertThreshold { onLimitCrossed(usage, window) }
            }
        }
    }
}
