import Observation

/// Where the user is in the main window, and requests to go somewhere from outside it (the notch, the menu bar).
@MainActor
@Observable
final class NavigationStore {
    enum Tab: Hashable { case servers, usage, accounts }

    var tab = Tab.servers
    /// Set by "+ MCP"; the servers view opens its form and clears it.
    var addServerRequested = false

    /// The window itself is AppKit; the composition root supplies how to bring it up.
    @ObservationIgnored var presentMainWindow: () -> Void = {}

    func openMain(addingServer: Bool = false) {
        if addingServer {
            tab = .servers
            addServerRequested = true
        }
        presentMainWindow()
    }
}
