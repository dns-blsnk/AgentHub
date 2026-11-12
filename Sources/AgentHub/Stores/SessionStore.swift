import AgentHubCore
import AppKit
import Observation

/// What changed in a session between two scans.
enum SessionEvent {
    /// A turn seen in progress is over.
    case finished(AgentSession)
    /// The session stopped to ask for something.
    case waiting(AgentSession, reason: String?)
    /// A waiting session went on, or ended.
    case resumed(sessionID: String)
}

/// Running agent sessions, re-scanned every 2 seconds. State changes go out as `SessionEvent`s.
@MainActor
@Observable
final class SessionStore {
    var sessions: [AgentSession] = []

    @ObservationIgnored var onEvent: (SessionEvent) -> Void = { _ in }

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

    static func preview() -> SessionStore { SessionStore(preview: ()) }

    func sessions(of agent: AgentID) -> [AgentSession] { sessions.filter { $0.agent == agent } }

    /// Brings the terminal or IDE running the session to the front: the nearest ancestor process that is a regular app.
    func focus(pid: Int32) {
        for ancestor in ProcessTable.ancestry(of: pid) {
            if let app = NSRunningApplication(processIdentifier: ancestor), app.activationPolicy == .regular {
                app.activate()
                return
            }
        }
    }

    private func apply(_ found: [AgentSession]) {
        guard !isPreview else { return }
        let current = Dictionary(found.map { ($0.id, $0.state) }, uniquingKeysWith: { first, _ in first })
        for session in found {
            let before = previous[session.id]
            switch session.state {
            case .waiting(let reason):
                if !before.isWaiting { onEvent(.waiting(session, reason: reason)) }
            case .idle:
                if before.isWaiting { onEvent(.resumed(sessionID: session.id)) }
                // Only a turn seen in progress counts as finished, not a session found idle at launch.
                if before == .working && scannedOnce { onEvent(.finished(session)) }
            case .working, .running:
                if before.isWaiting { onEvent(.resumed(sessionID: session.id)) }
            }
        }
        for (id, state) in previous where current[id] == nil && Optional(state).isWaiting {
            onEvent(.resumed(sessionID: id))
        }
        previous = current
        scannedOnce = true
        if sessions != found { sessions = found }
    }
}

private extension Optional where Wrapped == SessionState {
    var isWaiting: Bool {
        if case .waiting = self { return true }
        return false
    }
}
