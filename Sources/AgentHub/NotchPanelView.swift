import AgentHubCore
import SwiftUI

/// The panel that grows out of the notch: limits per agent and a few quick actions.
/// It is always laid out at full size (that size sizes the window); only the black shape and the content animate.
struct NotchPanelView: View {
    let state: NotchState
    let actions: NotchActions
    let onSize: (CGSize) -> Void

    @Environment(UsageModel.self) private var usage

    /// Agents with too many quotas (Antigravity lists every model) show only the first few here.
    private static let maxWindowsPerAgent = 4

    var body: some View {
        ZStack(alignment: .top) {
            NotchShape(radius: state.expanded ? 22 : 10)
                .fill(.black)
                .frame(width: state.expanded ? nil : state.notchWidth, height: state.expanded ? nil : state.notchHeight)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            content
                .opacity(state.expanded ? 1 : 0)
                .scaleEffect(state.expanded ? 1 : 0.92, anchor: .top)
        }
        .frame(width: NotchController.panelWidth)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { onSize($0) }
        .environment(\.colorScheme, .dark)
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
            .padding(.top, max(state.notchHeight - 18, 6))

            if usage.usages.isEmpty {
                Text("Reading limits…").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(usage.usages) { agent in
                AgentSection(usage: agent, maxWindows: Self.maxWindowsPerAgent)
            }

            Divider().overlay(.white.opacity(0.15))
            QuickActions(actions: actions)
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 14)
        .foregroundStyle(.white)
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
    let actions: NotchActions
    @Environment(AccountsModel.self) private var accounts

    var body: some View {
        HStack(spacing: 8) {
            if !accounts.accounts.isEmpty {
                Menu {
                    ForEach(accounts.accounts) { account in
                        Toggle(account.email, isOn: Binding(
                            get: { account.email == accounts.activeEmail },
                            set: { if $0 { Task { await accounts.switchTo(account) } } }
                        ))
                    }
                } label: {
                    Label(accounts.activeEmail ?? "Antigravity", systemImage: "person.crop.circle")
                        .lineLimit(1)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(accounts.adding)
                .help("Antigravity account")
            }
            Spacer()
            Button { actions.addServer() } label: {
                Label("MCP", systemImage: "plus")
            }
            Button { actions.openMain() } label: {
                Label("Open", systemImage: "arrow.up.forward.app")
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
}
