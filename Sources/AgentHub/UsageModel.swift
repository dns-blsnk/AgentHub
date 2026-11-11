import AgentHubCore
import Foundation
import Observation

/// Limits of every agent that reports them, re-read every few minutes while the app runs.
@MainActor
@Observable
final class UsageModel {
    var usages: [AgentUsage] = []
    var loading = false
    var lastRefresh: Date?

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
            AgentUsage(id: .claude, name: "Claude", plan: "pro", windows: [
                UsageWindow(id: "s", label: "5-hour session", usedFraction: 0.14, resetsAt: now.addingTimeInterval(2 * 3600)),
                UsageWindow(id: "w", label: "Week, all models", usedFraction: 0.47, resetsAt: now.addingTimeInterval(3 * 86_400)),
                UsageWindow(id: "f", label: "Week, Fable", usedFraction: 0.92, resetsAt: now.addingTimeInterval(3 * 86_400)),
            ]),
            AgentUsage(id: .codex, name: "Codex", plan: "API key",
                       note: "Signed in with an API key: billed per token, no plan limits. Sign in with ChatGPT to see them."),
            AgentUsage(id: .antigravity, name: "Antigravity", plan: "free-tier", account: "me@example.com", windows: [
                UsageWindow(id: "c", label: "Claude Sonnet 4.6 (Thinking)", usedFraction: 0, resetsAt: now.addingTimeInterval(7 * 86_400)),
                UsageWindow(id: "g", label: "Gemini Pro / Flash", usedFraction: 1, resetsAt: now.addingTimeInterval(5 * 86_400)),
            ]),
        ]
        lastRefresh = now
    }

    static func preview() -> UsageModel { UsageModel(preview: ()) }

    func refresh() async {
        guard !isPreview, !loading else { return }
        loading = true
        usages = await Task.detached { await UsageReader(runner: CommandRunner.detect()).readAll() }.value
        lastRefresh = Date()
        loading = false
    }

    /// Short text for the menu bar, e.g. "Claude 5h 14% · week 47%".
    func summary(for usage: AgentUsage) -> String? {
        let parts = usage.windows.prefix(2).compactMap { window -> String? in
            guard let used = window.usedFraction else { return nil }
            return "\(Self.shortLabel(window.label)) \(Int((used * 100).rounded()))%"
        }
        return parts.isEmpty ? nil : "\(usage.name): " + parts.joined(separator: " · ")
    }

    private static func shortLabel(_ label: String) -> String {
        switch label {
        case "5-hour session", "5-hour window": return "5h"
        case "Week, all models", "Week": return "week"
        default: return label
        }
    }
}
