import AppKit
import SwiftUI

@main
struct AgentHubApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        MenuBarExtra("AgentHub", systemImage: "point.3.connected.trianglepath.dotted") {
            MenuBarContent(openMain: { delegate.showMain() })
                .environment(delegate.loginItem)
                .environment(delegate.model)
                .environment(delegate.accounts)
                .environment(delegate.usage)
        }
    }
}

/// Which tab the main window shows, and a request to open the "Add MCP Server" form from outside it.
@MainActor
@Observable
final class WindowState {
    enum Tab: Hashable { case servers, usage, antigravity }
    var tab = Tab.servers
    var addServerRequested = false
}

/// Runs in the background: the notch panel and the menu bar are the way in, the main window opens on demand.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    let accounts = AccountsModel()
    let usage = UsageModel()
    let windowState = WindowState()
    let loginItem = LoginItem()
    private var notch: NotchController?
    private var mainWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        loginItem.enableOnFirstInstalledLaunch()
        notch = NotchController(usage: usage, accounts: accounts, actions: NotchActions(
            openMain: { [weak self] in self?.showMain() },
            addServer: { [weak self] in self?.showMain(addingServer: true) }
        ))
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMain()
        return false
    }

    func showMain(addingServer: Bool = false) {
        notch?.dismiss()
        if addingServer {
            windowState.tab = .servers
            windowState.addServerRequested = true
        }
        let window = mainWindow ?? makeMainWindow()
        mainWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func makeMainWindow() -> NSWindow {
        let root = MainView()
            .environment(model)
            .environment(accounts)
            .environment(usage)
            .environment(windowState)
        let window = NSWindow(contentViewController: NSHostingController(rootView: root))
        window.title = "AgentHub"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.setContentSize(NSSize(width: 920, height: 560))
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("AgentHubMain")
        window.center()
        return window
    }
}

struct MainView: View {
    @Environment(WindowState.self) private var windowState

    var body: some View {
        @Bindable var windowState = windowState
        TabView(selection: $windowState.tab) {
            Tab("MCP Servers", systemImage: "point.3.connected.trianglepath.dotted", value: WindowState.Tab.servers) {
                ContentView()
            }
            Tab("Usage", systemImage: "gauge.with.dots.needle.50percent", value: WindowState.Tab.usage) {
                UsageView()
            }
            Tab("Antigravity", systemImage: "person.2.circle", value: WindowState.Tab.antigravity) {
                AccountsView()
            }
        }
        .frame(minWidth: 860, minHeight: 480)
    }
}

private struct MenuBarContent: View {
    let openMain: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(AccountsModel.self) private var accounts
    @Environment(UsageModel.self) private var usage
    @Environment(LoginItem.self) private var loginItem

    var body: some View {
        Button("Open AgentHub", action: openMain)
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
        Toggle("Launch at Login", isOn: Binding(get: { loginItem.enabled }, set: { loginItem.set($0) }))
        if let message = loginItem.message {
            Text(message)
        }
        Button("Quit AgentHub") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

