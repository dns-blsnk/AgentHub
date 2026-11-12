import Foundation
import Security

public enum AppPaths {
    public static var support: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AgentHub", isDirectory: true)
    }
    public static var registry: URL { support.appendingPathComponent("registry.json") }
    public static var snapshots: URL { support.appendingPathComponent("snapshots", isDirectory: true) }
    public static var antigravityAccounts: URL { support.appendingPathComponent("antigravity-accounts.json") }
}

/// The list of MCP servers, without secrets.
public struct RegistryStore: Sendable {
    public let url: URL

    public init(url: URL) { self.url = url }

    public func load() -> [MCPServer] {
        guard let data = FileManager.default.contents(atPath: url.path) else { return [] }
        return (try? JSONDecoder().decode([MCPServer].self, from: data)) ?? []
    }

    /// Private: arguments can carry secrets the user typed into a command line.
    public func save(_ servers: [MCPServer]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try PrivateFiles.write(try encoder.encode(servers), to: url)
    }
}

/// Tokens as generic passwords in the login Keychain, one per server id.
public struct KeychainStore: Sendable {
    public let service: String

    public init(service: String) { self.service = service }

    public func get(_ account: String) -> String? {
        try? read(account)
    }

    /// Like `get`, but tells a missing item (nil) apart from a refused or failed read (throws), so a caller
    /// never mistakes "access denied" for "nothing stored" and overwrites the item.
    public func read(_ account: String) throws -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        try check(status)
        return (item as? Data).flatMap { String(data: $0, encoding: .utf8) }
    }

    public func set(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        let status = SecItemUpdate(baseQuery(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var query = baseQuery(account)
            query[kSecValueData as String] = data
            try check(SecItemAdd(query as CFDictionary, nil))
        } else {
            try check(status)
        }
    }

    public func delete(_ account: String) {
        SecItemDelete(baseQuery(account) as CFDictionary)
    }

    private func baseQuery(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            throw NSError(domain: "Keychain", code: Int(status), userInfo: [NSLocalizedDescriptionKey: message])
        }
    }
}

/// Key values of every MCP server in one Keychain item, a JSON object `{server id: {key: value}}`, so macOS asks
/// for access once instead of once per server. Older versions kept one item per server; `loadAll` moves them over.
public struct ServerKeyStore: Sendable {
    public let keychain: KeychainStore
    static let account = "servers"

    public init(keychain: KeychainStore) { self.keychain = keychain }

    /// Values of every server. Throws when the Keychain refuses, so nothing is saved over values that couldn't be read.
    public func loadAll(for servers: [MCPServer]) throws -> [UUID: [String: String]] {
        var all: [UUID: [String: String]] = [:]
        if let stored = try keychain.read(Self.account) {
            // Unreadable means stop: saving over it would drop every server's values at once.
            guard let object = try? JSONSerialization.jsonObject(with: Data(stored.utf8)) as? [String: [String: String]] else {
                throw NSError(
                    domain: "Keychain", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "The stored MCP key values are in an unknown format; nothing was changed."])
            }
            for (id, values) in object {
                if let uuid = UUID(uuidString: id) { all[uuid] = values }
            }
        }
        var migrated: [MCPServer] = []
        for server in servers where all[server.id] == nil && !server.keys.isEmpty {
            let legacy = Self.decode(try keychain.read(server.id.uuidString), keys: server.keys)
            if !legacy.isEmpty {
                all[server.id] = legacy
                migrated.append(server)
            }
        }
        if !migrated.isEmpty {
            try saveAll(all)
            for server in migrated { keychain.delete(server.id.uuidString) }
        }
        return all
    }

    public func saveAll(_ all: [UUID: [String: String]]) throws {
        let object = Dictionary(uniqueKeysWithValues: all.filter { !$0.value.isEmpty }.map { ($0.key.uuidString, $0.value) })
        if object.isEmpty {
            keychain.delete(Self.account)
            return
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: .sortedKeys)
        try keychain.set(String(decoding: data, as: UTF8.self), account: Self.account)
    }

    /// Only the server's own keys are kept, so a removed key's value doesn't linger.
    public static func ownValues(_ values: [String: String], for server: MCPServer) -> [String: String] {
        values.filter { server.keys.contains($0.key) && !$0.value.isEmpty }
    }

    /// v0.1 stored the bare token of the server's single key.
    static func decode(_ stored: String?, keys: [String]) -> [String: String] {
        guard let stored, !stored.isEmpty else { return [:] }
        if let object = try? JSONSerialization.jsonObject(with: Data(stored.utf8)) as? [String: String] {
            return object
        }
        return keys.first.map { [$0: stored] } ?? [:]
    }
}

/// Copies of agent config files taken before AgentHub changes them.
public struct SnapshotStore: Sendable {
    public let root: URL

    public init(root: URL) { self.root = root }

    /// A new folder for one apply operation, e.g. `2026-11-09_14-03-22_ab12`.
    public func makeSession() -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let suffix = UUID().uuidString.prefix(4).lowercased()
        return root.appendingPathComponent("\(formatter.string(from: Date()))_\(suffix)", isDirectory: true)
    }

    /// Session folder names sort chronologically, so the oldest ones go first.
    public func prune(keeping limit: Int) {
        let sessions = (try? FileManager.default.contentsOfDirectory(atPath: root.path))?.sorted() ?? []
        for name in sessions.dropLast(limit) {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(name))
        }
    }

    public func save(_ file: URL, agent: AgentID, in session: URL) throws {
        let file = file.resolvingSymlinksInPath()  // copy the content, not a dotfiles symlink
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        // Snapshots hold the same tokens as the configs, whatever permissions those have.
        try PrivateFiles.makeDirectory(root)
        try PrivateFiles.makeDirectory(session)
        let target = session.appendingPathComponent("\(agent.rawValue)-\(file.lastPathComponent)")
        guard !FileManager.default.fileExists(atPath: target.path) else { return }
        try FileManager.default.copyItem(at: file, to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
    }
}
