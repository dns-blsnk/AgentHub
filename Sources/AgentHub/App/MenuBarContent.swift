import AgentHubCore
import AppKit
import SwiftUI

/// The menu bar item: a second way in next to the notch.
struct MenuBarContent: View {
    @Environment(ServerStore.self) private var servers
    @Environment(UsageStore.self) private var usage
    @Environment(AccountsStore.self) private var accounts
    @Environment(LoginItemStore.self) private var loginItem
    @Environment(NavigationStore.self) private var navigation

    var body: some View {
        Button("Open AgentHub") { navigation.openMain() }
            .keyboardShortcut("o")
        Text("\(servers.servers.count) MCP server(s), \(servers.installedAgents.count) agent(s)")

        let summaries = usage.usages.compactMap(Self.summary)
        if !summaries.isEmpty {
            Divider()
            Section("Usage") {
                ForEach(summaries, id: \.self) { Text($0) }
                Button("Refresh Usage") { Task { await usage.refresh() } }
                    .disabled(usage.loading)
            }
        }

        ForEach(accounts.switchable) { agent in
            Divider()
            Section("\(agent.name) account") {
                AccountToggles(agent: agent)
            }
        }

        Divider()
        Toggle("Launch at Login", isOn: Binding(get: { loginItem.enabled }, set: { loginItem.set($0) }))
        if let message = loginItem.message {
            Text(message)
        }
        Button("Quit AgentHub") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    /// "Claude: 5h 14% · week 47%" from the first two windows.
    static func summary(_ usage: AgentUsage) -> String? {
        let parts = usage.windows.prefix(2).compactMap { window -> String? in
            guard let used = window.usedFraction else { return nil }
            let label: String
            switch window.label {
            case "5-hour session", "5-hour window": label = "5h"
            case "Week, all models", "Week": label = "week"
            default: label = window.label
            }
            return usage.reportsRemaining
                ? "\(label) \(Int(((1 - used) * 100).rounded()))% left"
                : "\(label) \(Int((used * 100).rounded()))%"
        }
        if parts.isEmpty, let tokens = usage.tokensToday {
            return "\(usage.name): today \(TokenUsage.compact(tokens.total)) tokens"
        }
        return parts.isEmpty ? nil : "\(usage.name): " + parts.joined(separator: " · ")
    }
}
