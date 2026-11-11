import AgentHubCore
import SwiftUI

/// One card per agent: each limit window as a bar with the time until it resets.
struct UsageView: View {
    @Environment(UsageModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Usage limits").font(.headline)
                    Text(subtitle).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if model.loading { ProgressView().controlSize(.small) }
                Button { Task { await model.refresh() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Read the limits again")
                .disabled(model.loading)
            }
            .padding(16)
            Divider()

            if model.usages.isEmpty {
                ProgressView("Reading limits…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(model.usages) { usage in
                            UsageCard(usage: usage)
                        }
                        Text("These numbers come from the same undocumented sources the agents use themselves, so they may stop working after an agent update.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(16)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var subtitle: String {
        guard let last = model.lastRefresh else { return "Reading what each agent reports…" }
        return "Updated \(last.formatted(date: .omitted, time: .shortened)), every 5 minutes."
    }
}

private struct UsageCard: View {
    let usage: AgentUsage

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(usage.name).font(.title3.weight(.semibold))
                if let plan = usage.plan {
                    Text(plan)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
                Spacer()
                if let account = usage.account {
                    Text(account).font(.caption).foregroundStyle(.secondary)
                }
            }
            ForEach(usage.windows) { window in
                WindowRow(window: window)
            }
            if let note = usage.note {
                Label(note, systemImage: usage.windows.isEmpty ? "info.circle" : "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct WindowRow: View {
    let window: UsageWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(window.label)
                Spacer()
                if let used = window.usedFraction {
                    Text("\(Int((used * 100).rounded()))% used")
                        .monospacedDigit()
                        .foregroundStyle(used >= 0.9 ? .red : .secondary)
                }
            }
            .font(.callout)
            ProgressView(value: window.usedFraction ?? 0)
                .tint(tint)
            if let reset = window.resetsAt {
                Text(resetText(reset))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var tint: Color {
        switch window.usedFraction ?? 0 {
        case 0.9...: return .red
        case 0.7...: return .orange
        default: return .accentColor
        }
    }

    /// "Resets in 2 h 13 min" within a day, "Resets Fri 03:59" further out.
    private func resetText(_ date: Date) -> String {
        let seconds = date.timeIntervalSinceNow
        guard seconds > 0 else { return "Resetting now" }
        if seconds < 86_400 {
            let formatter = DateComponentsFormatter()
            formatter.allowedUnits = seconds < 3600 ? [.minute] : [.hour, .minute]
            formatter.unitsStyle = .short
            return "Resets in \(formatter.string(from: seconds) ?? "")"
        }
        return "Resets \(date.formatted(.dateTime.weekday(.abbreviated).hour().minute()))"
    }
}

#Preview {
    UsageView()
        .environment(UsageModel.preview())
        .frame(width: 860, height: 560)
}
