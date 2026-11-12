import Foundation

/// One limit window, e.g. Claude's 5-hour session or a model's quota in Antigravity.
public struct UsageWindow: Sendable, Hashable, Identifiable {
    public var id: String
    public var label: String
    /// 0…1; nil when the source only says when it resets.
    public var usedFraction: Double?
    public var resetsAt: Date?

    public init(id: String, label: String, usedFraction: Double?, resetsAt: Date?) {
        self.id = id
        self.label = label
        self.usedFraction = usedFraction.map { min(max($0, 0), 1) }
        self.resetsAt = resetsAt
    }
}

/// Tokens spent over a period, as the agent counts them: `input` includes `cachedInput`.
public struct TokenUsage: Sendable, Equatable {
    public var input = 0
    public var cachedInput = 0
    public var output = 0
    /// `total` per hour of the day, local time; empty when not broken down.
    public var hourly: [Int] = []

    public init(input: Int = 0, cachedInput: Int = 0, output: Int = 0, hourly: [Int] = []) {
        self.input = input
        self.cachedInput = cachedInput
        self.output = output
        self.hourly = hourly
    }

    public var total: Int { input + output }
    /// Input that wasn't served from the cache.
    public var freshInput: Int { max(input - cachedInput, 0) }

    mutating func add(_ spent: TokenUsage, atHour hour: Int) {
        input += spent.input
        cachedInput += spent.cachedInput
        output += spent.output
        if hourly.isEmpty { hourly = Array(repeating: 0, count: 24) }
        hourly[hour] += spent.total
    }
}

public struct AgentUsage: Sendable, Identifiable {
    public var id: AgentID
    public var name: String
    /// Plan or tier as the source names it ("pro", "free-tier"…).
    public var plan: String?
    /// Whose limits these are, when the source says.
    public var account: String?
    public var windows: [UsageWindow]
    /// Tokens spent today, for agents that log them locally.
    public var tokensToday: TokenUsage?
    /// The source reports what's left rather than what's used (Antigravity), so that's what to show.
    public var reportsRemaining = false
    /// Why there are no windows, or a caveat about them.
    public var note: String?
    public var fetchedAt: Date

    public init(
        id: AgentID, name: String, plan: String? = nil, account: String? = nil, reportsRemaining: Bool = false,
        windows: [UsageWindow] = [], tokensToday: TokenUsage? = nil, note: String? = nil, fetchedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.plan = plan
        self.account = account
        self.windows = windows
        self.tokensToday = tokensToday
        self.reportsRemaining = reportsRemaining
        self.note = note
        self.fetchedAt = fetchedAt
    }
}

public enum UsageError: LocalizedError {
    case http(Int)
    case unexpectedResponse

    public var errorDescription: String? {
        switch self {
        case .http(let status): return "The usage service answered HTTP \(status)."
        case .unexpectedResponse: return "The usage service answered in an unknown format."
        }
    }
}

/// Reads limits the way each agent does itself. Every source is undocumented, so anything unexpected
/// becomes a note on the card instead of a guess. Agents' sign-ins are only read, never refreshed or written.
public struct UsageReader: Sendable {
    public let runner: CommandRunner

    public init(runner: CommandRunner) { self.runner = runner }

    public func readAll() async -> [AgentUsage] {
        async let claude = claude()
        async let antigravity = antigravity()
        let codex = codex()
        return await [claude, codex, antigravity]
    }

    // MARK: Claude

    /// The endpoint behind Claude Code's `/usage`, with the OAuth sign-in Claude Code keeps in the Keychain.
    /// Claude Desktop runs on the same subscription, so these are its limits too.
    public func claude() async -> AgentUsage {
        var usage = AgentUsage(id: .claude, name: "Claude")
        let raw: String
        do {
            raw = try CommandRunner.runRaw(
                "/usr/bin/security", ["find-generic-password", "-s", "Claude Code-credentials", "-w"], environment: nil)
        } catch {
            usage.note = "Not signed in to Claude Code with a Claude subscription."
            return usage
        }
        guard let oauth = (try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])?["claudeAiOauth"] as? [String: Any],
            let token = oauth["accessToken"] as? String
        else {
            usage.note = "Claude Code's sign-in has an unknown format."
            return usage
        }
        usage.plan = oauth["subscriptionType"] as? String
        if let expires = oauth["expiresAt"] as? Double, Date(timeIntervalSince1970: expires / 1000) < Date() {
            usage.note = "Claude Code's sign-in has expired. Start Claude Code once and it renews it."
            return usage
        }

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("AgentHub", forHTTPHeaderField: "User-Agent")
        do {
            usage.windows = try Self.claudeWindows(from: try await Self.json(for: request))
            if usage.windows.isEmpty { usage.note = "No limits reported for this plan." }
        } catch {
            usage.note = error.localizedDescription
        }
        return usage
    }

    /// Prefers the generic `limits` list; falls back to `five_hour` / `seven_day`.
    static func claudeWindows(from json: [String: Any]) throws -> [UsageWindow] {
        if let limits = json["limits"] as? [[String: Any]] {
            return limits.enumerated().compactMap { index, limit in
                guard let percent = limit["percent"] as? Double else { return nil }
                let kind = limit["kind"] as? String ?? "limit"
                let model = ((limit["scope"] as? [String: Any])?["model"] as? [String: Any])?["display_name"] as? String
                let label: String
                switch kind {
                case "session": label = "5-hour session"
                case "weekly_all": label = "Week, all models"
                case "weekly_scoped": label = "Week, \(model ?? "one model")"
                default: label = model.map { "\(kind) (\($0))" } ?? kind
                }
                return UsageWindow(
                    id: "\(kind)-\(model ?? "")-\(index)", label: label, usedFraction: percent / 100,
                    resetsAt: (limit["resets_at"] as? String).flatMap(parseDate))
            }
        }
        let legacy: [(String, String)] = [
            ("five_hour", "5-hour session"), ("seven_day", "Week, all models"),
            ("seven_day_opus", "Week, Opus"), ("seven_day_sonnet", "Week, Sonnet"),
        ]
        let windows = legacy.compactMap { key, label -> UsageWindow? in
            guard let window = json[key] as? [String: Any], let utilization = window["utilization"] as? Double else { return nil }
            return UsageWindow(
                id: key, label: label, usedFraction: utilization / 100,
                resetsAt: (window["resets_at"] as? String).flatMap(parseDate))
        }
        guard !windows.isEmpty || json["five_hour"] != nil else { throw UsageError.unexpectedResponse }
        return windows
    }

    // MARK: Antigravity

    /// The quota agy itself refreshes: `fetchAvailableModels` lists each model with `quotaInfo`.
    /// agy only renews its token while it runs, so an expired one is renewed by `agy models`, which agy writes back itself.
    public func antigravity() async -> AgentUsage {
        var usage = AgentUsage(id: .antigravity, name: "Antigravity", reportsRemaining: true)
        let keyring = AntigravityKeyring()
        guard var credential = try? keyring.readCredential() else {
            usage.note = "agy is not signed in."
            return usage
        }
        usage.account = credential.email
        if credential.isExpired, runner.which("agy") != nil {
            _ = try? runner.run("agy", ["models"])
            credential = (try? keyring.readCredential()) ?? credential
        }
        guard let token = credential.accessToken, !credential.isExpired else {
            usage.note = "agy's sign-in has expired. Start agy once and it renews it."
            return usage
        }

        do {
            let assist = try await Self.json(
                for: Self.cloudCode(
                    "loadCodeAssist", token: token,
                    body: [
                        "metadata": ["ideType": "ANTIGRAVITY", "platform": "PLATFORM_UNSPECIFIED", "pluginType": "GEMINI"]
                    ]))
            usage.plan = (assist["currentTier"] as? [String: Any])?["id"] as? String
            let project =
                (assist["cloudaicompanionProject"] as? [String: Any])?["id"] as? String
                ?? assist["cloudaicompanionProject"] as? String
            guard let project else {
                usage.note = "Antigravity didn't report a project for this account."
                return usage
            }
            let body: [String: Any] = ["project": project]
            usage.windows = try Self.antigravityWindows(
                from: try await Self.json(for: Self.cloudCode("fetchAvailableModels", token: token, body: body)))
            if usage.windows.isEmpty { usage.note = "No model quotas reported." }
        } catch {
            usage.note = error.localizedDescription
        }
        return usage
    }

    /// The models agy offers the agent (`agentModelSorts`) plus the Gemini tiers. A `resetTime` without
    /// `remainingFraction` means nothing is left: protobuf leaves zero values out. An untouched quota reports a
    /// `resetTime` of now plus the window (it moves on every read), so it has no reset until it's used.
    static func antigravityWindows(from json: [String: Any]) throws -> [UsageWindow] {
        guard let models = json["models"] as? [String: Any] else { throw UsageError.unexpectedResponse }
        var ids: [String] = []
        for sort in json["agentModelSorts"] as? [[String: Any]] ?? [] {
            for group in sort["groups"] as? [[String: Any]] ?? [] {
                ids += group["modelIds"] as? [String] ?? []
            }
        }
        // One model can serve several tiers ("pro" and "flash" both pointing at a flash model).
        var tierNames: [String: String] = [:]
        let tiers = json["tieredModelIds"] as? [String: [String]] ?? [:]
        for (tier, label) in [("pro", "Pro"), ("flash", "Flash"), ("flashLite", "Flash Lite")] {
            for id in tiers[tier] ?? [] {
                if let existing = tierNames[id] {
                    tierNames[id] = existing + " / " + label
                } else {
                    tierNames[id] = "Gemini " + label
                    ids.append(id)
                }
            }
        }

        var seen = Set<String>()
        return ids.compactMap { id in
            guard seen.insert(id).inserted, let model = models[id] as? [String: Any],
                let quota = model["quotaInfo"] as? [String: Any]
            else { return nil }
            let reset = (quota["resetTime"] as? String).flatMap(parseDate)
            let remaining = quota["remainingFraction"] as? Double ?? (reset != nil ? 0 : nil)
            let label = model["displayName"] as? String ?? tierNames[id] ?? id
            return UsageWindow(id: id, label: label, usedFraction: remaining.map { 1 - $0 }, resetsAt: remaining == 1 ? nil : reset)
        }
    }

    private static func cloudCode(_ method: String, token: String, body: [String: Any]) throws -> URLRequest {
        var request = URLRequest(url: URL(string: "https://cloudcode-pa.googleapis.com/v1internal:\(method)")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // The service only returns the user's project and tier to the Antigravity client; any other agent is "ineligible".
        request.setValue("antigravity", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    // MARK: Codex

    /// Codex writes `rate_limits` into its session files after each turn, but only for a ChatGPT sign-in.
    /// Token counts are there for any sign-in.
    public func codex() -> AgentUsage {
        var usage = AgentUsage(id: .codex, name: "Codex")
        let codexHome = runner.home.appendingPathComponent(".codex")
        let sessions = codexHome.appendingPathComponent("sessions")
        usage.tokensToday = Self.codexTokens(in: sessions, since: Calendar.current.startOfDay(for: Date()))
        let auth = (FileManager.default.contents(atPath: codexHome.appendingPathComponent("auth.json").path))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        if (auth?["auth_mode"] as? String) == "apikey" {
            usage.plan = "API key"
            usage.note = "API key: billed per token, no plan limits."
            return usage
        }
        guard let latest = Self.latestCodexRateLimits(in: sessions) else {
            usage.note = "No limits yet: Codex writes them after the first reply in a session."
            return usage
        }
        usage.windows = latest.windows
        usage.plan = latest.plan
        usage.fetchedAt = latest.at
        return usage
    }

    /// The newest non-empty `rate_limits` in the newest session files.
    static func latestCodexRateLimits(in sessions: URL, filesToScan: Int = 20) -> (windows: [UsageWindow], plan: String?, at: Date)? {
        guard let enumerator = FileManager.default.enumerator(at: sessions, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return nil }
        var files: [(URL, Date)] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            files.append((url, (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast))
        }
        for (file, modified) in files.sorted(by: { $0.1 > $1.1 }).prefix(filesToScan) {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n").reversed() where line.contains("\"rate_limits\":{") {
                guard let event = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                    let limits = findValue("rate_limits", in: event) as? [String: Any]
                else { continue }
                let windows = codexWindows(from: limits)
                guard !windows.isEmpty else { continue }
                let at = (event["timestamp"] as? String).flatMap(parseDate) ?? modified
                return (windows, limits["plan_type"] as? String, at)
            }
        }
        return nil
    }

    /// Tokens spent since `since`, from the `token_count` events of session files touched since then. Each event
    /// carries the thread's running total; the change from the previous event is what that reply spent. The first
    /// event in a file counts only its own reply, so a resumed thread isn't counted twice.
    static func codexTokens(in sessions: URL, since: Date) -> TokenUsage {
        guard let enumerator = FileManager.default.enumerator(at: sessions, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return TokenUsage() }
        var sum = TokenUsage()
        let calendar = Calendar.current
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            guard let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, modified >= since,
                let text = try? String(contentsOf: url, encoding: .utf8)
            else { continue }
            var previous: TokenUsage?
            for line in text.split(separator: "\n") where line.contains("\"total_token_usage\"") {
                guard let event = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                    let info = findValue("info", in: event) as? [String: Any],
                    let total = (info["total_token_usage"] as? [String: Any]).map(tokenUsage)
                else { continue }
                let last = (info["last_token_usage"] as? [String: Any]).map(tokenUsage) ?? TokenUsage()
                let spent: TokenUsage
                // A running total that went down in any field was reset: count this reply on its own.
                if let previous, total.input >= previous.input, total.output >= previous.output {
                    spent = TokenUsage(
                        input: total.input - previous.input, cachedInput: max(total.cachedInput - previous.cachedInput, 0),
                        output: total.output - previous.output)
                } else {
                    spent = last
                }
                previous = total
                if let at = (event["timestamp"] as? String).flatMap(parseDate), at >= since {
                    sum.add(spent, atHour: calendar.component(.hour, from: at))
                }
            }
        }
        return sum
    }

    private static func tokenUsage(_ json: [String: Any]) -> TokenUsage {
        func int(_ key: String) -> Int { (json[key] as? NSNumber)?.intValue ?? 0 }
        return TokenUsage(input: int("input_tokens"), cachedInput: int("cached_input_tokens"), output: int("output_tokens"))
    }

    static func codexWindows(from limits: [String: Any]) -> [UsageWindow] {
        ["primary", "secondary"].compactMap { key in
            guard let window = limits[key] as? [String: Any], let used = window["used_percent"] as? Double else { return nil }
            let minutes = window["window_minutes"] as? Double
            let label: String
            switch minutes {
            case 300: label = "5-hour window"
            case 10080: label = "Week"
            case let minutes?: label = minutes >= 1440 ? "\(Int(minutes / 1440))-day window" : "\(Int(minutes / 60))-hour window"
            case nil: label = key.capitalized
            }
            let reset = (window["resets_at"] as? Double).map { Date(timeIntervalSince1970: $0) }
            return UsageWindow(id: key, label: label, usedFraction: used / 100, resetsAt: reset)
        }
    }

    // MARK: Helpers

    private static func json(for request: URLRequest) async throws -> [String: Any] {
        var request = request
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw UsageError.http(http.statusCode)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw UsageError.unexpectedResponse }
        return json
    }

    private static func findValue(_ key: String, in object: Any) -> Any? {
        if let dict = object as? [String: Any] {
            if let value = dict[key], !(value is NSNull) { return value }
            for value in dict.values {
                if let found = findValue(key, in: value) { return found }
            }
        }
        return nil
    }

    /// ISO 8601 with or without fractional seconds (Anthropic sends microseconds, Google whole seconds).
    static func parseDate(_ string: String) -> Date? {
        if let date = fractionalFormatter.date(from: string) ?? wholeFormatter.date(from: string) { return date }
        // Fractions longer than milliseconds: drop them.
        if let dot = string.firstIndex(of: "."), let end = string[dot...].firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" }) {
            return wholeFormatter.date(from: String(string[..<dot]) + String(string[end...]))
        }
        return nil
    }

    /// Shared: token counting parses a timestamp per line, and ISO8601DateFormatter is thread-safe.
    nonisolated(unsafe) private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    nonisolated(unsafe) private static let wholeFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
