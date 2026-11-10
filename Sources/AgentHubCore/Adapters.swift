import Foundation

/// Knows where one agent keeps its global MCP servers and how to change them safely.
public protocol AgentAdapter: Sendable {
    var id: AgentID { get }
    var displayName: String { get }
    /// The file that changes on write; it is snapshotted before every change.
    var configURL: URL { get }
    func isInstalled() -> Bool
    func serverNames() throws -> [String]
    func upsert(_ server: MCPServer, token: String?) throws
    func remove(name: String) throws
}

public enum Agents {
    public static func all(runner: CommandRunner) -> [any AgentAdapter] {
        [
            ClaudeAdapter(runner: runner),
            CodexAdapter(runner: runner),
            AntigravityAdapter(runner: runner),
            GeminiAdapter(runner: runner),
            CursorAdapter(runner: runner),
        ]
    }
}

// MARK: - Claude Code

/// User-scope servers live in `~/.claude.json`, a big state file Claude Code rewrites constantly,
/// so all writes go through `claude mcp`.
public struct ClaudeAdapter: AgentAdapter {
    public let runner: CommandRunner
    public let id = AgentID.claude
    public let displayName = "Claude Code"
    public var configURL: URL { runner.home.appendingPathComponent(".claude.json") }

    public func isInstalled() -> Bool { runner.which("claude") != nil }

    public func serverNames() throws -> [String] { try JSONConfigFile.serverNames(configURL) }

    public func upsert(_ server: MCPServer, token: String?) throws {
        // `claude mcp add` refuses to overwrite an existing name, so the old entry is removed first
        // and put back if the new one is rejected.
        let servers = try JSONConfigFile.load(configURL)["mcpServers"] as? [String: Any] ?? [:]
        let previous = servers[server.name]
        if previous != nil {
            try runner.run("claude", ["mcp", "remove", "-s", "user", server.name])
        }
        do {
            try runner.run("claude", Self.addArguments(server, token: token), secrets: [token ?? ""])
        } catch {
            if let previous, let data = try? JSONSerialization.data(withJSONObject: previous),
               let json = String(data: data, encoding: .utf8) {
                _ = try? runner.run("claude", ["mcp", "add-json", "-s", "user", server.name, json], secrets: [json])
            }
            throw error
        }
    }

    public func remove(name: String) throws {
        try runner.run("claude", ["mcp", "remove", "-s", "user", name])
    }

    /// `-e` and `-H` are variadic, so they go after the name, never right before it.
    public static func addArguments(_ server: MCPServer, token: String?) -> [String] {
        let secret = server.secret(token: token)
        switch server.transport {
        case .stdio:
            var args = ["mcp", "add", "-s", "user", server.name]
            if let secret { args += ["-e", "\(secret.key)=\(secret.value)"] }
            return args + ["--", server.command] + server.args
        case .http:
            var args = ["mcp", "add", "-s", "user", "-t", "http", server.name, server.url]
            if let secret { args += ["-H", "\(secret.key): \(secret.value)"] }
            return args
        }
    }
}

// MARK: - Codex

/// `codex mcp add` can't set HTTP headers, so `config.toml` is edited directly, touching only the server's tables.
public struct CodexAdapter: AgentAdapter {
    public let runner: CommandRunner
    public let id = AgentID.codex
    public let displayName = "Codex"
    public var configURL: URL { runner.home.appendingPathComponent(".codex/config.toml") }

    public func isInstalled() -> Bool {
        runner.which("codex") != nil || FileManager.default.fileExists(atPath: configURL.path)
    }

    public func serverNames() throws -> [String] { CodexTOML.serverNames(in: try read()) }

    public func upsert(_ server: MCPServer, token: String?) throws {
        try write(CodexTOML.upserting(server, token: token, in: try read()))
    }

    public func remove(name: String) throws {
        try write(CodexTOML.removing(name, from: try read()))
    }

    private func read() throws -> String {
        guard FileManager.default.fileExists(atPath: configURL.path) else { return "" }
        return try String(contentsOf: configURL, encoding: .utf8)
    }

    private func write(_ text: String) throws {
        try ConfigFileWriter.write(Data(text.utf8), to: configURL)
    }
}

// MARK: - Antigravity

/// IDE and `agy` CLI share `~/.gemini/config/mcp_config.json`; writes go through `agy mcp`,
/// which knows the exact schema (it differs from other agents for remote servers).
public struct AntigravityAdapter: AgentAdapter {
    public let runner: CommandRunner
    public let id = AgentID.antigravity
    public let displayName = "Antigravity"
    public var configURL: URL { runner.home.appendingPathComponent(".gemini/config/mcp_config.json") }

    public func isInstalled() -> Bool { runner.which("agy") != nil }

    public func serverNames() throws -> [String] { try JSONConfigFile.serverNames(configURL) }

    public func upsert(_ server: MCPServer, token: String?) throws {
        try runner.run("agy", Self.addArguments(server, token: token), secrets: [token ?? ""])
    }

    public func remove(name: String) throws {
        try runner.run("agy", ["mcp", "remove", name])
    }

    /// `agy` rejects flags placed after the name. `agy mcp add` also updates an existing server.
    public static func addArguments(_ server: MCPServer, token: String?) -> [String] {
        let secret = server.secret(token: token)
        switch server.transport {
        case .stdio:
            var args = ["mcp", "add"]
            if let secret { args += ["--env", "\(secret.key)=\(secret.value)"] }
            return args + [server.name, "--", server.command] + server.args
        case .http:
            var args = ["mcp", "add", "--type", "http"]
            if let secret { args += ["--header", "\(secret.key): \(secret.value)"] }
            return args + [server.name, server.url]
        }
    }
}

// MARK: - Gemini CLI

/// `~/.gemini/settings.json` → `mcpServers`. Not verified against a live install yet.
public struct GeminiAdapter: AgentAdapter {
    public let runner: CommandRunner
    public let id = AgentID.gemini
    public let displayName = "Gemini CLI"
    public var configURL: URL { runner.home.appendingPathComponent(".gemini/settings.json") }

    // `~/.gemini` alone proves nothing: Antigravity creates it too.
    public func isInstalled() -> Bool {
        runner.which("gemini") != nil || FileManager.default.fileExists(atPath: configURL.path)
    }

    public func serverNames() throws -> [String] { try JSONConfigFile.serverNames(configURL) }

    public func upsert(_ server: MCPServer, token: String?) throws {
        try JSONConfigFile.setServer(server.name, entry: Self.entry(server, token: token), in: configURL)
    }

    public func remove(name: String) throws {
        try JSONConfigFile.setServer(name, entry: nil, in: configURL)
    }

    static func entry(_ server: MCPServer, token: String?) -> [String: Any] {
        let secret = server.secret(token: token)
        switch server.transport {
        case .stdio:
            var entry: [String: Any] = ["command": server.command, "args": server.args]
            if let secret { entry["env"] = [secret.key: secret.value] }
            return entry
        case .http:
            // `httpUrl` is streamable HTTP; plain `url` would mean SSE.
            var entry: [String: Any] = ["httpUrl": server.url]
            if let secret { entry["headers"] = [secret.key: secret.value] }
            return entry
        }
    }
}

// MARK: - Cursor

/// `~/.cursor/mcp.json` → `mcpServers`; Cursor has no CLI for this.
public struct CursorAdapter: AgentAdapter {
    public let runner: CommandRunner
    public let id = AgentID.cursor
    public let displayName = "Cursor"
    public var configURL: URL { runner.home.appendingPathComponent(".cursor/mcp.json") }

    public func isInstalled() -> Bool {
        FileManager.default.fileExists(atPath: runner.home.appendingPathComponent(".cursor").path)
            || FileManager.default.fileExists(atPath: "/Applications/Cursor.app")
    }

    public func serverNames() throws -> [String] { try JSONConfigFile.serverNames(configURL) }

    public func upsert(_ server: MCPServer, token: String?) throws {
        try JSONConfigFile.setServer(server.name, entry: Self.entry(server, token: token), in: configURL)
    }

    public func remove(name: String) throws {
        try JSONConfigFile.setServer(name, entry: nil, in: configURL)
    }

    static func entry(_ server: MCPServer, token: String?) -> [String: Any] {
        let secret = server.secret(token: token)
        switch server.transport {
        case .stdio:
            var entry: [String: Any] = ["command": server.command, "args": server.args]
            if let secret { entry["env"] = [secret.key: secret.value] }
            return entry
        case .http:
            var entry: [String: Any] = ["url": server.url]
            if let secret { entry["headers"] = [secret.key: secret.value] }
            return entry
        }
    }
}
