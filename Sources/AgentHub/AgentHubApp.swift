import AppKit
import SwiftUI

@main
struct AgentHubApp: App {
    @State private var model = AppModel()
    @State private var accounts = AccountsModel()

    var body: some Scene {
        Window("AgentHub", id: "main") {
            TabView {
                Tab("MCP Servers", systemImage: "point.3.connected.trianglepath.dotted") {
                    ContentView()
                }
                Tab("Antigravity", systemImage: "person.2.circle") {
                    AccountsView()
                }
            }
            .environment(model)
            .environment(accounts)
            .frame(minWidth: 860, minHeight: 480)
        }
        // A menu bar app gets no window by default; open it on launch so changes are visible right away.
        .defaultLaunchBehavior(.presented)

        MenuBarExtra("AgentHub", systemImage: "point.3.connected.trianglepath.dotted") {
            MenuBarContent()
                .environment(model)
                .environment(accounts)
        }
    }
}

private struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(AccountsModel.self) private var accounts
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open AgentHub") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut("o")
        Text("\(model.servers.count) MCP server(s), \(model.installedAgents.count) agent(s)")

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
