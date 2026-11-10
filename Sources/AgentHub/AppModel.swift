import AgentHubCore
import Foundation
import Observation

struct AgentStatus: Identifiable, Sendable {
    let id: AgentID
    let name: String
    let installed: Bool
    let configPath: String
    let serverNames: [String]
    let error: String?
}

@MainActor
@Observable
final class AppModel {
    var servers: [MCPServer] = []
    var agents: [AgentStatus] = []
    /// Last sync errors per server and agent; cleared on the next successful sync.
    var errors: [UUID: [AgentID: String]] = [:]
    var busy = false
    var message: String?

    private let registry = RegistryStore(url: AppPaths.registry)
    private let keychain = KeychainStore(service: "dev.agenthub.mcp")
    private var sync: MCPSync?
    private var isPreview = false

    init() {
        servers = registry.load()
        Task { await refreshAgents() }
    }

    /// Sample data for Xcode previews. `sync` stays nil, so nothing is ever written to agents or the Keychain.
    private init(preview: Void) {
        isPreview = true
        servers = [
            MCPServer(name: "github", transport: .stdio, command: "npx", args: ["-y", "@modelcontextprotocol/server-github"],
                      secretKey: "GITHUB_TOKEN", agents: [.claude, .codex, .antigravity], appliedAgents: [.claude, .codex, .antigravity]),
            MCPServer(name: "sentry", transport: .http, url: "https://mcp.sentry.dev/mcp",
                      secretKey: "Authorization", agents: [.claude, .cursor], appliedAgents: [.claude]),
        ]
        agents = [
            AgentStatus(id: .claude, name: "Claude Code", installed: true, configPath: "~/.claude.json", serverNames: ["github", "sentry"], error: nil),
            AgentStatus(id: .codex, name: "Codex", installed: true, configPath: "~/.codex/config.toml", serverNames: ["github"], error: nil),
            AgentStatus(id: .antigravity, name: "Antigravity", installed: true, configPath: "~/.gemini/config/mcp_config.json", serverNames: ["github"], error: nil),
            AgentStatus(id: .gemini, name: "Gemini CLI", installed: false, configPath: "~/.gemini/settings.json", serverNames: [], error: nil),
            AgentStatus(id: .cursor, name: "Cursor", installed: true, configPath: "~/.cursor/mcp.json", serverNames: [], error: nil),
        ]
        errors = [servers[1].id: [.cursor: "Sample error: ~/.cursor/mcp.json is not plain JSON"]]
    }

    static func preview() -> AppModel { AppModel(preview: ()) }

    var installedAgents: [AgentStatus] { agents.filter(\.installed) }

    func refreshAgents() async {
        guard !isPreview else { return }
        let (sync, statuses) = await Task.detached {
            let runner = CommandRunner.detect()
            let adapters = Agents.all(runner: runner)
            let statuses = adapters.map { adapter -> AgentStatus in
                let installed = adapter.isInstalled()
                var names: [String] = []
                var readError: String?
                if installed {
                    do { names = try adapter.serverNames() } catch { readError = error.localizedDescription }
                }
                return AgentStatus(
                    id: adapter.id,
                    name: adapter.displayName,
                    installed: installed,
                    configPath: adapter.configURL.path.replacingOccurrences(of: runner.home.path, with: "~"),
                    serverNames: names,
                    error: readError
                )
            }
            return (MCPSync(adapters: adapters, snapshots: SnapshotStore(root: AppPaths.snapshots)), statuses)
        }.value
        self.sync = sync
        self.agents = statuses
    }

    func hasToken(_ server: MCPServer) -> Bool {
        keychain.get(server.id.uuidString) != nil
    }

    /// Saves a new or edited server and pushes it to its agents. An empty `token` keeps the stored one.
    func save(_ server: MCPServer, token: String) async {
        guard !isPreview else { return }
        let previousName = servers.first(where: { $0.id == server.id })?.name
        if !token.isEmpty {
            do {
                try keychain.set(token, account: server.id.uuidString)
            } catch {
                message = "Keychain: \(error.localizedDescription)"
                return
            }
        }
        if let index = servers.firstIndex(where: { $0.id == server.id }) {
            servers[index] = server
        } else {
            servers.append(server)
        }
        await push(server, previousName: previousName)
    }

    func setAgent(_ agent: AgentID, enabled: Bool, for server: MCPServer) async {
        var updated = server
        if enabled { updated.agents.insert(agent) } else { updated.agents.remove(agent) }
        guard let index = servers.firstIndex(where: { $0.id == server.id }) else { return }
        servers[index] = updated
        await push(updated, previousName: server.name)
    }

    func delete(_ server: MCPServer) async {
        guard let sync = await readySync() else { return }
        busy = true
        let result = await Task.detached { sync.removeEverywhere(server) }.value
        busy = false
        let failures = failuresByAgent(result.outcomes)
        if failures.isEmpty {
            keychain.delete(server.id.uuidString)
            servers.removeAll { $0.id == server.id }
            errors[server.id] = nil
        } else if let index = servers.firstIndex(where: { $0.id == server.id }) {
            // Record the agents it did leave, so a retry never touches a same-named server added there later.
            servers[index].appliedAgents = result.appliedAgents
            servers[index].agents = result.appliedAgents
            errors[server.id] = failures
            message = "\(server.name) wasn't removed everywhere, see the marked agents."
        }
        persist()
        await refreshAgents()
    }

    /// Agent detection runs in the background on launch; an action that comes earlier waits for it
    /// instead of being dropped after the server was already changed in memory.
    private func readySync() async -> MCPSync? {
        if sync == nil && !isPreview { await refreshAgents() }
        return sync
    }

    private func push(_ server: MCPServer, previousName: String?) async {
        guard let sync = await readySync() else {
            persist()
            return
        }
        busy = true
        let token = keychain.get(server.id.uuidString)
        let result = await Task.detached { sync.apply(server, token: token, previousName: previousName) }.value
        busy = false
        if let index = servers.firstIndex(where: { $0.id == server.id }) {
            servers[index].appliedAgents = result.appliedAgents
        }
        let failures = failuresByAgent(result.outcomes)
        errors[server.id] = failures.isEmpty ? nil : failures
        message = failures.isEmpty ? nil : "\(server.name): \(failures.count) agent(s) failed, hover the ⚠︎ for details."
        persist()
        await refreshAgents()
    }

    private func failuresByAgent(_ outcomes: [AgentID: SyncOutcome]) -> [AgentID: String] {
        outcomes.compactMapValues { outcome in
            if case .failed(let reason) = outcome { return reason }
            return nil
        }
    }

    private func persist() {
        do {
            try registry.save(servers)
        } catch {
            message = "Couldn't save the registry: \(error.localizedDescription)"
        }
    }
}
