import Foundation

/// An agent's current sign-in as an opaque string AgentHub can save and put back, plus who it belongs to.
public struct SignIn: Sendable, Equatable {
    public let raw: String
    /// The account's email, or another stable label (e.g. "API key ••••abcd").
    public let email: String?
    public let authMethod: String?

    public init(raw: String, email: String?, authMethod: String?) {
        self.raw = raw
        self.email = email
        self.authMethod = authMethod
    }
}

/// Where an agent reads its sign-in from. Clearing is local only: an agent's own logout may revoke the
/// token on the server, which would break the copy AgentHub saved.
public protocol SignInSlot: Sendable {
    var agent: AgentID { get }
    func read() throws -> SignIn?
    func write(_ raw: String) throws
    func clear() throws
}

public enum AccountError: LocalizedError {
    case unexpectedFormat
    case writeFailed
    case unknownAccount(String)
    case sessionsRunning(String, Int)

    public var errorDescription: String? {
        switch self {
        case .unexpectedFormat: return "The stored sign-in has an unexpected format."
        case .writeFailed: return "Couldn't update the agent's sign-in."
        case .unknownAccount(let email): return "No saved sign-in for \(email)."
        case .sessionsRunning(let agent, let count):
            return
                "Close the \(count) running \(agent) session(s) first: \(agent) rewrites its sign-in while it runs and would undo the switch."
        }
    }
}

public struct SavedAccount: Codable, Identifiable, Hashable, Sendable {
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

/// Saved sign-ins of one agent: metadata in a JSON file, each sign-in in AgentHub's own Keychain item.
public struct AccountVault: Sendable {
    /// Refreshes run concurrently; serialize the load-modify-save of the metadata file.
    private static let lock = NSLock()

    public let metadataURL: URL
    public let keychain: KeychainStore

    public init(metadataURL: URL, keychain: KeychainStore) {
        self.metadataURL = metadataURL
        self.keychain = keychain
    }

    public static func antigravity() -> AccountVault {
        AccountVault(metadataURL: AppPaths.antigravityAccounts, keychain: KeychainStore(service: "dev.agenthub.antigravity"))
    }

    public static func codex() -> AccountVault {
        AccountVault(
            metadataURL: AppPaths.support.appendingPathComponent("codex-accounts.json"),
            keychain: KeychainStore(service: "dev.agenthub.codex"))
    }

    public static func claude() -> AccountVault {
        AccountVault(
            metadataURL: AppPaths.support.appendingPathComponent("claude-accounts.json"),
            keychain: KeychainStore(service: "dev.agenthub.claude"))
    }

    public func load() -> [SavedAccount] {
        guard let data = FileManager.default.contents(atPath: metadataURL.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([SavedAccount].self, from: data)) ?? []
    }

    public func save(_ accounts: [SavedAccount]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try PrivateFiles.write(try encoder.encode(accounts), to: metadataURL)
    }

    /// Adds the account or refreshes its saved sign-in.
    @discardableResult
    public func remember(_ signIn: SignIn, markUsed: Bool) throws -> SavedAccount? {
        guard let email = signIn.email else { return nil }
        Self.lock.lock()
        defer { Self.lock.unlock() }
        try keychain.set(signIn.raw, account: email)
        var accounts = load()
        let now = Date()
        if let index = accounts.firstIndex(where: { $0.email == email }) {
            accounts[index].authMethod = signIn.authMethod ?? accounts[index].authMethod
            if markUsed { accounts[index].lastUsedAt = now }
        } else {
            accounts.append(SavedAccount(email: email, authMethod: signIn.authMethod ?? "", addedAt: now, lastUsedAt: markUsed ? now : nil))
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

/// Switching = putting another saved sign-in into the agent's slot.
public struct AccountSwitcher: Sendable {
    public let slot: any SignInSlot
    public let vault: AccountVault

    public init(slot: any SignInSlot, vault: AccountVault) {
        self.slot = slot
        self.vault = vault
    }

    /// Agents refresh their tokens in place, so whatever the slot has now is re-saved before anything else happens.
    @discardableResult
    public func captureCurrent() throws -> SavedAccount? {
        guard let signIn = try slot.read() else { return nil }
        return try vault.remember(signIn, markUsed: true)
    }

    public func switchTo(_ email: String) throws {
        try captureCurrent()
        try activate(email)
    }

    /// Puts a saved sign-in back without capturing first (used to undo an abandoned "add account").
    public func activate(_ email: String) throws {
        guard let raw = vault.savedSignIn(for: email) else { throw AccountError.unknownAccount(email) }
        try slot.write(raw)
        if let signIn = try slot.read() { try vault.remember(signIn, markUsed: true) }
    }

    /// Saves the current account and clears the slot, so the agent's next login starts fresh.
    /// Returns the account that was active, to restore if the user gives up.
    public func beginAdding() throws -> SavedAccount? {
        let current = try slot.read()
        let previous = try current.flatMap { try vault.remember($0, markUsed: true) }
        // Never sign out of an account that isn't safely saved first.
        if let current, previous.map({ vault.savedSignIn(for: $0.email) }) != current.raw {
            throw AccountError.unexpectedFormat
        }
        try slot.clear()
        return previous
    }
}

// MARK: - Codex

/// `~/.codex/auth.json` (Codex's default file store): `auth_mode` plus either `OPENAI_API_KEY` or ChatGPT `tokens`.
public struct CodexAuthSlot: SignInSlot {
    public let home: URL
    public var agent: AgentID { .codex }
    public var url: URL { home.appendingPathComponent(".codex/auth.json") }

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) { self.home = home }

    public func read() throws -> SignIn? {
        guard let data = FileManager.default.contents(atPath: url.path), !data.isEmpty else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AccountError.unexpectedFormat }
        let raw = String(decoding: data, as: UTF8.self)
        return SignIn(raw: raw, email: Self.identity(json), authMethod: json["auth_mode"] as? String)
    }

    public func write(_ raw: String) throws {
        guard (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) is [String: Any] else { throw AccountError.unexpectedFormat }
        try ConfigFileWriter.write(Data(raw.utf8), to: url)
        try PrivateFiles.restrict(url)
    }

    public func clear() throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    /// The ChatGPT account's email from the id token, or the API key's last four characters.
    static func identity(_ json: [String: Any]) -> String? {
        if let token = (json["tokens"] as? [String: Any])?["id_token"] as? String,
            let claims = jwtClaims(token), let email = claims["email"] as? String
        {
            return email
        }
        if let key = json["OPENAI_API_KEY"] as? String, key.count > 4 {
            return "API key ••••\(key.suffix(4))"
        }
        return nil
    }

    static func jwtClaims(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        return Data(base64Encoded: payload).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }
}

// MARK: - Claude Code

/// Claude Code keeps its OAuth tokens in the Keychain item `Claude Code-credentials` (`claudeAiOauth`, next to
/// `mcpOAuth` for remote MCP logins) and the account's profile in `~/.claude.json` → `oauthAccount`.
/// A saved sign-in is both: `{"claudeAiOauth": …, "oauthAccount": …}`. Switching swaps only those two;
/// MCP logins stay with the machine, not the account.
public struct ClaudeSignInSlot: SignInSlot {
    public let home: URL
    public let service = "Claude Code-credentials"
    public var agent: AgentID { .claude }
    var stateURL: URL { home.appendingPathComponent(".claude.json") }

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) { self.home = home }

    public func read() throws -> SignIn? {
        guard let item = try readItem(), let oauth = item["claudeAiOauth"] as? [String: Any] else { return nil }
        let profile = try JSONConfigFile.load(stateURL)["oauthAccount"] as? [String: Any]
        var saved: [String: Any] = ["claudeAiOauth": oauth]
        if let profile { saved["oauthAccount"] = profile }
        let data = try JSONSerialization.data(withJSONObject: saved, options: .sortedKeys)
        return SignIn(
            raw: String(decoding: data, as: UTF8.self), email: profile?["emailAddress"] as? String,
            authMethod: oauth["subscriptionType"] as? String)
    }

    public func write(_ raw: String) throws {
        guard let saved = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
            let oauth = saved["claudeAiOauth"] as? [String: Any]
        else { throw AccountError.unexpectedFormat }
        var item = try readItem() ?? [:]
        item["claudeAiOauth"] = oauth
        try writeItem(item)
        try setProfile(saved["oauthAccount"])
    }

    public func clear() throws {
        if var item = try readItem() {
            item["claudeAiOauth"] = nil
            try writeItem(item)
        }
        try setProfile(nil)
    }

    /// Only the `oauthAccount` key changes; everything else in Claude Code's state file is kept.
    private func setProfile(_ profile: Any?) throws {
        guard FileManager.default.fileExists(atPath: stateURL.path) else { return }
        var state = try JSONConfigFile.load(stateURL)
        state["oauthAccount"] = profile
        try JSONConfigFile.save(state, to: stateURL)
    }

    private func readItem() throws -> [String: Any]? {
        let raw: String
        do {
            raw = try CommandRunner.runRaw("/usr/bin/security", ["find-generic-password", "-s", service, "-w"], environment: nil)
        } catch let error as CommandError where error.status == 44 {
            return nil
        }
        guard
            let item = try? JSONSerialization.jsonObject(with: Data(raw.trimmingCharacters(in: .whitespacesAndNewlines).utf8))
                as? [String: Any]
        else {
            throw AccountError.unexpectedFormat
        }
        return item
    }

    /// Through `/usr/bin/security`, like Claude Code itself, so the item keeps its access list. The value goes
    /// in as hex on stdin: no quoting issues, and the token never shows up in `ps`.
    private func writeItem(_ item: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: item)
        let hex = data.map { String(format: "%02x", $0) }.joined()
        let account = itemAccount() ?? NSUserName()
        guard !account.contains(where: { $0 == "\"" || $0 == "\\" || $0.isNewline }) else { throw AccountError.unexpectedFormat }
        _ = try CommandRunner.runRaw(
            "/usr/bin/security", ["-i"], environment: nil,
            input: "add-generic-password -U -a \"\(account)\" -s \"\(service)\" -X \(hex)\n"
        )
        // `security -i` exits 0 even when the command inside fails.
        guard let written = try readItem(),
            NSDictionary(dictionary: written).isEqual(to: item)
        else { throw AccountError.writeFailed }
    }

    /// The item's account attribute (Claude Code uses the macOS user name).
    private func itemAccount() -> String? {
        guard let output = try? CommandRunner.runRaw("/usr/bin/security", ["find-generic-password", "-s", service], environment: nil) else {
            return nil
        }
        for line in output.split(separator: "\n") where line.contains("\"acct\"<blob>=\"") {
            return line.components(separatedBy: "<blob>=\"").last.map { String($0.dropLast()) }
        }
        return nil
    }
}
