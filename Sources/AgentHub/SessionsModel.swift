import AgentHubCore
import AppKit
import Observation

/// A short message the notch shows on its own, like the Dynamic Island.
struct IslandAlert: Identifiable, Equatable {
    enum Kind { case finished, waiting, limit }

    var id: String
    var kind: Kind
    var agent: AgentID?
    var title: String
    var detail: String
    /// The session to bring forward on a click.
    var pid: Int32?
    /// Stays until resolved (a session waiting for you), instead of fading after a few seconds.
    var persistent: Bool
}

/// Running agent sessions, re-scanned every 2 seconds; state changes become notch alerts.
@MainActor
@Observable
final class SessionsModel {
    var sessions: [AgentSession] = []

    @ObservationIgnored var onAlert: (IslandAlert) -> Void = { _ in }
    @ObservationIgnored var onResolve: (String) -> Void = { _ in }

    private static let interval: Duration = .seconds(2)
    private var previous: [String: SessionState] = [:]
    private var scannedOnce = false
    private var isPreview = false

    init() {
        Task {
            let scanner = SessionScanner()
            while !Task.isCancelled {
                let found = await Task.detached { scanner.scan() }.value
                apply(found)
                try? await Task.sleep(for: Self.interval)
            }
        }
    }

    private init(preview: Void) {
        isPreview = true
        sessions = [
            AgentSession(agent: .claude, pid: 1, cwd: "/w/app", name: "fix-login", state: .waiting(reason: "permission"), since: .now.addingTimeInterval(-40)),
            AgentSession(agent: .claude, pid: 2, cwd: "/w/api", name: "refactor", state: .working, since: .now.addingTimeInterval(-300)),
            AgentSession(agent: .codex, pid: 3, cwd: "/w/site", state: .idle),
        ]
    }

    static func preview() -> SessionsModel { SessionsModel(preview: ()) }

    private func apply(_ found: [AgentSession]) {
        guard !isPreview else { return }
        let current = Dictionary(found.map { ($0.id, $0.state) }, uniquingKeysWith: { first, _ in first })
        for session in found {
            let before = previous[session.id]
            switch session.state {
            case .waiting(let reason):
                if !Self.isWaiting(before) { onAlert(Self.waitingAlert(session, reason: reason)) }
            case .idle:
                if Self.isWaiting(before) { onResolve(Self.waitingID(session)) }
                // Only a turn seen in progress counts as finished, not a session found idle at launch.
                if before == .working && scannedOnce { onAlert(Self.finishedAlert(session)) }
            case .working, .running:
                if Self.isWaiting(before) { onResolve(Self.waitingID(session)) }
            }
        }
        for (id, state) in previous where current[id] == nil && Self.isWaiting(state) {
            onResolve("waiting-\(id)")
        }
        previous = current
        scannedOnce = true
        if sessions != found { sessions = found }
    }

    /// Brings the terminal or IDE running the session to the front: the nearest ancestor process that is a regular app.
    func focus(pid: Int32) {
        for ancestor in ProcessTable.ancestry(of: pid) {
            if let app = NSRunningApplication(processIdentifier: ancestor), app.activationPolicy == .regular {
                app.activate()
                return
            }
        }
    }

    func hostAppName(pid: Int32) -> String? {
        ProcessTable.ancestry(of: pid).lazy.compactMap { pid -> String? in
            guard let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular else { return nil }
            return app.localizedName
        }.first
    }

    // MARK: Alerts

    private static func isWaiting(_ state: SessionState?) -> Bool {
        if case .waiting = state { return true }
        return false
    }

    private static func waitingID(_ session: AgentSession) -> String { "waiting-\(session.id)" }

    private static func waitingAlert(_ session: AgentSession, reason: String?) -> IslandAlert {
        let what: String
        switch reason?.lowercased() {
        case let reason? where reason.contains("permission"): what = "needs permission"
        case let reason? where !reason.isEmpty: what = "is waiting: \(reason)"
        default: what = "is waiting for you"
        }
        return IslandAlert(id: waitingID(session), kind: .waiting, agent: session.agent,
                           title: "\(agentName(session.agent)) \(what)", detail: label(session), pid: session.pid, persistent: true)
    }

    private static func finishedAlert(_ session: AgentSession) -> IslandAlert {
        IslandAlert(id: "finished-\(session.id)-\(Date().timeIntervalSince1970)", kind: .finished, agent: session.agent,
                    title: "\(agentName(session.agent)) finished", detail: label(session), pid: session.pid, persistent: false)
    }

    static func label(_ session: AgentSession) -> String {
        guard let name = session.name, !name.isEmpty, name != session.project else { return session.project }
        return "\(session.project) · \(name)"
    }

    static func agentName(_ agent: AgentID) -> String {
        switch agent {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .antigravity: return "Antigravity"
        case .gemini: return "Gemini"
        case .cursor: return "Cursor"
        case .claudeDesktop: return "Claude Desktop"
        }
    }
}
