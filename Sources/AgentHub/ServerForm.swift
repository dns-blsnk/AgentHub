import AgentHubCore
import SwiftUI

/// Add or edit one MCP server: name, how to reach it, any number of keys, and which agents get it.
struct ServerForm: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let original: MCPServer?

    @State private var name = ""
    @State private var transport = Transport.stdio
    @State private var commandLine = ""
    @State private var url = ""
    @State private var keyRows: [KeyRow] = []
    @State private var agents: Set<AgentID> = []
    @State private var saving = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $name, prompt: Text("github"))
                    if !name.isEmpty && !MCPServer.isValidName(name) {
                        Text("Letters, digits, - and _ only.")
                            .font(.caption).foregroundStyle(.red)
                    } else if nameTaken {
                        Text("Another server in AgentHub already uses this name.")
                            .font(.caption).foregroundStyle(.red)
                    }
                    Picker("Type", selection: $transport) {
                        Text("Local command").tag(Transport.stdio)
                        Text("Remote URL").tag(Transport.http)
                    }
                    .pickerStyle(.segmented)
                    if transport == .stdio {
                        TextField("Command", text: $commandLine, prompt: Text("npx -y @modelcontextprotocol/server-github"))
                    } else {
                        TextField("URL", text: $url, prompt: Text("https://example.com/mcp"))
                    }
                }

                Section {
                    ForEach($keyRows) { $row in
                        KeyRowEditor(row: $row, transport: transport, duplicate: isDuplicate(row)) {
                            keyRows.removeAll { $0.id == row.id }
                        }
                    }
                    Button {
                        keyRows.append(KeyRow())
                    } label: {
                        Label(transport == .stdio ? "Add Variable" : "Add Header", systemImage: "plus")
                    }
                    .buttonStyle(.borderless)
                } header: {
                    Text(transport == .stdio ? "Environment variables" : "Headers")
                } footer: {
                    Text("Values are kept in the macOS Keychain and written into the config of every agent below, since agents read them from there. A change here reaches all of them on Save.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    ForEach(model.agents) { agent in
                        VStack(alignment: .leading, spacing: 2) {
                            Toggle(agent.name, isOn: Binding(
                                get: { agents.contains(agent.id) },
                                set: { if $0 { agents.insert(agent.id) } else { agents.remove(agent.id) } }
                            ))
                            .disabled(!agent.installed || !agent.supports(transport))
                            if !agent.installed {
                                Text("Not installed").font(.caption).foregroundStyle(.secondary)
                            } else if !agent.supports(transport) {
                                Text("Can't run \(transport == .http ? "remote" : "local") servers").font(.caption).foregroundStyle(.secondary)
                            } else if overwrites(agent) {
                                Text("\(agent.name) already has a server named \"\(name)\"; it will be replaced.")
                                    .font(.caption).foregroundStyle(.orange)
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text("Agents")
                        Spacer()
                        Button("All") { agents = Set(model.installedAgents.filter { $0.supports(transport) }.map(\.id)) }
                        Button("None") { agents = [] }
                    }
                    .buttonStyle(.borderless)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                if saving {
                    ProgressView().controlSize(.small)
                    Text("Applying…").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(original == nil ? "Add" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid || saving)
            }
            .padding(14)
        }
        .frame(width: 560, height: 660)
        .onAppear(perform: load)
    }

    private var nameTaken: Bool {
        model.servers.contains { $0.name == name && $0.id != original?.id }
    }

    private var isValid: Bool {
        guard MCPServer.isValidName(name), !nameTaken else { return false }
        if keyRows.contains(where: { $0.trimmedName.isEmpty && !$0.value.isEmpty }) { return false }
        if keyRows.contains(where: { !MCPServer.isValidValue($0.value) }) { return false }
        for row in filledRows where !MCPServer.isValidKey(row.trimmedName) || isDuplicate(row) { return false }
        switch transport {
        case .stdio: return !CommandLineParser.split(commandLine).isEmpty
        case .http: return URL(string: url)?.scheme?.hasPrefix("http") == true
        }
    }

    /// Rows with a key name; fully empty rows are ignored.
    private var filledRows: [KeyRow] { keyRows.filter { !$0.trimmedName.isEmpty } }

    private func isDuplicate(_ row: KeyRow) -> Bool {
        !row.trimmedName.isEmpty && keyRows.contains { $0.id != row.id && $0.trimmedName == row.trimmedName }
    }

    /// The agent already has this name and AgentHub didn't put it there.
    private func overwrites(_ agent: AgentStatus) -> Bool {
        agents.contains(agent.id) && agent.supports(transport)
            && agent.serverNames.contains(name)
            && !(original?.name == name && original?.appliedAgents.contains(agent.id) == true)
    }

    private func load() {
        guard let original else {
            // New servers go to every installed agent; untick the ones that shouldn't get it.
            agents = Set(model.installedAgents.map(\.id))
            keyRows = [KeyRow()]
            return
        }
        name = original.name
        transport = original.transport
        commandLine = CommandLineParser.join([original.command] + original.args)
        url = original.url
        let values = model.keyValues(for: original)
        keyRows = original.keys.map { KeyRow(name: $0, value: values[$0] ?? "") }
        if keyRows.isEmpty { keyRows = [KeyRow()] }
        agents = original.agents
    }

    private func save() {
        let argv = CommandLineParser.split(commandLine)
        var server = original ?? MCPServer(name: name, transport: transport)
        server.name = name
        server.transport = transport
        server.command = transport == .stdio ? argv.first ?? "" : ""
        server.args = transport == .stdio ? Array(argv.dropFirst()) : []
        server.url = transport == .http ? url.trimmingCharacters(in: .whitespaces) : ""
        server.keys = filledRows.map(\.trimmedName)
        server.agents = agents.filter { id in model.agents.first { $0.id == id }?.supports(transport) ?? false }
        let values = Dictionary(
            filledRows.map { ($0.trimmedName, $0.value.trimmingCharacters(in: .whitespacesAndNewlines)) },
            uniquingKeysWith: { _, last in last }
        )
        saving = true
        Task {
            await model.save(server, values: values)
            saving = false
            dismiss()
        }
    }
}

struct KeyRow: Identifiable {
    let id = UUID()
    var name = ""
    var value = ""

    var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }
}

/// One key: name, value (hidden unless revealed) and a remove button.
private struct KeyRowEditor: View {
    @Binding var row: KeyRow
    let transport: Transport
    let duplicate: Bool
    let remove: () -> Void
    @State private var revealed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                TextField("Key", text: $row.name, prompt: Text(transport == .stdio ? "FIGMA_API_KEY" : "Authorization"))
                    .labelsHidden()
                    .font(.body.monospaced())
                    .frame(width: 180)
                Group {
                    if revealed {
                        TextField("Value", text: $row.value, prompt: Text(valuePrompt))
                    } else {
                        SecureField("Value", text: $row.value, prompt: Text(valuePrompt))
                    }
                }
                .labelsHidden()
                Button { revealed.toggle() } label: {
                    Image(systemName: revealed ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
                .help(revealed ? "Hide value" : "Show value")
                Button(action: remove) {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help("Remove key")
            }
            if let problem {
                Text(problem).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private var valuePrompt: String { transport == .http ? "Bearer …" : "Value" }

    private var problem: String? {
        let name = row.trimmedName
        if !MCPServer.isValidValue(row.value) { return "Values can't contain line breaks." }
        if name.isEmpty { return row.value.isEmpty ? nil : "Give the value a key name." }
        if !MCPServer.isValidKey(name) { return "No spaces, = or : in key names." }
        if duplicate { return "This key is already listed." }
        return nil
    }
}

#Preview {
    ServerForm(original: nil)
        .environment(AppModel.preview())
}
