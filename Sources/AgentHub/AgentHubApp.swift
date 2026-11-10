import AppKit
import SwiftUI

@main
struct AgentHubApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        Window("AgentHub", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 760, minHeight: 440)
        }
        // A menu bar app gets no window by default; open it on launch so changes are visible right away.
        .defaultLaunchBehavior(.presented)

        MenuBarExtra("AgentHub", systemImage: "point.3.connected.trianglepath.dotted") {
            MenuBarContent()
                .environment(model)
        }
    }
}

private struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open AgentHub") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut("o")
        Text("\(model.servers.count) MCP server(s), \(model.installedAgents.count) agent(s)")

        Divider()
        Button("Quit AgentHub") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
