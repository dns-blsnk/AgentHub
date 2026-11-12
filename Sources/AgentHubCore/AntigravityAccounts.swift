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

/// The one Keychain item `agy` signs in from. It goes through `/usr/bin/security`, the same way
/// agy's go-keyring does, so the item keeps the access list agy expects and agy never gets a prompt.
public struct AntigravityKeyring: SignInSlot {
    public let service: String
    public let account: String
    public var agent: AgentID { .antigravity }

    public init(service: String = "gemini", account: String = "antigravity") {
        self.service = service
        self.account = account
    }

    public func read() throws -> SignIn? {
        try readCredential().map { SignIn(raw: $0.raw, email: $0.email, authMethod: $0.authMethod) }
    }

    public func readCredential() throws -> AntigravityCredential? {
        do {
            let raw = try CommandRunner.runRaw(
                "/usr/bin/security", ["find-generic-password", "-s", service, "-a", account, "-w"], environment: nil)
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
        guard try readCredential()?.raw == raw else { throw AccountError.writeFailed }
    }

    public func clear() throws {
        do {
            _ = try CommandRunner.runRaw("/usr/bin/security", ["delete-generic-password", "-s", service, "-a", account], environment: nil)
        } catch let error as CommandError where error.status == 44 {
            return
        }
    }
}
