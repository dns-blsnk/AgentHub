import Foundation

extension AgentID {
    /// The agent's name as people call it.
    public var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .antigravity: return "Antigravity"
        case .gemini: return "Gemini CLI"
        case .cursor: return "Cursor"
        case .claudeDesktop: return "Claude Desktop"
        }
    }

    /// Short name for tight spots (notch alerts, usage cards).
    public var shortName: String {
        switch self {
        case .claude: return "Claude"
        case .gemini: return "Gemini"
        default: return displayName
        }
    }
}

/// What AgentHub found out about one agent on this machine.
public struct AgentStatus: Identifiable, Sendable, Equatable {
    public let id: AgentID
    public let name: String
    public let installed: Bool
    /// The global config path with `~` for the home directory.
    public let configPath: String
    public let serverNames: [String]
    public let error: String?
    public var supportedTransports: Set<Transport>
    /// Project-scope servers by name → project paths (with `~`), shown but never written.
    public var projectServers: [String: [String]]

    public init(
        id: AgentID, name: String, installed: Bool, configPath: String, serverNames: [String], error: String?,
        supportedTransports: Set<Transport> = [.stdio, .http], projectServers: [String: [String]] = [:]
    ) {
        self.id = id
        self.name = name
        self.installed = installed
        self.configPath = configPath
        self.serverNames = serverNames
        self.error = error
        self.supportedTransports = supportedTransports
        self.projectServers = projectServers
    }

    public func supports(_ transport: Transport) -> Bool { supportedTransports.contains(transport) }
}

extension Agents {
    /// Detects every supported agent: installed or not, its config and what's in it. Reads only.
    public static func detect(runner: CommandRunner) -> (adapters: [any AgentAdapter], statuses: [AgentStatus]) {
        let adapters = all(runner: runner)
        let home = runner.home.path
        let statuses = adapters.map { adapter -> AgentStatus in
            let installed = adapter.isInstalled()
            var names: [String] = []
            var readError: String?
            if installed {
                do { names = try adapter.serverNames() } catch { readError = error.localizedDescription }
            }
            return AgentStatus(
                id: adapter.id,
                name: adapter.displayName,
                installed: installed,
                configPath: adapter.configURL.path.replacingOccurrences(of: home, with: "~"),
                serverNames: names,
                error: readError,
                supportedTransports: adapter.supportedTransports,
                projectServers: installed
                    ? adapter.projectServers().mapValues { $0.map { $0.replacingOccurrences(of: home, with: "~") } } : [:]
            )
        }
        return (adapters, statuses)
    }
}
