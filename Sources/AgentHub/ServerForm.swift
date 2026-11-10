import AgentHubCore
import SwiftUI

/// Add or edit one MCP server: name, how to reach it, one secret, and which agents get it.
struct ServerForm: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let original: MCPServer?

    @State private var name = ""
    @State private var transport = Transport.stdio
    @State private var commandLine = ""
    @State private var url = ""
    @State private var secretKey = ""
    @State private var token = ""
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
                    TextField(
                        transport == .stdio ? "Env variable" : "Header",
                        text: $secretKey,
                        prompt: Text(transport == .stdio ? "GITHUB_TOKEN" : "Authorization")
                    )
                    SecureField("Token", text: $token, prompt: Text(tokenPrompt))
                } header: {
                    Text("Key")
                } footer: {
                    Text("The token is kept in the macOS Keychain and written into each agent's config, since agents read it from there.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Agents") {
                    ForEach(model.agents) { agent in
                        VStack(alignment: .leading, spacing: 2) {
                            Toggle(agent.name, isOn: Binding(
                                get: { agents.contains(agent.id) },
                                set: { if $0 { agents.insert(agent.id) } else { agents.remove(agent.id) } }
                            ))
                            .disabled(!agent.installed)
                            if !agent.installed {
                                Text("Not installed").font(.caption).foregroundStyle(.secondary)
                            } else if overwrites(agent) {
                                Text("\(agent.name) already has a server named \"\(name)\"; it will be replaced.")
                                    .font(.caption).foregroundStyle(.orange)
                            }
                        }
                    }
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
        .frame(width: 520, height: 600)
        .onAppear(perform: load)
    }

    private var tokenPrompt: String {
        if let original, model.hasToken(original) { return "Unchanged" }
        return transport == .http ? "Bearer …" : "Optional"
    }

    private var nameTaken: Bool {
        model.servers.contains { $0.name == name && $0.id != original?.id }
    }

    private var isValid: Bool {
        guard MCPServer.isValidName(name), !nameTaken else { return false }
        switch transport {
        case .stdio: return !CommandLineParser.split(commandLine).isEmpty
        case .http: return URL(string: url)?.scheme?.hasPrefix("http") == true
        }
    }

    /// The agent already has this name and AgentHub didn't put it there.
    private func overwrites(_ agent: AgentStatus) -> Bool {
        agents.contains(agent.id)
            && agent.serverNames.contains(name)
            && !(original?.name == name && original?.appliedAgents.contains(agent.id) == true)
    }

    private func load() {
        guard let original else {
            // New servers go to every installed agent; untick the ones that shouldn't get it.
            agents = Set(model.installedAgents.map(\.id))
            return
        }
        name = original.name
        transport = original.transport
        commandLine = CommandLineParser.join([original.command] + original.args)
        url = original.url
        secretKey = original.secretKey
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
        server.secretKey = secretKey.trimmingCharacters(in: .whitespaces)
        server.agents = agents
        saving = true
        Task {
            await model.save(server, token: token.trimmingCharacters(in: .whitespacesAndNewlines))
            saving = false
            dismiss()
        }
    }
}

#Preview {
    ServerForm(original: nil)
        .environment(AppModel.preview())
}
