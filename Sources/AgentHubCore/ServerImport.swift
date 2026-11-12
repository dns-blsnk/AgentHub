import Foundation

/// A server as it is written in one agent's config, with its key values.
public struct FoundServer: Sendable, Equatable {
    public var server: MCPServer
    public var values: [String: String]

    public init(server: MCPServer, values: [String: String]) {
        self.server = server
        self.values = values
    }

    /// Same command or URL and same keys with the same values; the id and agents don't matter.
    public func sameDefinition(as other: FoundServer) -> Bool {
        server.transport == other.server.transport
            && server.command == other.server.command
            && server.args == other.server.args
            && server.url == other.server.url
            && values == other.values
    }

    /// Arguments that look like they carry a secret (`--api-key=…`, `--token …`), which then sits in plain text.
    public var secretLikeArguments: [String] {
        let markers = ["key", "token", "secret", "password", "auth"]
        var flagged: [String] = []
        for (index, arg) in server.args.enumerated() {
            let lower = arg.lowercased()
            guard lower.hasPrefix("-"), markers.contains(where: lower.contains) else { continue }
            if let equals = arg.firstIndex(of: "=") {
                if arg.index(after: equals) < arg.endIndex { flagged.append(String(arg[..<equals])) }
            } else if index + 1 < server.args.count, !server.args[index + 1].hasPrefix("-") {
                flagged.append(arg)
            }
        }
        return flagged
    }
}

/// All agents' servers that share one name. Agents can disagree on the definition, so each distinct
/// definition is a variant; only one becomes the registry entry, the agents with other variants stay untouched.
public struct ImportCandidate: Identifiable, Sendable {
    public struct Variant: Sendable {
        public var found: FoundServer
        public var agents: [AgentID]
    }

    public var name: String
    public var variants: [Variant]
    public var id: String { name }

    /// The variant most agents agree on; on a tie, the one from the agent listed first.
    public var suggestedVariant: Int {
        variants.indices.max {
            variants[$0].agents.count < variants[$1].agents.count || (variants[$0].agents.count == variants[$1].agents.count && $0 > $1)
        } ?? 0
    }

    /// The registry entry for `variant`: AgentHub takes ownership of exactly the agents that have that definition.
    public func server(variant: Int) -> (server: MCPServer, values: [String: String]) {
        let chosen = variants[variant]
        var server = chosen.found.server
        server.id = UUID()
        server.agents = Set(chosen.agents)
        server.appliedAgents = Set(chosen.agents)
        return (server, chosen.found.values)
    }
}

public enum ServerImport {
    /// Groups what each agent has by name, in agent order. Names the registry already uses are left out:
    /// those servers are AgentHub's own, or would clash with them.
    public static func candidates(found: [(agent: AgentID, servers: [FoundServer])], existingNames: Set<String>) -> [ImportCandidate] {
        var byName: [String: ImportCandidate] = [:]
        var order: [String] = []
        for (agent, servers) in found {
            for item in servers where !existingNames.contains(item.server.name) && MCPServer.isValidName(item.server.name) {
                let name = item.server.name
                var candidate = byName[name] ?? ImportCandidate(name: name, variants: [])
                if byName[name] == nil { order.append(name) }
                if let index = candidate.variants.firstIndex(where: { $0.found.sameDefinition(as: item) }) {
                    candidate.variants[index].agents.append(agent)
                } else {
                    candidate.variants.append(.init(found: item, agents: [agent]))
                }
                byName[name] = candidate
            }
        }
        return order.compactMap { byName[$0] }
    }
}
