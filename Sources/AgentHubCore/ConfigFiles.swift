import Foundation

/// Atomic writes replace the file, which would turn a dotfiles symlink into a plain file and reset
/// permissions; write through the symlink and put the old permissions back.
enum ConfigFileWriter {
    static func write(_ data: Data, to url: URL) throws {
        let target = url.resolvingSymlinksInPath()
        let permissions = (try? FileManager.default.attributesOfItem(atPath: target.path))?[.posixPermissions]
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target, options: .atomic)
        if let permissions {
            try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: target.path)
        }
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

    public static func upserting(_ server: MCPServer, token: String?, in text: String) -> String {
        let block = self.block(for: server, token: token)
        var lines = text.components(separatedBy: "\n")
        if let firstStart = blockRange(of: server.name, in: lines)?.lowerBound {
            // Keep the server where it was, and keep tables AgentHub doesn't own (e.g. per-tool `approval_mode`).
            let kept = foreignSubtables(of: server.name, in: lines)
            let mainKeys = foreignMainKeys(of: server.name, in: lines)
            removeAllBlocks(of: server.name, from: &lines)
            var replacement = self.block(for: server, token: token, extraMainLines: mainKeys).components(separatedBy: "\n") + [""]
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

    static func block(for server: MCPServer, token: String?, extraMainLines: [String] = []) -> String {
        let table = "mcp_servers.\(server.name)"
        var lines = ["[\(table)]"]
        switch server.transport {
        case .stdio:
            lines.append("command = \(quoted(server.command))")
            lines.append("args = [\(server.args.map(quoted).joined(separator: ", "))]")
            lines += extraMainLines
            if let secret = server.secret(token: token) {
                lines += ["", "[\(table).env]", "\(quoted(secret.key)) = \(quoted(secret.value))"]
            }
        case .http:
            lines.append("url = \(quoted(server.url))")
            lines += extraMainLines
            if let secret = server.secret(token: token) {
                lines += ["", "[\(table).http_headers]", "\(quoted(secret.key)) = \(quoted(secret.value))"]
            }
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
