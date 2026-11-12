import AgentHubCore
import Foundation
import Observation

/// A short message the notch shows on its own, like the Dynamic Island.
struct IslandAlert: Identifiable, Equatable {
    enum Kind { case finished, waiting, limit }

    var id: String
    var kind: Kind
    var title: String
    var detail: String
    /// The session to bring forward on a click.
    var pid: Int32?
    /// Stays until resolved (a session waiting for you), instead of fading after a few seconds.
    var persistent: Bool

    static func waitingID(_ sessionID: String) -> String { "waiting-\(sessionID)" }

    /// The alert for a session event; `.resumed` has none (it resolves the waiting one).
    init?(_ event: SessionEvent) {
        switch event {
        case .finished(let session):
            self.init(
                id: "finished-\(session.id)-\(Date().timeIntervalSince1970)", kind: .finished,
                title: "\(session.agent.shortName) finished", detail: session.title, pid: session.pid, persistent: false)
        case .waiting(let session, let reason):
            let what: String
            switch reason?.lowercased() {
            case let reason? where reason.contains("permission"): what = "needs permission"
            case let reason? where !reason.isEmpty: what = "is waiting: \(reason)"
            default: what = "is waiting for you"
            }
            self.init(
                id: Self.waitingID(session.id), kind: .waiting,
                title: "\(session.agent.shortName) \(what)", detail: session.title, pid: session.pid, persistent: true)
        case .resumed:
            return nil
        }
    }

    init(limit usage: AgentUsage, window: UsageWindow) {
        let percent = Int(((window.usedFraction ?? 0) * 100).rounded())
        self.init(
            id: "limit-\(usage.id.rawValue)-\(window.id)", kind: .limit,
            title: "\(usage.name): \(window.label) at \(percent)%", detail: "Close to the limit", pid: nil, persistent: false)
    }

    init(id: String, kind: Kind, title: String, detail: String, pid: Int32?, persistent: Bool) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.pid = pid
        self.persistent = persistent
    }
}

/// What the notch shows: collapsed, expanded into the panel, or an alert pill; plus the alert queue.
/// The windows themselves belong to `NotchController`, which follows this store.
@MainActor
@Observable
final class NotchStore {
    var expanded = false
    /// The alert on screen: the newest one still pending.
    private(set) var alert: IslandAlert?
    var notchWidth: CGFloat = 200
    var notchHeight: CGFloat = 32
    var hasNotch = true

    /// Something is drawn below the notch, so the panel window must be up.
    var isVisible: Bool { expanded || alert != nil }

    /// Events for the host and the composition root.
    @ObservationIgnored var onExpand: () -> Void = {}
    @ObservationIgnored var onOpenRequest: () -> Void = {}

    @ObservationIgnored private var alerts: [IslandAlert] = []
    private static let alertDuration: Duration = .seconds(6)

    func expand() {
        guard !expanded else { return }
        expanded = true
        onExpand()
    }

    func collapse() {
        expanded = false
    }

    /// Resting on the pill opens the panel like the notch does; the host applies its hover delay.
    func requestOpen() {
        onOpenRequest()
    }

    func show(_ alert: IslandAlert) {
        alerts.removeAll { $0.id == alert.id }
        alerts.append(alert)
        self.alert = alert
        guard !alert.persistent else { return }
        Task { [weak self] in
            try? await Task.sleep(for: Self.alertDuration)
            self?.resolve(alert.id)
        }
    }

    func resolve(_ id: String) {
        guard alerts.contains(where: { $0.id == id }) else { return }
        alerts.removeAll { $0.id == id }
        alert = alerts.last
    }

    static func preview(expanded: Bool = true) -> NotchStore {
        let store = NotchStore()
        store.expanded = expanded
        return store
    }
}
