import AppKit
import SwiftUI

@main
struct AgentHubApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        MenuBarExtra("AgentHub", systemImage: "point.3.connected.trianglepath.dotted") {
            MenuBarContent()
                .environment(stores: delegate.stores)
        }
    }
}

/// Every store, created once. Views get them through the environment, never build their own.
@MainActor
final class Stores {
    let servers = ServerStore()
    let usage = UsageStore()
    let sessions = SessionStore()
    let accounts = AccountsStore()
    let loginItem = LoginItemStore()
    let navigation = NavigationStore()
    let notch = NotchStore()

    /// Store events that reach other stores: sessions and limits become notch alerts, opening the notch
    /// re-reads limits.
    func connect() {
        sessions.onEvent = { [notch] event in
            if case .resumed(let id) = event {
                notch.resolve(IslandAlert.waitingID(id))
            } else if let alert = IslandAlert(event) {
                notch.show(alert)
            }
        }
        usage.onLimitCrossed = { [notch] usage, window in
            notch.show(IslandAlert(limit: usage, window: window))
        }
        notch.onExpand = { [usage] in
            Task { await usage.refresh(ifOlderThan: 30) }
        }
    }
}

extension View {
    func environment(stores: Stores) -> some View {
        environment(stores.servers)
            .environment(stores.usage)
            .environment(stores.sessions)
            .environment(stores.accounts)
            .environment(stores.loginItem)
            .environment(stores.navigation)
            .environment(stores.notch)
    }
}

/// The composition root. Runs in the background: the notch panel and the menu bar are the way in,
/// the main window opens on demand.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let stores = Stores()
    private var notch: NotchController?
    private var mainWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        stores.connect()
        stores.loginItem.enableOnFirstInstalledLaunch()
        stores.navigation.presentMainWindow = { [weak self] in self?.showMainWindow() }
        let stores = self.stores
        notch = NotchController(store: stores.notch) { onSize in
            NotchPanelView(onSize: onSize).environment(stores: stores)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        stores.navigation.openMain()
        return false
    }

    private func showMainWindow() {
        notch?.dismiss()
        let window = mainWindow ?? makeMainWindow()
        mainWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func makeMainWindow() -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: MainView().environment(stores: stores)))
        window.title = "AgentHub"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.setContentSize(NSSize(width: 920, height: 560))
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("AgentHubMain")
        window.center()
        return window
    }
}
