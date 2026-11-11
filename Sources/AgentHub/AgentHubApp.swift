import AppKit
import SwiftUI

@main
struct AgentHubApp: App {
    @State private var model = AppModel()
    @State private var accounts = AccountsModel()
    @State private var usage = UsageModel()

    var body: some Scene {
        Window("AgentHub", id: "main") {
            TabView {
                Tab("MCP Servers", systemImage: "point.3.connected.trianglepath.dotted") {
                    ContentView()
                }
                Tab("Usage", systemImage: "gauge.with.dots.needle.50percent") {
                    UsageView()
                }
                Tab("Antigravity", systemImage: "person.2.circle") {
                    AccountsView()
                }
            }
            .environment(model)
            .environment(accounts)
            .environment(usage)
            .frame(minWidth: 860, minHeight: 480)
        }
        // A menu bar app gets no window by default; open it on launch so changes are visible right away.
        .defaultLaunchBehavior(.presented)

        MenuBarExtra("AgentHub", systemImage: "point.3.connected.trianglepath.dotted") {
            MenuBarContent()
                .environment(model)
                .environment(accounts)
                .environment(usage)
        }
    }
}

private struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(AccountsModel.self) private var accounts
    @Environment(UsageModel.self) private var usage
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open AgentHub") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut("o")
        Text("\(model.servers.count) MCP server(s), \(model.installedAgents.count) agent(s)")

        let summaries = usage.usages.compactMap { usage.summary(for: $0) }
        if !summaries.isEmpty {
            Divider()
            Section("Usage") {
                ForEach(summaries, id: \.self) { Text($0) }
                Button("Refresh Usage") { Task { await usage.refresh() } }
                    .disabled(usage.loading)
            }
        }

        if !accounts.accounts.isEmpty {
            Divider()
            Section("Antigravity account") {
                ForEach(accounts.accounts) { account in
                    Toggle(account.email, isOn: Binding(
                        get: { account.email == accounts.activeEmail },
                        set: { if $0 { Task { await accounts.switchTo(account) } } }
                    ))
                    .disabled(accounts.adding)
                }
            }
        }

        Divider()
        Button("Quit AgentHub") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
