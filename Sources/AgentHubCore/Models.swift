import Foundation

public enum AgentID: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case claude, codex, antigravity, gemini, cursor

    public var id: String { rawValue }
}

public enum Transport: String, Codable, CaseIterable, Hashable, Sendable {
    /// A local process the agent starts (`command` + `args`).
    case stdio
    /// A remote streamable HTTP endpoint (`url`).
    case http
}

/// One MCP server in the AgentHub registry. The token itself is never stored here, only in the Keychain.
public struct MCPServer: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var transport: Transport
    public var command: String
    public var args: [String]
    public var url: String
    /// Env variable name for stdio servers, header name for http servers. Empty means no secret.
    public var secretKey: String
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
        secretKey: String = "",
        agents: Set<AgentID> = [],
        appliedAgents: Set<AgentID> = []
    ) {
        self.id = id
        self.name = name
        self.transport = transport
        self.command = command
        self.args = args
        self.url = url
        self.secretKey = secretKey
        self.agents = agents
        self.appliedAgents = appliedAgents
    }

    /// Names end up as TOML bare keys and CLI arguments, so keep them to a safe charset.
    public static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    /// The secret as key/value, or nil when the server has none.
    public func secret(token: String?) -> (key: String, value: String)? {
        guard !secretKey.isEmpty, let token, !token.isEmpty else { return nil }
        return (secretKey, token)
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
