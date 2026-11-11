import Foundation

/// What `agy` keeps in the Keychain: `go-keyring-base64:` + base64 of
/// `{"token": {access_token, refresh_token, expiry, …}, "auth_method": "...", "id_token_email": "..."}`.
public struct AntigravityCredential: Sendable, Equatable {
    public let raw: String
    public let email: String?
    public let authMethod: String?
    public let accessToken: String?
    public let expiry: Date?

    /// A minute of margin, so a token isn't used right as it runs out.
    public var isExpired: Bool { expiry.map { $0 < Date().addingTimeInterval(60) } ?? false }

    public init(raw: String) {
        self.raw = raw
        let payload: Data? = {
            let prefix = "go-keyring-base64:"
            if raw.hasPrefix(prefix) { return Data(base64Encoded: String(raw.dropFirst(prefix.count))) }
            return Data(raw.utf8)
        }()
        let json = payload.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        email = json?["id_token_email"] as? String
        authMethod = json?["auth_method"] as? String
        let token = json?["token"] as? [String: Any]
        accessToken = token?["access_token"] as? String
        expiry = (token?["expiry"] as? String).flatMap(UsageReader.parseDate)
    }
}

public struct AntigravityAccount: Codable, Identifiable, Hashable, Sendable {
    public var email: String
    public var authMethod: String
    public var addedAt: Date
    public var lastUsedAt: Date?

    public var id: String { email }

    public init(email: String, authMethod: String, addedAt: Date, lastUsedAt: Date?) {
        self.email = email
        self.authMethod = authMethod
        self.addedAt = addedAt
        self.lastUsedAt = lastUsedAt
    }
}

/// The one Keychain item `agy` signs in from. It goes through `/usr/bin/security`, the same way
/// agy's go-keyring does, so the item keeps the access list agy expects and agy never gets a prompt.
public struct AntigravityKeyring: Sendable {
    public let service: String
    public let account: String

    public init(service: String = "gemini", account: String = "antigravity") {
        self.service = service
        self.account = account
    }

    public func read() throws -> AntigravityCredential? {
        do {
            let raw = try CommandRunner.runRaw("/usr/bin/security", ["find-generic-password", "-s", service, "-a", account, "-w"], environment: nil)
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : AntigravityCredential(raw: trimmed)
        } catch let error as CommandError where error.status == 44 {
            return nil  // errSecItemNotFound
        }
    }

    public func write(_ raw: String) throws {
        guard !raw.contains(where: { $0.isWhitespace || $0 == "\"" || $0 == "\\" }) else {
            throw AccountError.unexpectedFormat
        }
        // Interactive mode reads the command from stdin, so the token never appears in `ps`.
        _ = try CommandRunner.runRaw(
            "/usr/bin/security", ["-i"], environment: nil,
            input: "add-generic-password -U -s \(service) -a \(account) -w \"\(raw)\"\n"
        )
        // `security -i` exits 0 even when the command inside fails.
        guard try read()?.raw == raw else { throw AccountError.writeFailed }
    }

    public func delete() throws {
        do {
            _ = try CommandRunner.runRaw("/usr/bin/security", ["delete-generic-password", "-s", service, "-a", account], environment: nil)
        } catch let error as CommandError where error.status == 44 {
            return
        }
    }
}

public enum AccountError: LocalizedError {
    case unexpectedFormat
    case writeFailed
    case unknownAccount(String)

    public var errorDescription: String? {
        switch self {
        case .unexpectedFormat: return "The stored Antigravity sign-in has an unexpected format."
        case .writeFailed: return "Couldn't update the Antigravity sign-in in the Keychain."
        case .unknownAccount(let email): return "No saved sign-in for \(email)."
        }
    }
}

/// Saved accounts: metadata in `antigravity-accounts.json`, each sign-in in AgentHub's own Keychain item.
public struct AntigravityAccountStore: Sendable {
    /// Refreshes run concurrently; serialize the load-modify-save of the metadata file.
    private static let lock = NSLock()

    public let metadataURL: URL
    public let keychain: KeychainStore

    public init(metadataURL: URL, keychain: KeychainStore = KeychainStore(service: "dev.agenthub.antigravity")) {
        self.metadataURL = metadataURL
        self.keychain = keychain
    }

    public func load() -> [AntigravityAccount] {
        guard let data = FileManager.default.contents(atPath: metadataURL.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([AntigravityAccount].self, from: data)) ?? []
    }

    public func save(_ accounts: [AntigravityAccount]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try PrivateFiles.write(try encoder.encode(accounts), to: metadataURL)
    }

    /// Adds the account or refreshes its saved sign-in.
    @discardableResult
    public func remember(_ credential: AntigravityCredential, markUsed: Bool) throws -> AntigravityAccount? {
        guard let email = credential.email else { return nil }
        Self.lock.lock()
        defer { Self.lock.unlock() }
        try keychain.set(credential.raw, account: email)
        var accounts = load()
        let now = Date()
        if let index = accounts.firstIndex(where: { $0.email == email }) {
            accounts[index].authMethod = credential.authMethod ?? accounts[index].authMethod
            if markUsed { accounts[index].lastUsedAt = now }
        } else {
            accounts.append(AntigravityAccount(email: email, authMethod: credential.authMethod ?? "", addedAt: now, lastUsedAt: markUsed ? now : nil))
        }
        try save(accounts)
        return accounts.first { $0.email == email }
    }

    public func savedSignIn(for email: String) -> String? {
        keychain.get(email)
    }

    public func forget(_ email: String) throws {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        keychain.delete(email)
        try save(load().filter { $0.email != email })
    }
}

/// Switching = putting another saved sign-in into agy's Keychain item.
public struct AntigravityAccountSwitcher: Sendable {
    public let keyring: AntigravityKeyring
    public let store: AntigravityAccountStore

    public init(keyring: AntigravityKeyring = AntigravityKeyring(), store: AntigravityAccountStore) {
        self.keyring = keyring
        self.store = store
    }

    /// agy refreshes its token in place, so whatever it has now is re-saved before anything else happens.
    @discardableResult
    public func captureCurrent() throws -> AntigravityAccount? {
        guard let credential = try keyring.read() else { return nil }
        return try store.remember(credential, markUsed: true)
    }

    public func switchTo(_ email: String) throws {
        try captureCurrent()
        try activate(email)
    }

    /// Puts a saved sign-in back without capturing first (used to undo an abandoned "add account").
    public func activate(_ email: String) throws {
        guard let raw = store.savedSignIn(for: email) else { throw AccountError.unknownAccount(email) }
        try keyring.write(raw)
        try store.remember(AntigravityCredential(raw: raw), markUsed: true)
    }

    /// Saves the current account and signs agy out, so the next `agy` start asks for a new sign-in.
    /// Returns the account that was active, to restore if the user gives up.
    public func beginAdding() throws -> AntigravityAccount? {
        let current = try keyring.read()
        let previous = try current.flatMap { try store.remember($0, markUsed: true) }
        // Never sign out of an account that isn't safely saved first.
        if let current, previous.map({ store.savedSignIn(for: $0.email) }) != current.raw {
            throw AccountError.unexpectedFormat
        }
        try keyring.delete()
        return previous
    }
}
