import AgentHubCore
import SwiftUI

/// Width of one agent checkbox column; the server column takes the rest.
private let agentColumnWidth: CGFloat = 86

struct ServersView: View {
    @Environment(ServerStore.self) private var store
    @Environment(NavigationStore.self) private var navigation
    @State private var editing: MCPServer?
    @State private var adding = false
    @State private var deleting: MCPServer?
    @State private var importing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Header(adding: $adding, importing: $importing)
                .padding(16)
            Divider()

            if store.servers.isEmpty {
                ContentUnavailableView {
                    Label("No MCP servers yet", systemImage: "point.3.connected.trianglepath.dotted")
                } description: {
                    Text(
                        """
                        Import the servers your agents already have, or add one with any keys it needs, \
                        and AgentHub keeps it in every agent you pick.
                        """
                    )
                } actions: {
                    HStack {
                        Button("Import from Agents…") { importing = true }
                            .buttonStyle(.borderedProminent)
                        Button("Add MCP Server…") { adding = true }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ServerTable(editing: $editing, deleting: $deleting)
            }

            if let message = store.message {
                Divider()
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(message).textSelection(.enabled)
                    Spacer()
                    Button("Dismiss") { store.message = nil }
                }
                .font(.callout)
                .padding(10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // "+ MCP" in the notch panel opens the window with the form.
        .onChange(of: navigation.addServerRequested, initial: true) { _, requested in
            guard requested else { return }
            navigation.addServerRequested = false
            adding = true
        }
        .sheet(isPresented: $adding) {
            ServerForm(original: nil)
        }
        .sheet(item: $editing) { server in
            ServerForm(original: server)
        }
        .sheet(isPresented: $importing) {
            ImportSheet()
        }
        .confirmationDialog(
            "Remove \(deleting?.name ?? "")?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            presenting: deleting
        ) { server in
            Button("Remove from all agents", role: .destructive) {
                Task { await store.delete(server) }
            }
        } message: { _ in
            Text("It is removed from every agent AgentHub added it to, and its key values are deleted from the Keychain.")
        }
    }
}

/// Title, detected agents and the actions.
private struct Header: View {
    @Environment(ServerStore.self) private var store
    @Binding var adding: Bool
    @Binding var importing: Bool

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text("MCP servers").font(.headline)
                AgentStrip()
            }
            Spacer()
            if store.busy { ProgressView().controlSize(.small) }
            Button {
                Task { await store.refreshAgents() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Re-detect agents and re-read their configs")
            Button("Import…") { importing = true }
                .help("Adopt servers that are already in agent configs")
            Button("Add Server…") { adding = true }
                .keyboardShortcut("n")
        }
    }
}

/// Detected agents with their config file paths on hover.
private struct AgentStrip: View {
    @Environment(ServerStore.self) private var store

    var body: some View {
        HStack(spacing: 12) {
            ForEach(store.agents) { agent in
                HStack(spacing: 5) {
                    Circle()
                        .fill(agent.error != nil ? .orange : agent.installed ? .green : .secondary.opacity(0.4))
                        .frame(width: 7, height: 7)
                    Text(agent.name)
                        .foregroundStyle(agent.installed ? .secondary : .tertiary)
                }
                .help(agent.error ?? (agent.installed ? stripHelp(agent) : "Not installed"))
            }
            if store.agents.isEmpty {
                ProgressView().controlSize(.mini)
                Text("Detecting agents…").foregroundStyle(.secondary)
            }
        }
        .font(.callout)
    }

    private func stripHelp(_ agent: AgentStatus) -> String {
        var text = "\(agent.configPath) · \(agent.serverNames.count) global server(s)"
        if !agent.projectServers.isEmpty { text += ", \(agent.projectServers.count) more in project scope" }
        return text
    }
}

/// Servers as rows, agents as checkbox columns: each server is on exactly for the agents ticked in its row.
private struct ServerTable: View {
    @Environment(ServerStore.self) private var store
    @Binding var editing: MCPServer?
    @Binding var deleting: MCPServer?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("Server")
                    .frame(maxWidth: .infinity, alignment: .leading)
                ForEach(store.agents) { agent in
                    Text(agent.name)
                        .lineLimit(1)
                        .frame(width: agentColumnWidth)
                        .foregroundStyle(agent.installed ? .secondary : .tertiary)
                }
                Color.clear.frame(width: 28, height: 1)
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(store.servers) { server in
                        ServerRow(server: server, editing: $editing, deleting: $deleting)
                        Divider().padding(.leading, 16)
                    }
                }
            }
        }
        .disabled(store.busy)
    }
}

private struct ServerRow: View {
    @Environment(ServerStore.self) private var store
    let server: MCPServer
    @Binding var editing: MCPServer?
    @Binding var deleting: MCPServer?
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(server.name).fontWeight(.medium)
                HStack(spacing: 4) {
                    Image(systemName: server.transport == .stdio ? "terminal" : "globe")
                    Text(target)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if !server.keys.isEmpty {
                    KeyChips(keys: server.keys)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 12)

            ForEach(store.agents) { agent in
                AgentCell(server: server, agent: agent)
                    .frame(width: agentColumnWidth)
            }

            Menu {
                actions
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 28)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(hovering ? Color.primary.opacity(0.04) : .clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { editing = server }
        .contextMenu { actions }
    }

    @ViewBuilder private var actions: some View {
        Button("Edit…") { editing = server }
        Divider()
        Button("Enable for All Agents") { Task { await store.setAllAgents(enabled: true, for: server) } }
        Button("Disable for All Agents") { Task { await store.setAllAgents(enabled: false, for: server) } }
        Divider()
        Button("Remove…", role: .destructive) { deleting = server }
    }

    private var target: String {
        server.transport == .stdio ? CommandLineParser.join([server.command] + server.args) : server.url
    }
}

/// Key names only; values never leave the Keychain for display.
private struct KeyChips: View {
    let keys: [String]

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "key").foregroundStyle(.secondary)
            ForEach(keys.prefix(4), id: \.self) { key in
                Text(key)
                    .font(.caption2.monospaced())
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
            }
            if keys.count > 4 {
                Text("+\(keys.count - 4)").foregroundStyle(.secondary)
            }
        }
        .font(.caption2)
        .lineLimit(1)
    }
}

private struct AgentCell: View {
    @Environment(ServerStore.self) private var store
    let server: MCPServer
    let agent: AgentStatus
    @State private var confirmingOverwrite = false

    var body: some View {
        let error = store.errors[server.id]?[agent.id]
        HStack(spacing: 3) {
            Toggle(
                "",
                isOn: Binding(
                    get: { server.agents.contains(agent.id) },
                    set: { enabled in
                        if enabled && overwritesForeignEntry {
                            confirmingOverwrite = true
                        } else {
                            Task { await store.setAgent(agent.id, enabled: enabled, for: server) }
                        }
                    }
                )
            )
            .toggleStyle(.checkbox)
            .labelsHidden()
            .disabled(!agent.installed || !supported)
            if let error {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help(error)
            } else if let projects = agent.projectServers[server.name] {
                Image(systemName: "folder.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(projectHelp(projects))
            }
        }
        .opacity(supported ? 1 : 0.4)
        .confirmationDialog(
            "Replace \(server.name) in \(agent.name)?",
            isPresented: $confirmingOverwrite
        ) {
            Button("Replace", role: .destructive) {
                Task { await store.setAgent(agent.id, enabled: true, for: server) }
            }
        } message: {
            Text(
                "\(agent.name) already has a server named \"\(server.name)\" that AgentHub didn't add. It will be replaced with AgentHub's definition; a snapshot of the config is kept."
            )
        }
        .help(
            !agent.installed
                ? "\(agent.name) is not installed"
                : !supported
                    ? "\(agent.name) can't run \(server.transport == .http ? "remote" : "local") servers"
                    : "\(server.name) in \(agent.name)")
    }

    /// The agent has an entry with this name that AgentHub didn't write (hand-made or another tool's).
    private var overwritesForeignEntry: Bool {
        agent.serverNames.contains(server.name) && !server.appliedAgents.contains(agent.id)
    }

    private func projectHelp(_ projects: [String]) -> String {
        let names = projects.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
        return
            "Also in \(agent.name) project scope: \(names). AgentHub manages user scope only and leaves project files alone; the checkbox makes \(server.name) global."
    }

    private var supported: Bool {
        agent.supports(server.transport) || server.agents.contains(agent.id)
    }
}

#Preview {
    ServersView()
        .environment(ServerStore.preview())
        .environment(NavigationStore())
        .frame(width: 860, height: 460)
}
