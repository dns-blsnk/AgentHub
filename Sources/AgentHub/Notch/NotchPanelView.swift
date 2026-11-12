import AgentHubCore
import SwiftUI

/// The panel that grows out of the notch: running sessions, limits per agent and a few quick actions.
/// Collapsed it is the notch itself; with an alert it is a pill just below it. The view's size sizes the
/// window, so nothing transparent is left covering the screen.
struct NotchPanelView: View {
    /// Reports the view's size to the host, which sizes the window to it.
    let onSize: (CGSize) -> Void

    @Environment(NotchStore.self) private var notch
    @Environment(UsageStore.self) private var usage
    @Environment(SessionStore.self) private var sessions

    /// Agents with too many quotas (Antigravity lists every model) show only the first few here.
    private static let maxWindowsPerAgent = 4
    private static let pillWidth: CGFloat = 380

    var body: some View {
        ZStack(alignment: .top) {
            if notch.expanded {
                content.transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .top)))
            } else if let alert = notch.alert {
                AlertPill(alert: alert, notchHeight: notch.notchHeight) {
                    if let pid = alert.pid { sessions.focus(pid: pid) }
                    notch.resolve(alert.id)
                }
                .onHover { if $0 { notch.requestOpen() } }
                .transition(.opacity)
            }
        }
        .frame(width: width, height: notch.isVisible ? nil : notch.notchHeight, alignment: .top)
        .background(NotchShape(radius: notch.expanded ? 22 : notch.alert != nil ? 18 : 10).fill(.black))
        .fixedSize(horizontal: false, vertical: true)
        .animation(notch.expanded ? .spring(duration: 0.3, bounce: 0.15) : .easeIn(duration: 0.18), value: notch.expanded)
        .animation(.spring(duration: 0.35, bounce: 0.25), value: notch.alert)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { onSize($0) }
        .environment(\.colorScheme, .dark)
    }

    private var width: CGFloat {
        if notch.expanded { return NotchController.panelWidth }
        return notch.alert != nil ? Self.pillWidth : notch.notchWidth
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("AgentHub").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if usage.loading {
                    ProgressView().controlSize(.mini)
                } else if let last = usage.lastRefresh {
                    Text("updated \(last.formatted(date: .omitted, time: .shortened))")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            // Below the camera housing, the part of the panel that is visible.
            .padding(.top, max(notch.notchHeight - 18, 6))

            if !sessions.sessions.isEmpty {
                SessionsSection(sessions: sessions.sessions) { pid in
                    sessions.focus(pid: pid)
                    notch.collapse()
                }
                Divider().overlay(.white.opacity(0.15))
            }

            if usage.usages.isEmpty {
                Text("Reading limits…").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(usage.usages) { agent in
                AgentSection(usage: agent, maxWindows: Self.maxWindowsPerAgent)
            }

            Divider().overlay(.white.opacity(0.15))
            QuickActions()
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 14)
        .foregroundStyle(.white)
    }
}

/// The Dynamic Island style message: one line below the camera, tap to jump to the session.
private struct AlertPill: View {
    let alert: IslandAlert
    let notchHeight: CGFloat
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.callout.weight(.semibold))
                .foregroundStyle(color)
                .symbolEffect(.pulse, isActive: alert.kind == .waiting)
            VStack(alignment: .leading, spacing: 1) {
                Text(alert.title).font(.callout.weight(.semibold)).lineLimit(1)
                if !alert.detail.isEmpty {
                    Text(alert.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if alert.pid != nil {
                Image(systemName: "arrow.up.forward").font(.caption).foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(.white)
        .padding(.top, notchHeight + 4)
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }

    private var icon: String {
        switch alert.kind {
        case .finished: return "checkmark.circle.fill"
        case .waiting: return "hand.raised.fill"
        case .limit: return "gauge.with.dots.needle.67percent"
        }
    }

    private var color: Color {
        switch alert.kind {
        case .finished: return .green
        case .waiting: return .orange
        case .limit: return .yellow
        }
    }
}

private struct SessionsSection: View {
    let sessions: [AgentSession]
    let onTap: (Int32) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Sessions").font(.callout.weight(.semibold))
            ForEach(sessions) { session in
                SessionRow(session: session)
                    .contentShape(Rectangle())
                    .onTapGesture { onTap(session.pid) }
                    .help("Bring its terminal to the front")
            }
        }
    }
}

private struct SessionRow: View {
    let session: AgentSession

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
                .opacity(session.state == .working ? 0.9 : 1)
            Text(session.agent.shortName)
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
            Text(session.title)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Text(stateText)
                .foregroundStyle(stateColor)
                .lineLimit(1)
        }
        .font(.caption)
    }

    private var color: Color {
        switch session.state {
        case .working: return .green
        case .waiting: return .orange
        case .idle: return .gray
        case .running: return .blue
        }
    }

    private var stateColor: Color {
        if case .waiting = session.state { return .orange }
        return .secondary
    }

    private var stateText: String {
        let elapsed = session.since.map { " · " + Self.elapsed(since: $0) } ?? ""
        switch session.state {
        case .working: return "working" + elapsed
        case .waiting(let reason): return (reason.map { "waiting: \($0)" } ?? "waiting for you") + elapsed
        case .idle: return "idle"
        case .running: return "running"
        }
    }

    static func elapsed(since date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        return "\(seconds / 3600)h \(seconds % 3600 / 60)m"
    }
}

/// Flat top flush with the screen edge, rounded bottom corners: reads as the notch growing down.
private struct NotchShape: Shape {
    var radius: CGFloat

    var animatableData: CGFloat {
        get { radius }
        set { radius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let r = min(radius, rect.height / 2, rect.width / 2)
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - r, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - r), control: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

private struct AgentSection: View {
    let usage: AgentUsage
    let maxWindows: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(usage.name).font(.callout.weight(.semibold))
                if let plan = usage.plan {
                    Text(plan).font(.caption2).foregroundStyle(.secondary)
                }
            }
            if usage.windows.isEmpty, let note = usage.note {
                Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            ForEach(usage.windows.prefix(maxWindows)) { window in
                LimitRow(window: window)
            }
            if usage.windows.count > maxWindows {
                Text("+\(usage.windows.count - maxWindows) more in AgentHub").font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }
}

private struct LimitRow: View {
    let window: UsageWindow

    var body: some View {
        HStack(spacing: 8) {
            Text(window.label)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 128, alignment: .leading)
            Bar(fraction: window.usedFraction ?? 0)
            Text(window.usedFraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "–")
                .monospacedDigit()
                .frame(width: 38, alignment: .trailing)
            Text(window.resetsAt.map(Self.reset) ?? "")
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .trailing)
        }
        .font(.caption)
    }

    /// "2h 13m" within a day, "Fri 03:59" further out.
    static func reset(_ date: Date) -> String {
        let seconds = date.timeIntervalSinceNow
        guard seconds > 0 else { return "now" }
        if seconds < 86_400 {
            let hours = Int(seconds) / 3600
            let minutes = Int(seconds) % 3600 / 60
            return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
        }
        return date.formatted(.dateTime.weekday(.abbreviated).hour(.twoDigits(amPM: .omitted)).minute())
    }
}

private struct Bar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.12))
                Capsule().fill(color).frame(width: max(proxy.size.width * fraction, fraction > 0 ? 4 : 0))
            }
        }
        .frame(height: 5)
    }

    private var color: Color {
        switch fraction {
        case 0.9...: return .red
        case 0.7...: return .orange
        default: return .green
        }
    }
}

private struct QuickActions: View {
    @Environment(AccountsStore.self) private var accounts
    @Environment(NavigationStore.self) private var navigation

    var body: some View {
        HStack(spacing: 8) {
            if !accounts.switchable.isEmpty {
                Menu {
                    ForEach(accounts.switchable) { agent in
                        Section(agent.name) {
                            AccountToggles(agent: agent)
                        }
                    }
                } label: {
                    Label("Accounts", systemImage: "person.crop.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Switch the account of an agent")
            }
            Spacer()
            Button { navigation.openMain(addingServer: true) } label: {
                Label("MCP", systemImage: "plus")
            }
            Button { navigation.openMain() } label: {
                Label("Open", systemImage: "arrow.up.forward.app")
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
}
