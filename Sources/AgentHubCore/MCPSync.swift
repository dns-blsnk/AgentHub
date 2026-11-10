import Foundation

public enum SyncOutcome: Sendable, Equatable {
    case applied
    case removed
    case failed(String)
}

/// Brings every agent's config in line with one registry entry.
public struct MCPSync: Sendable {
    public let adapters: [any AgentAdapter]
    public let snapshots: SnapshotStore

    public init(adapters: [any AgentAdapter], snapshots: SnapshotStore) {
        self.adapters = adapters
        self.snapshots = snapshots
    }

    /// Writes `server` to the agents in `server.agents` and removes it from agents AgentHub wrote it to before.
    /// `previousName` handles renames. The returned `appliedAgents` reflects what actually succeeded.
    public func apply(_ server: MCPServer, token: String?, previousName: String? = nil) -> (appliedAgents: Set<AgentID>, outcomes: [AgentID: SyncOutcome]) {
        let session = snapshots.makeSession()
        snapshots.prune(keeping: 100)
        var applied = server.appliedAgents
        var outcomes: [AgentID: SyncOutcome] = [:]

        for adapter in adapters where adapter.isInstalled() {
            let wanted = server.agents.contains(adapter.id)
            let wasApplied = server.appliedAgents.contains(adapter.id)
            let renamed = previousName != nil && previousName != server.name
            guard wanted || wasApplied else { continue }

            do {
                try snapshots.save(adapter.configURL, agent: adapter.id, in: session)
                if wasApplied && renamed, let previousName {
                    try removeIfPresent(previousName, from: adapter)
                }
                if wanted {
                    try adapter.upsert(server, token: token)
                    applied.insert(adapter.id)
                    outcomes[adapter.id] = .applied
                } else {
                    if !renamed { try removeIfPresent(server.name, from: adapter) }
                    applied.remove(adapter.id)
                    outcomes[adapter.id] = .removed
                }
            } catch {
                outcomes[adapter.id] = .failed(error.localizedDescription)
            }
        }
        return (applied, outcomes)
    }

    /// A server the user already deleted by hand is not an error.
    private func removeIfPresent(_ name: String, from adapter: any AgentAdapter) throws {
        if try adapter.serverNames().contains(name) {
            try adapter.remove(name: name)
        }
    }

    /// Removes the server from every agent AgentHub wrote it to.
    public func removeEverywhere(_ server: MCPServer) -> (appliedAgents: Set<AgentID>, outcomes: [AgentID: SyncOutcome]) {
        var target = server
        target.agents = []
        return apply(target, token: nil)
    }
}
