import AgentHubCore
import Foundation
import Observation

/// MCP servers: the registry, what each agent has, and the actions that keep them in sync.
/// The single source of truth for the "MCP Servers" tab, the server form and the import sheet.
@MainActor
@Observable
final class ServerStore {
    var servers: [MCPServer] = []
    var agents: [AgentStatus] = []
    /// Last sync errors per server and agent; cleared on the next successful sync.
    var errors: [UUID: [AgentID: String]] = [:]
    var busy = false
    var message: String?

    private let registry = RegistryStore(url: AppPaths.registry)
    private let keyStore = ServerKeyStore(keychain: KeychainStore(service: "dev.agenthub.mcp"))
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
                      keys: ["GITHUB_TOKEN"], agents: [.claude, .codex, .antigravity], appliedAgents: [.claude, .codex, .antigravity]),
            MCPServer(name: "sentry", transport: .http, url: "https://mcp.sentry.dev/mcp",
                      keys: ["Authorization", "X-Org-Id"], agents: [.claude, .cursor], appliedAgents: [.claude]),
        ]
        agents = [
            AgentStatus(id: .claude, name: "Claude Code", installed: true, configPath: "~/.claude.json", serverNames: ["github"], error: nil,
                        projectServers: ["sentry": ["~/work/app", "~/work/api"]]),
            AgentStatus(id: .codex, name: "Codex", installed: true, configPath: "~/.codex/config.toml", serverNames: ["github"], error: nil),
            AgentStatus(id: .antigravity, name: "Antigravity", installed: true, configPath: "~/.gemini/config/mcp_config.json", serverNames: ["github"], error: nil),
            AgentStatus(id: .gemini, name: "Gemini CLI", installed: false, configPath: "~/.gemini/settings.json", serverNames: [], error: nil),
            AgentStatus(id: .cursor, name: "Cursor", installed: true, configPath: "~/.cursor/mcp.json", serverNames: [], error: nil),
            AgentStatus(id: .claudeDesktop, name: "Claude Desktop", installed: true, configPath: "~/Library/Application Support/Claude/claude_desktop_config.json",
                        serverNames: ["github"], error: nil, supportedTransports: [.stdio]),
        ]
        errors = [servers[1].id: [.cursor: "Sample error: ~/.cursor/mcp.json is not plain JSON"]]
    }

    static func preview() -> ServerStore { ServerStore(preview: ()) }

    var installedAgents: [AgentStatus] { agents.filter(\.installed) }

    func refreshAgents() async {
        guard !isPreview else { return }
        let (sync, statuses) = await Task.detached {
            let (adapters, statuses) = Agents.detect(runner: CommandRunner.detect())
            return (MCPSync(adapters: adapters, snapshots: SnapshotStore(root: AppPaths.snapshots)), statuses)
        }.value
        self.sync = sync
        self.agents = statuses
    }

    func keyValues(for server: MCPServer) -> [String: String] {
        isPreview ? [:] : keyStore.values(for: server)
    }

    /// Saves a new or edited server with all its key values and pushes it to every agent it is enabled for.
    func save(_ server: MCPServer, values: [String: String]) async {
        guard !isPreview else { return }
        let previousName = servers.first(where: { $0.id == server.id })?.name
        do {
            try keyStore.setValues(values, for: server)
        } catch {
            message = "Keychain: \(error.localizedDescription)"
            return
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

    /// Turns the server on for every installed agent, or off everywhere.
    func setAllAgents(enabled: Bool, for server: MCPServer) async {
        var updated = server
        updated.agents = enabled ? Set(installedAgents.filter { $0.supports(server.transport) }.map(\.id)) : []
        guard updated.agents != server.agents, let index = servers.firstIndex(where: { $0.id == server.id }) else { return }
        servers[index] = updated
        await push(updated, previousName: server.name)
    }

    /// Servers already in agent configs that the registry doesn't have yet. Reading only, nothing is written.
    func findImportCandidates() async -> [ImportCandidate] {
        guard !isPreview else { return [] }
        let existing = Set(servers.map(\.name))
        let (candidates, errors) = await Task.detached { () -> ([ImportCandidate], [String]) in
            var found: [(agent: AgentID, servers: [FoundServer])] = []
            var errors: [String] = []
            for adapter in Agents.all(runner: CommandRunner.detect()) where adapter.isInstalled() {
                do {
                    found.append((adapter.id, try adapter.readServers()))
                } catch {
                    errors.append("\(adapter.displayName): \(error.localizedDescription)")
                }
            }
            return (ServerImport.candidates(found: found, existingNames: existing), errors)
        }.value
        if !errors.isEmpty { message = "Couldn't read: " + errors.joined(separator: "; ") }
        return candidates
    }

    /// Adopts the chosen variant of each candidate. The agents already have exactly that definition,
    /// so nothing is written to them; AgentHub only starts managing the entries.
    func importServers(_ picks: [(candidate: ImportCandidate, variant: Int)]) async {
        guard !isPreview else { return }
        var failed: [String] = []
        for pick in picks where !servers.contains(where: { $0.name == pick.candidate.name }) {
            let (server, values) = pick.candidate.server(variant: pick.variant)
            do {
                try keyStore.setValues(values, for: server)
                servers.append(server)
            } catch {
                failed.append("\(server.name): \(error.localizedDescription)")
            }
        }
        if !failed.isEmpty { message = "Keychain: " + failed.joined(separator: "; ") }
        persist()
        await refreshAgents()
    }

    func delete(_ server: MCPServer) async {
        guard let sync = await readySync() else { return }
        busy = true
        let result = await Task.detached { sync.removeEverywhere(server) }.value
        busy = false
        let failures = failuresByAgent(result.outcomes)
        if failures.isEmpty {
            keyStore.delete(server)
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
        let values = keyStore.values(for: server)
        let result = await Task.detached { sync.apply(server, values: values, previousName: previousName) }.value
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
