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
    /// Every server's key values, read from the Keychain once per launch: one access prompt, not one per action.
    @ObservationIgnored private var keyCache: [UUID: [String: String]]?
    private var isPreview = false

    init() {
        servers = registry.load()
        Task { await refreshAgents() }
    }

    /// Sample data for Xcode previews. `sync` stays nil, so nothing is ever written to agents or the Keychain.
    private init(preview: Void) {
        isPreview = true
        servers = [
            MCPServer(
                name: "github", transport: .stdio, command: "npx", args: ["-y", "@modelcontextprotocol/server-github"],
                keys: ["GITHUB_TOKEN"], agents: [.claude, .codex, .antigravity], appliedAgents: [.claude, .codex, .antigravity]),
            MCPServer(
                name: "sentry", transport: .http, url: "https://mcp.sentry.dev/mcp",
                keys: ["Authorization", "X-Org-Id"], agents: [.claude, .cursor], appliedAgents: [.claude]),
        ]
        agents = [
            AgentStatus(
                id: .claude, name: "Claude Code", installed: true, configPath: "~/.claude.json", serverNames: ["github"], error: nil,
                projectServers: ["sentry": ["~/work/app", "~/work/api"]]),
            AgentStatus(
                id: .codex, name: "Codex", installed: true, configPath: "~/.codex/config.toml", serverNames: ["github"], error: nil),
            AgentStatus(
                id: .antigravity, name: "Antigravity", installed: true, configPath: "~/.gemini/config/mcp_config.json",
                serverNames: ["github"], error: nil),
            AgentStatus(
                id: .gemini, name: "Gemini CLI", installed: false, configPath: "~/.gemini/settings.json", serverNames: [], error: nil),
            AgentStatus(id: .cursor, name: "Cursor", installed: true, configPath: "~/.cursor/mcp.json", serverNames: [], error: nil),
            AgentStatus(
                id: .claudeDesktop, name: "Claude Desktop", installed: true,
                configPath: "~/Library/Application Support/Claude/claude_desktop_config.json",
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

    /// nil when the Keychain refused, so the form can tell "no values" from "couldn't read them".
    func keyValues(for server: MCPServer) -> [String: String]? {
        if isPreview || server.keys.isEmpty { return [:] }
        guard let all = try? allKeyValues() else { return nil }
        return all[server.id] ?? [:]
    }

    /// Saves a new or edited server with all its key values and pushes it to every agent it is enabled for.
    func save(_ server: MCPServer, values: [String: String]) async {
        guard !isPreview else { return }
        let previousName = servers.first(where: { $0.id == server.id })?.name
        let own = ServerKeyStore.ownValues(values, for: server)
        let hadKeys = servers.first(where: { $0.id == server.id })?.keys.isEmpty == false
        // A server without keys, before and after, has nothing in the Keychain: no prompt for it.
        if !own.isEmpty || hadKeys {
            do {
                try updateKeyValues { $0[server.id] = own.isEmpty ? nil : own }
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
        await push(updated, previousName: server.name, only: [agent])
    }

    /// Turns the server on for every installed agent, or off everywhere.
    func setAllAgents(enabled: Bool, for server: MCPServer) async {
        var updated = server
        updated.agents = enabled ? Set(installedAgents.filter { $0.supports(server.transport) }.map(\.id)) : []
        guard updated.agents != server.agents, let index = servers.firstIndex(where: { $0.id == server.id }) else { return }
        servers[index] = updated
        await push(updated, previousName: server.name, only: updated.agents.symmetricDifference(server.agents))
    }

    /// Turns one agent on or off for every server it can run, and re-reads the agents once at the end.
    /// Turning on skips servers the agent already has from elsewhere: replacing those needs a confirmation each.
    func setAgentForAllServers(_ agent: AgentID, enabled: Bool) async {
        guard let status = agents.first(where: { $0.id == agent }), status.installed else { return }
        // One Keychain read up front; a refusal stops here instead of asking again for every server.
        if enabled && servers.contains(where: { !$0.keys.isEmpty }) {
            do {
                _ = try allKeyValues()
            } catch {
                message = "Keychain: \(error.localizedDescription)"
                return
            }
        }
        var skipped: [String] = []
        var failed = 0
        for id in servers.map(\.id) {
            guard let server = servers.first(where: { $0.id == id }), server.agents.contains(agent) != enabled else { continue }
            if enabled {
                guard status.supports(server.transport) else { continue }
                if status.serverNames.contains(server.name) && !server.appliedAgents.contains(agent) {
                    skipped.append(server.name)
                    continue
                }
            }
            var updated = server
            if enabled { updated.agents.insert(agent) } else { updated.agents.remove(agent) }
            guard let index = servers.firstIndex(where: { $0.id == id }) else { continue }
            servers[index] = updated
            if await !push(updated, previousName: server.name, only: [agent], refresh: false) { failed += 1 }
        }
        await refreshAgents()
        var notes: [String] = []
        if failed > 0 { notes.append("\(failed) server(s) failed in \(status.name), hover the ⚠︎ for details.") }
        if !skipped.isEmpty {
            notes.append(
                "Skipped \(skipped.joined(separator: ", ")): \(status.name) already has them from elsewhere; tick them one by one to replace."
            )
        }
        message = notes.isEmpty ? nil : notes.joined(separator: " ")
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
        var adopted: [(server: MCPServer, values: [String: String])] = []
        for pick in picks where !servers.contains(where: { $0.name == pick.candidate.name }) {
            let (server, values) = pick.candidate.server(variant: pick.variant)
            adopted.append((server, ServerKeyStore.ownValues(values, for: server)))
        }
        let withValues = adopted.filter { !$0.values.isEmpty }
        // Servers without values never need the Keychain, so a refusal only holds back the ones with values.
        servers += adopted.filter { $0.values.isEmpty }.map(\.server)
        if !withValues.isEmpty {
            do {
                try updateKeyValues { all in
                    for (server, values) in withValues { all[server.id] = values }
                }
                servers += withValues.map(\.server)
            } catch {
                message = "Keychain: \(error.localizedDescription). Not imported: \(withValues.map(\.server.name).joined(separator: ", "))."
            }
        }
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
            do {
                if !server.keys.isEmpty { try updateKeyValues { $0[server.id] = nil } }
            } catch {
                message = "\(server.name) was removed, but its key values stay in the Keychain: \(error.localizedDescription)"
            }
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

    private func allKeyValues() throws -> [UUID: [String: String]] {
        if let keyCache { return keyCache }
        let loaded = try keyStore.loadAll(for: servers)
        keyCache = loaded
        return loaded
    }

    private func updateKeyValues(_ change: (inout [UUID: [String: String]]) -> Void) throws {
        var all = try allKeyValues()
        change(&all)
        try keyStore.saveAll(all)
        keyCache = all
    }

    /// Writes the server to the agents in `only` (all of them when nil). Key values are read only when an agent in
    /// scope gets the server, so turning servers off never touches the Keychain. Returns whether every agent took it.
    @discardableResult
    private func push(_ server: MCPServer, previousName: String?, only: Set<AgentID>? = nil, refresh: Bool = true) async -> Bool {
        guard let sync = await readySync() else {
            persist()
            return false
        }
        let writes = only.map { server.agents.intersection($0) } ?? server.agents
        var values: [String: String] = [:]
        if !writes.isEmpty && !server.keys.isEmpty {
            do {
                values = try allKeyValues()[server.id] ?? [:]
            } catch {
                // Nothing was written: put the checkboxes in scope back to what those agents really have.
                if let index = servers.firstIndex(where: { $0.id == server.id }) {
                    let scope = only ?? Set(AgentID.allCases)
                    servers[index].agents = server.agents.subtracting(scope).union(server.appliedAgents.intersection(scope))
                }
                message = "Keychain: \(error.localizedDescription)"
                persist()
                return false
            }
        }
        busy = true
        let result = await Task.detached { sync.apply(server, values: values, previousName: previousName, only: only) }.value
        busy = false
        if let index = servers.firstIndex(where: { $0.id == server.id }) {
            servers[index].appliedAgents = result.appliedAgents
        }
        let failures = failuresByAgent(result.outcomes)
        // Agents outside `only` weren't tried, so their earlier errors still stand.
        var serverErrors = only.map { scope in (errors[server.id] ?? [:]).filter { !scope.contains($0.key) } } ?? [:]
        serverErrors.merge(failures) { _, new in new }
        errors[server.id] = serverErrors.isEmpty ? nil : serverErrors
        message = failures.isEmpty ? nil : "\(server.name): \(failures.count) agent(s) failed, hover the ⚠︎ for details."
        persist()
        if refresh { await refreshAgents() }
        return failures.isEmpty
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
