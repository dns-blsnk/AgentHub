import Foundation

/// Knows where one agent keeps its global MCP servers and how to change them safely.
public protocol AgentAdapter: Sendable {
    var id: AgentID { get }
    var displayName: String { get }
    /// The file that changes on write; it is snapshotted before every change.
    var configURL: URL { get }
    /// Transports the agent can run; the others are shown as "not supported" and never written.
    var supportedTransports: Set<Transport> { get }
    func isInstalled() -> Bool
    func serverNames() throws -> [String]
    /// The agent's global servers as AgentHub would describe them, for import. Entries it can't express are left out.
    func readServers() throws -> [FoundServer]
    /// Servers the agent has in project scope, by name → project paths. Read-only: AgentHub never writes there.
    func projectServers() -> [String: [String]]
    func upsert(_ server: MCPServer, values: [String: String]) throws
    func remove(name: String) throws
}

extension AgentAdapter {
    public var supportedTransports: Set<Transport> { [.stdio, .http] }

    public func supports(_ transport: Transport) -> Bool { supportedTransports.contains(transport) }

    public func projectServers() -> [String: [String]] { [:] }
}

public enum Agents {
    public static func all(runner: CommandRunner) -> [any AgentAdapter] {
        [
            ClaudeAdapter(runner: runner),
            CodexAdapter(runner: runner),
            AntigravityAdapter(runner: runner),
            GeminiAdapter(runner: runner),
            CursorAdapter(runner: runner),
            ClaudeDesktopAdapter(runner: runner),
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

    public func readServers() throws -> [FoundServer] { try JSONConfigFile.readServers(configURL) }

    public func upsert(_ server: MCPServer, values: [String: String]) throws {
        // `claude mcp add` refuses to overwrite an existing name, so the old entry is removed first
        // and put back if the new one is rejected.
        let servers = try JSONConfigFile.load(configURL)["mcpServers"] as? [String: Any] ?? [:]
        let previous = servers[server.name]
        if previous != nil {
            try runner.run("claude", ["mcp", "remove", "-s", "user", server.name])
        }
        do {
            try runner.run("claude", Self.addArguments(server, values: values), secrets: Array(values.values))
        } catch {
            if let previous, let data = try? JSONSerialization.data(withJSONObject: previous),
                let json = String(data: data, encoding: .utf8)
            {
                _ = try? runner.run("claude", ["mcp", "add-json", "-s", "user", server.name, json], secrets: [json])
            }
            throw error
        }
    }

    public func remove(name: String) throws {
        try runner.run("claude", ["mcp", "remove", "-s", "user", name])
    }

    /// Every project Claude Code knows (`projects` in `~/.claude.json`): its local-scope servers there
    /// and the shared ones in the project's `.mcp.json`.
    public func projectServers() -> [String: [String]] {
        guard let projects = (try? JSONConfigFile.load(configURL))?["projects"] as? [String: Any] else { return [:] }
        var result: [String: [String]] = [:]
        for path in projects.keys.sorted() {
            var names = Set(((projects[path] as? [String: Any])?["mcpServers"] as? [String: Any] ?? [:]).keys)
            let shared = URL(fileURLWithPath: path).appendingPathComponent(".mcp.json")
            names.formUnion((try? JSONConfigFile.serverNames(shared)) ?? [])
            for name in names { result[name, default: []].append(path) }
        }
        return result
    }

    /// `-e` and `-H` are variadic, so they go after the name, never right before it.
    public static func addArguments(_ server: MCPServer, values: [String: String]) -> [String] {
        let pairs = server.keyValues(values)
        switch server.transport {
        case .stdio:
            var args = ["mcp", "add", "-s", "user", server.name]
            for pair in pairs { args += ["-e", "\(pair.key)=\(pair.value)"] }
            return args + ["--", server.command] + server.args
        case .http:
            var args = ["mcp", "add", "-s", "user", "-t", "http", server.name, server.url]
            for pair in pairs { args += ["-H", "\(pair.key): \(pair.value)"] }
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

    public func readServers() throws -> [FoundServer] { CodexTOML.readServers(in: try read()) }

    public func upsert(_ server: MCPServer, values: [String: String]) throws {
        try write(CodexTOML.upserting(server, values: values, in: try read()))
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

    public func readServers() throws -> [FoundServer] { try JSONConfigFile.readServers(configURL) }

    public func upsert(_ server: MCPServer, values: [String: String]) throws {
        try runner.run("agy", Self.addArguments(server, values: values), secrets: Array(values.values))
    }

    public func remove(name: String) throws {
        try runner.run("agy", ["mcp", "remove", name])
    }

    /// `agy` rejects flags placed after the name. `agy mcp add` also updates an existing server.
    public static func addArguments(_ server: MCPServer, values: [String: String]) -> [String] {
        let pairs = server.keyValues(values)
        switch server.transport {
        case .stdio:
            var args = ["mcp", "add"]
            for pair in pairs { args += ["--env", "\(pair.key)=\(pair.value)"] }
            return args + [server.name, "--", server.command] + server.args
        case .http:
            var args = ["mcp", "add", "--type", "http"]
            for pair in pairs { args += ["--header", "\(pair.key): \(pair.value)"] }
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

    public func readServers() throws -> [FoundServer] { try JSONConfigFile.readServers(configURL) }

    public func upsert(_ server: MCPServer, values: [String: String]) throws {
        try JSONConfigFile.setServer(server.name, entry: Self.entry(server, values: values), in: configURL)
    }

    public func remove(name: String) throws {
        try JSONConfigFile.setServer(name, entry: nil, in: configURL)
    }

    static func entry(_ server: MCPServer, values: [String: String]) -> [String: Any] {
        let keys = server.keyDictionary(values)
        switch server.transport {
        case .stdio:
            var entry: [String: Any] = ["command": server.command, "args": server.args]
            if let keys { entry["env"] = keys }
            return entry
        case .http:
            // `httpUrl` is streamable HTTP; plain `url` would mean SSE.
            var entry: [String: Any] = ["httpUrl": server.url]
            if let keys { entry["headers"] = keys }
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

    public func readServers() throws -> [FoundServer] { try JSONConfigFile.readServers(configURL) }

    public func upsert(_ server: MCPServer, values: [String: String]) throws {
        try JSONConfigFile.setServer(server.name, entry: Self.entry(server, values: values), in: configURL)
    }

    public func remove(name: String) throws {
        try JSONConfigFile.setServer(name, entry: nil, in: configURL)
    }

    static func entry(_ server: MCPServer, values: [String: String]) -> [String: Any] {
        let keys = server.keyDictionary(values)
        switch server.transport {
        case .stdio:
            var entry: [String: Any] = ["command": server.command, "args": server.args]
            if let keys { entry["env"] = keys }
            return entry
        case .http:
            var entry: [String: Any] = ["url": server.url]
            if let keys { entry["headers"] = keys }
            return entry
        }
    }
}

// MARK: - Claude Desktop

/// `claude_desktop_config.json` → `mcpServers`. The file only runs local commands (remote servers are connectors
/// in the app), so a remote server is written as `npx mcp-remote <url>` with each header passed as
/// `Name:${VAR}` and its value in `env`, which keeps spaces out of the arguments.
/// Claude Desktop reads the file on launch, so it needs a restart after a change.
public struct ClaudeDesktopAdapter: AgentAdapter {
    public let runner: CommandRunner
    public let id = AgentID.claudeDesktop
    public let displayName = "Claude Desktop"
    public var configURL: URL {
        runner.home.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
    }

    public func isInstalled() -> Bool {
        FileManager.default.fileExists(atPath: configURL.path)
            || FileManager.default.fileExists(atPath: "/Applications/Claude.app")
    }

    public func serverNames() throws -> [String] { try JSONConfigFile.serverNames(configURL) }

    /// `mcp-remote` entries in AgentHub's own shape read back as remote servers; other ones stay local commands.
    public func readServers() throws -> [FoundServer] {
        try JSONConfigFile.readServers(configURL).map { Self.remote(from: $0) ?? $0 }
    }

    public func upsert(_ server: MCPServer, values: [String: String]) throws {
        try JSONConfigFile.setServer(server.name, entry: Self.entry(server, values: values), in: configURL)
    }

    public func remove(name: String) throws {
        try JSONConfigFile.setServer(name, entry: nil, in: configURL)
    }

    static func entry(_ server: MCPServer, values: [String: String]) -> [String: Any] {
        guard server.transport == .http else { return CursorAdapter.entry(server, values: values) }
        var args = ["-y", "mcp-remote", server.url]
        var env: [String: String] = [:]
        for pair in server.keyValues(values) {
            let variable = headerVariable(pair.key)
            args += ["--header", "\(pair.key):${\(variable)}"]
            env[variable] = pair.value
        }
        var entry: [String: Any] = ["command": "npx", "args": args]
        if !env.isEmpty { entry["env"] = env }
        return entry
    }

    /// `Private-Token` → `MCP_HEADER_PRIVATE_TOKEN`.
    static func headerVariable(_ header: String) -> String {
        "MCP_HEADER_" + header.uppercased().map { $0.isLetter || $0.isNumber ? String($0) : "_" }.joined()
    }

    static func remote(from found: FoundServer) -> FoundServer? {
        let args = found.server.args
        guard found.server.command == "npx", args.count >= 3, args[0] == "-y", args[1] == "mcp-remote" else { return nil }
        var keys: [String] = []
        var values: [String: String] = [:]
        var rest = args.dropFirst(3)
        while let flag = rest.first {
            guard flag == "--header", rest.count >= 2 else { return nil }
            let header = rest[rest.index(after: rest.startIndex)]
            guard let colon = header.firstIndex(of: ":") else { return nil }
            let name = String(header[..<colon])
            guard header[header.index(after: colon)...] == "${\(headerVariable(name))}",
                let value = found.values[headerVariable(name)]
            else { return nil }
            keys.append(name)
            values[name] = value
            rest = rest.dropFirst(2)
        }
        guard values.count == found.values.count else { return nil }
        let server = MCPServer(name: found.server.name, transport: .http, url: args[2], keys: keys.sorted())
        return FoundServer(server: server, values: values)
    }
}
