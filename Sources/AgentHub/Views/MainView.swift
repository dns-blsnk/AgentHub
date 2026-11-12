import SwiftUI

/// The main window: one tab per area, each reading its store.
struct MainView: View {
    @Environment(NavigationStore.self) private var navigation

    var body: some View {
        @Bindable var navigation = navigation
        TabView(selection: $navigation.tab) {
            Tab("MCP Servers", systemImage: "point.3.connected.trianglepath.dotted", value: NavigationStore.Tab.servers) {
                ServersView()
            }
            Tab("Usage", systemImage: "gauge.with.dots.needle.50percent", value: NavigationStore.Tab.usage) {
                UsageView()
            }
            Tab("Accounts", systemImage: "person.2.circle", value: NavigationStore.Tab.accounts) {
                AccountsView()
            }
        }
        .frame(minWidth: 860, minHeight: 480)
    }
}
