import Foundation

/// Atomic writes replace the file, which would turn a dotfiles symlink into a plain file and reset
/// permissions; write through the symlink and put the old permissions back. A new file is private (0600):
/// agent configs end up holding tokens.
enum ConfigFileWriter {
    static func write(_ data: Data, to url: URL) throws {
        let target = url.resolvingSymlinksInPath()
        let permissions = (try? FileManager.default.attributesOfItem(atPath: target.path))?[.posixPermissions] ?? 0o600
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: target.path)
    }
}

/// Files that hold secrets or personal data: readable by the owner only.
public enum PrivateFiles {
    /// Drops group and other permission bits (e.g. 0644 → 0600). Agent CLIs create their configs world-readable,
    /// and once AgentHub has put a token there that matters. The owner's own bits stay as they are.
    public static func restrict(_ url: URL) throws {
        let target = url.resolvingSymlinksInPath()
        guard let mode = (try? FileManager.default.attributesOfItem(atPath: target.path))?[.posixPermissions] as? Int else { return }
        let restricted = mode & 0o700
        if restricted != mode {
            try FileManager.default.setAttributes([.posixPermissions: restricted], ofItemAtPath: target.path)
        }
    }

    /// Creates `directory` (and parents) owner-only, and tightens it if it already exists.
    public static func makeDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    /// Writes atomically and leaves the file at 0600.
    public static func write(_ data: Data, to url: URL) throws {
        try makeDirectory(url.deletingLastPathComponent())
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// Reads and writes JSON configs that keep MCP servers under a top-level `mcpServers` object.
enum JSONConfigFile {
    static func load(_ url: URL) throws -> [String: Any] {
        guard let data = FileManager.default.contents(atPath: url.path),
              !data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 })
        else { return [:] }
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw AgentError.unreadableConfig(url, "top level is not an object")
            }
            return object
        } catch let error as AgentError {
            throw error
        } catch {
            // Most likely JSONC (comments or trailing commas): refuse rather than drop them.
            throw AgentError.unreadableConfig(url, "not plain JSON (comments?), edit it by hand")
        }
    }

    static func save(_ object: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try ConfigFileWriter.write(data, to: url)
    }

    static func serverNames(_ url: URL) throws -> [String] {
        let servers = try load(url)["mcpServers"] as? [String: Any] ?? [:]
        return servers.keys.sorted()
    }

    /// `url` / `httpUrl` (Gemini) / `serverUrl` (Antigravity) are remote; `type: sse` has no AgentHub equivalent.
    static func readServers(_ url: URL) throws -> [FoundServer] {
        let servers = try load(url)["mcpServers"] as? [String: Any] ?? [:]
        return servers.keys.sorted().compactMap { name in
            guard let entry = servers[name] as? [String: Any], (entry["type"] as? String) != "sse" else { return nil }
            if let command = entry["command"] as? String {
                let env = stringDictionary(entry["env"])
                return FoundServer(
                    server: MCPServer(name: name, transport: .stdio, command: command,
                                      args: entry["args"] as? [String] ?? [], keys: env.keys.sorted()),
                    values: env
                )
            }
            guard let remote = (entry["url"] ?? entry["httpUrl"] ?? entry["serverUrl"]) as? String else { return nil }
            let headers = stringDictionary(entry["headers"])
            return FoundServer(
                server: MCPServer(name: name, transport: .http, url: remote, keys: headers.keys.sorted()),
                values: headers
            )
        }
    }

    private static func stringDictionary(_ value: Any?) -> [String: String] {
        (value as? [String: Any] ?? [:]).compactMapValues { $0 as? String }
    }

    /// Keys AgentHub writes; anything else in an existing entry (timeouts, trust flags…) is kept.
    static let ownedEntryKeys: Set<String> = ["command", "args", "env", "url", "httpUrl", "headers", "type"]

    static func setServer(_ name: String, entry: [String: Any]?, in url: URL) throws {
        var root = try load(url)
        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        if let entry {
            let existing = (servers[name] as? [String: Any] ?? [:]).filter { !ownedEntryKeys.contains($0.key) }
            servers[name] = existing.merging(entry) { _, new in new }
        } else {
            servers[name] = nil
        }
        root["mcpServers"] = servers
        try save(root, to: url)
    }
}

/// Minimal, format-preserving edits to Codex `config.toml`: only the `[mcp_servers.<name>]` tables
/// of one server are replaced or removed, every other line stays byte-for-byte the same.
public enum CodexTOML {
    public static func serverNames(in text: String) -> [String] {
        var names: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let path = tablePath(String(line)), path.count == 2, path[0] == "mcp_servers" else { continue }
            if !names.contains(path[1]) { names.append(path[1]) }
        }
        return names
    }

    /// Servers from `[mcp_servers.<name>]` tables, with `env` / `http_headers` either as sub-tables or inline tables.
    /// Other keys (`bearer_token_env_var`, timeouts…) aren't part of the registry and stay in the file on update.
    public static func readServers(in text: String) -> [FoundServer] {
        var order: [String] = []
        var main: [String: [String: String]] = [:]  // raw values of the main table
        var keys: [String: [String: String]] = [:]
        var path: [String] = []
        var pending = ""

        for line in text.components(separatedBy: "\n") {
            if pending.isEmpty, let header = tablePath(line) {
                path = header
                if header.count >= 2, header[0] == "mcp_servers", !order.contains(header[1]) { order.append(header[1]) }
                continue
            }
            guard path.count >= 2, path[0] == "mcp_servers" else { continue }
            pending += (pending.isEmpty ? "" : "\n") + line
            if bracketDelta(pending) > 0 { continue }  // a multi-line array or inline table goes on
            defer { pending = "" }
            let parts = pending.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard parts.count == 2, !parts[0].hasPrefix("#") else { continue }
            let key = unquoted(parts[0])
            let name = path[1]
            if path.count == 2 {
                if ["env", "http_headers"].contains(key) {
                    keys[name, default: [:]].merge(inlineTable(parts[1])) { _, new in new }
                } else {
                    main[name, default: [:]][key] = parts[1]
                }
            } else if path.count == 3, ["env", "http_headers"].contains(path[2]), let value = strings(in: parts[1]).first {
                keys[name, default: [:]][key] = value
            }
        }

        return order.compactMap { name in
            let table = main[name] ?? [:]
            let values = keys[name] ?? [:]
            if let command = table["command"].flatMap({ strings(in: $0).first }) {
                let args = table["args"].map(strings(in:)) ?? []
                return FoundServer(server: MCPServer(name: name, transport: .stdio, command: command, args: args,
                                                     keys: values.keys.sorted()), values: values)
            }
            if let url = table["url"].flatMap({ strings(in: $0).first }) {
                return FoundServer(server: MCPServer(name: name, transport: .http, url: url, keys: values.keys.sorted()),
                                   values: values)
            }
            return nil
        }
    }

    /// Every basic or literal string in a TOML value, in order: one for a string, all items for an array.
    static func strings(in value: String) -> [String] {
        var result: [String] = []
        var current: String?
        var quote: Character = "\""
        var escaped = false
        for char in value {
            guard current != nil else {
                if char == "#" { break }
                if char == "\"" || char == "'" { current = ""; quote = char }
                continue
            }
            if escaped {
                switch char {
                case "n": current!.append("\n")
                case "t": current!.append("\t")
                case "r": current!.append("\r")
                default: current!.append(char)
                }
                escaped = false
            } else if char == "\\" && quote == "\"" {
                escaped = true
            } else if char == quote {
                result.append(current!)
                current = nil
            } else {
                current!.append(char)
            }
        }
        return result
    }

    /// `{ A = "x", "B-C" = 'y' }` → `["A": "x", "B-C": "y"]`.
    static func inlineTable(_ value: String) -> [String: String] {
        var body = value.trimmingCharacters(in: .whitespaces)
        guard body.hasPrefix("{"), body.hasSuffix("}") else { return [:] }
        body = String(body.dropFirst().dropLast())
        var result: [String: String] = [:]
        for pair in body.split(separator: ",") {
            let parts = pair.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            if parts.count == 2, let value = strings(in: parts[1]).first { result[unquoted(parts[0])] = value }
        }
        return result
    }

    private static func unquoted(_ key: String) -> String {
        key.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }

    public static func upserting(_ server: MCPServer, values: [String: String], in text: String) -> String {
        let block = self.block(for: server, values: values)
        var lines = text.components(separatedBy: "\n")
        if let firstStart = blockRange(of: server.name, in: lines)?.lowerBound {
            // Keep the server where it was, and keep tables AgentHub doesn't own (e.g. per-tool `approval_mode`).
            let kept = foreignSubtables(of: server.name, in: lines)
            let mainKeys = foreignMainKeys(of: server.name, in: lines)
            removeAllBlocks(of: server.name, from: &lines)
            var replacement = self.block(for: server, values: values, extraMainLines: mainKeys).components(separatedBy: "\n") + [""]
            if !kept.isEmpty { replacement += kept + [""] }
            lines.insert(contentsOf: replacement, at: min(firstStart, lines.count))
            return lines.joined(separator: "\n")
        }
        var trimmed = text
        while trimmed.hasSuffix("\n") { trimmed.removeLast() }
        return (trimmed.isEmpty ? "" : trimmed + "\n\n") + block + "\n"
    }

    public static func removing(_ name: String, from text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        removeAllBlocks(of: name, from: &lines)
        return lines.joined(separator: "\n")
    }

    /// Keys of `[mcp_servers.<name>]` AgentHub writes itself; all others (`startup_timeout_sec`, `enabled`,
    /// `cwd`, `enabled_tools`…) are carried over on update.
    static let ownedMainKeys: Set<String> = ["command", "args", "url", "env", "http_headers"]

    /// The server's main-table lines (with comments and multi-line values) whose key AgentHub doesn't own.
    private static func foreignMainKeys(of name: String, in lines: [String]) -> [String] {
        var kept: [String] = []
        var inMain = false
        var keeping = false
        var depth = 0
        for line in lines {
            if depth == 0, let path = tablePath(line) {
                inMain = path == ["mcp_servers", name]
                continue
            }
            guard inMain else { continue }
            if depth == 0 {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty { continue }
                let key = trimmed.split(separator: "=", maxSplits: 1).first.map {
                    $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                } ?? ""
                keeping = trimmed.hasPrefix("#") || !ownedMainKeys.contains(key)
            }
            if keeping { kept.append(line) }
            depth = max(0, depth + bracketDelta(line))
        }
        return kept
    }

    /// Opening minus closing brackets/braces outside strings and comments, to follow multi-line values.
    private static func bracketDelta(_ line: String) -> Int {
        var delta = 0
        var quote: Character?
        var escaped = false
        for char in line {
            if let q = quote {
                if escaped { escaped = false } else if char == "\\" && q == "\"" { escaped = true } else if char == q { quote = nil }
                continue
            }
            switch char {
            case "\"", "'": quote = char
            case "#": return delta
            case "[", "{": delta += 1
            case "]", "}": delta -= 1
            default: break
            }
        }
        return delta
    }

    /// Lines of the server's sub-tables other than the `env` / `http_headers` AgentHub writes, trailing blanks trimmed.
    private static func foreignSubtables(of name: String, in lines: [String]) -> [String] {
        var kept: [String] = []
        var copying = false
        for line in lines {
            if let path = tablePath(line) {
                copying = path.count >= 3 && path[0] == "mcp_servers" && path[1] == name
                    && !["env", "http_headers"].contains(path[2])
            }
            if copying { kept.append(line) }
        }
        while let last = kept.last, last.trimmingCharacters(in: .whitespaces).isEmpty { kept.removeLast() }
        return kept
    }

    private static func removeAllBlocks(of name: String, from lines: inout [String]) {
        while let range = blockRange(of: name, in: lines) {
            lines.removeSubrange(range)
        }
    }

    static func block(for server: MCPServer, values: [String: String], extraMainLines: [String] = []) -> String {
        let pairs = server.keyValues(values).map { "\(quoted($0.key)) = \(quoted($0.value))" }
        let table = "mcp_servers.\(server.name)"
        var lines = ["[\(table)]"]
        switch server.transport {
        case .stdio:
            lines.append("command = \(quoted(server.command))")
            lines.append("args = [\(server.args.map(quoted).joined(separator: ", "))]")
            lines += extraMainLines
            if !pairs.isEmpty { lines += ["", "[\(table).env]"] + pairs }
        case .http:
            lines.append("url = \(quoted(server.url))")
            lines += extraMainLines
            if !pairs.isEmpty { lines += ["", "[\(table).http_headers]"] + pairs }
        }
        return lines.joined(separator: "\n")
    }

    /// Lines from the server's first table header up to the next unrelated header (or the end of the file).
    static func blockRange(of name: String, in lines: [String]) -> Range<Int>? {
        func belongs(_ path: [String]) -> Bool { path.count >= 2 && path[0] == "mcp_servers" && path[1] == name }
        guard let start = lines.firstIndex(where: { tablePath($0).map(belongs) ?? false }) else { return nil }
        var end = start + 1
        while end < lines.count {
            if let path = tablePath(lines[end]), !belongs(path) { break }
            end += 1
        }
        return start..<end
    }

    /// `[a.b."c.d"]` → `["a", "b", "c.d"]`; nil for lines that are not table headers.
    static func tablePath(_ line: String) -> [String]? {
        var s = line.trimmingCharacters(in: .whitespaces)
        if let hash = s.range(of: "#"), !s[..<hash.lowerBound].contains("\"") {
            s = String(s[..<hash.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        guard s.hasPrefix("["), s.hasSuffix("]") else { return nil }
        s = String(s.drop(while: { $0 == "[" }).reversed().drop(while: { $0 == "]" }).reversed())
        var parts: [String] = []
        var current = ""
        var inQuotes = false
        for char in s {
            if char == "\"" {
                inQuotes.toggle()
            } else if char == "." && !inQuotes {
                parts.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(char)
            }
        }
        parts.append(current.trimmingCharacters(in: .whitespaces))
        return parts
    }

    static func quoted(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where scalar.value < 0x20 || scalar.value == 0x7F:
                out += String(format: "\\u%04X", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }
}
