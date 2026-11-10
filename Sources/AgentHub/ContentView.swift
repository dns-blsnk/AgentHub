import AgentHubCore
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var editing: MCPServer?
    @State private var adding = false
    @State private var deleting: MCPServer?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            AgentStrip()
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            Divider()
            if model.servers.isEmpty {
                ContentUnavailableView {
                    Label("No MCP servers yet", systemImage: "point.3.connected.trianglepath.dotted")
                } description: {
                    Text("Add a server once and AgentHub writes it into every agent you pick.")
                } actions: {
                    Button("Add MCP Server") { adding = true }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                ScrollView {
                    ServerGrid(editing: $editing, deleting: $deleting)
                        .padding(16)
                }
            }
            if let message = model.message {
                Divider()
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(message).textSelection(.enabled)
                    Spacer()
                    Button("Dismiss") { model.message = nil }
                }
                .font(.callout)
                .padding(10)
            }
        }
        .toolbar {
            ToolbarItem {
                if model.busy { ProgressView().controlSize(.small) }
            }
            ToolbarItem {
                Button { Task { await model.refreshAgents() } } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Re-detect agents and re-read their configs")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { adding = true } label: {
                    Label("Add MCP Server", systemImage: "plus")
                }
                .keyboardShortcut("n")
            }
        }
        .sheet(isPresented: $adding) {
            ServerForm(original: nil)
        }
        .sheet(item: $editing) { server in
            ServerForm(original: server)
        }
        .confirmationDialog(
            "Remove \(deleting?.name ?? "")?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            presenting: deleting
        ) { server in
            Button("Remove from all agents", role: .destructive) {
                Task { await model.delete(server) }
            }
        } message: { _ in
            Text("It is removed from every agent AgentHub added it to, and its token is deleted from the Keychain.")
        }
    }
}

/// Detected agents with their config file paths.
private struct AgentStrip: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 14) {
            ForEach(model.agents) { agent in
                HStack(spacing: 5) {
                    Circle()
                        .fill(agent.error != nil ? .orange : agent.installed ? .green : .secondary.opacity(0.4))
                        .frame(width: 7, height: 7)
                    Text(agent.name)
                        .foregroundStyle(agent.installed ? .primary : .secondary)
                }
                .font(.callout)
                .help(agent.error ?? (agent.installed ? "\(agent.configPath) · \(agent.serverNames.count) server(s)" : "Not installed"))
            }
            if model.agents.isEmpty {
                ProgressView().controlSize(.small)
                Text("Detecting agents…").foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

/// Servers as rows, agents as checkbox columns.
private struct ServerGrid: View {
    @Environment(AppModel.self) private var model
    @Binding var editing: MCPServer?
    @Binding var deleting: MCPServer?

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 12) {
            GridRow {
                Text("Server")
                ForEach(model.agents) { agent in
                    Text(agent.name)
                        .gridColumnAlignment(.center)
                        .foregroundStyle(agent.installed ? .secondary : .tertiary)
                }
                Text("")
            }
            .font(.caption)
            Divider()
            ForEach(model.servers) { server in
                GridRow {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(server.name).fontWeight(.medium)
                        Text(subtitle(server))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .frame(maxWidth: 280, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { editing = server }

                    ForEach(model.agents) { agent in
                        AgentCell(server: server, agent: agent)
                    }

                    Menu {
                        Button("Edit…") { editing = server }
                        Button("Remove…", role: .destructive) { deleting = server }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
        }
        .disabled(model.busy)
    }

    private func subtitle(_ server: MCPServer) -> String {
        let target = server.transport == .stdio
            ? CommandLineParser.join([server.command] + server.args)
            : server.url
        return server.secretKey.isEmpty ? target : "\(target) · \(server.secretKey)"
    }
}

private struct AgentCell: View {
    @Environment(AppModel.self) private var model
    let server: MCPServer
    let agent: AgentStatus

    var body: some View {
        let error = model.errors[server.id]?[agent.id]
        HStack(spacing: 3) {
            Toggle("", isOn: Binding(
                get: { server.agents.contains(agent.id) },
                set: { enabled in Task { await model.setAgent(agent.id, enabled: enabled, for: server) } }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()
            .disabled(!agent.installed)
            if let error {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help(error)
            }
        }
        .gridColumnAlignment(.center)
        .help(agent.installed ? "" : "\(agent.name) is not installed")
    }
}

#Preview {
    ContentView()
        .environment(AppModel.preview())
        .frame(width: 820, height: 460)
}
