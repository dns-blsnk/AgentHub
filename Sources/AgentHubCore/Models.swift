import Foundation

public enum AgentID: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case claude, codex, antigravity, gemini, cursor, claudeDesktop

    public var id: String { rawValue }
}

public enum Transport: String, Codable, CaseIterable, Hashable, Sendable {
    /// A local process the agent starts (`command` + `args`).
    case stdio
    /// A remote streamable HTTP endpoint (`url`).
    case http
}

/// One MCP server in the AgentHub registry. Key values are never stored here, only in the Keychain.
public struct MCPServer: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var transport: Transport
    public var command: String
    public var args: [String]
    public var url: String
    /// Env variable names for stdio servers, header names for http servers, in the order they are written.
    public var keys: [String]
    /// Agents the user wants this server in.
    public var agents: Set<AgentID>
    /// Agents AgentHub has actually written this server to. Only these are ever removed,
    /// so a same-named server the user added by hand is never deleted.
    public var appliedAgents: Set<AgentID>

    public init(
        id: UUID = UUID(),
        name: String,
        transport: Transport,
        command: String = "",
        args: [String] = [],
        url: String = "",
        keys: [String] = [],
        agents: Set<AgentID> = [],
        appliedAgents: Set<AgentID> = []
    ) {
        self.id = id
        self.name = name
        self.transport = transport
        self.command = command
        self.args = args
        self.url = url
        self.keys = keys
        self.agents = agents
        self.appliedAgents = appliedAgents
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, transport, command, args, url, keys, agents, appliedAgents
    }

    /// v0.1 registries had a single `secretKey`.
    private enum LegacyKeys: String, CodingKey {
        case secretKey
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        transport = try container.decode(Transport.self, forKey: .transport)
        command = try container.decode(String.self, forKey: .command)
        args = try container.decode([String].self, forKey: .args)
        url = try container.decode(String.self, forKey: .url)
        agents = try container.decode(Set<AgentID>.self, forKey: .agents)
        appliedAgents = try container.decode(Set<AgentID>.self, forKey: .appliedAgents)
        if let keys = try container.decodeIfPresent([String].self, forKey: .keys) {
            self.keys = keys
        } else {
            let legacy = try decoder.container(keyedBy: LegacyKeys.self)
            let key = try legacy.decodeIfPresent(String.self, forKey: .secretKey) ?? ""
            keys = key.isEmpty ? [] : [key]
        }
    }

    /// Names end up as TOML bare keys and CLI arguments, so keep them to a safe charset.
    public static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    /// Env variable / header names: no spaces, `=` or `:`, which would break `KEY=value` and `Key: value` arguments.
    public static func isValidKey(_ key: String) -> Bool {
        !key.isEmpty && key.allSatisfy { $0.isASCII && !$0.isWhitespace && $0 != "=" && $0 != ":" && !$0.isNewline }
    }

    /// A value becomes one header line or env entry; a line break would smuggle in another one.
    public static func isValidValue(_ value: String) -> Bool {
        !value.contains(where: { $0.isNewline || $0 == "\0" })
    }

    /// The keys that have a value, in order. Keys without a value are left out of agent configs.
    public func keyValues(_ values: [String: String]) -> [(key: String, value: String)] {
        keys.compactMap { key in
            guard let value = values[key], !value.isEmpty, Self.isValidValue(value) else { return nil }
            return (key, value)
        }
    }

    /// `keyValues` as a dictionary, for JSON configs.
    public func keyDictionary(_ values: [String: String]) -> [String: String]? {
        let pairs = keyValues(values)
        return pairs.isEmpty ? nil : Dictionary(pairs, uniquingKeysWith: { _, last in last })
    }
}

public enum AgentError: LocalizedError {
    case toolNotFound(String)
    case unreadableConfig(URL, String)

    public var errorDescription: String? {
        switch self {
        case .toolNotFound(let tool):
            return "`\(tool)` not found in PATH"
        case .unreadableConfig(let url, let reason):
            return "Can't read \(url.path): \(reason)"
        }
    }
}
