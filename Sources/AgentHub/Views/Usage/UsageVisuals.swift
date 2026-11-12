import AgentHubCore
import SwiftUI

/// Colors and pieces shared by the notch panel and the Usage tab.
enum UsageTone {
    /// Green with room to spare, orange getting close, red nearly out; by the share already used.
    static func color(used: Double) -> Color {
        switch used {
        case 0.9...: return .red
        case 0.7...: return .orange
        default: return .green
        }
    }

    static let cached = Color.green.opacity(0.4)
    static let fresh = Color.green
    static let output = Color.cyan
}

extension UsageWindow {
    /// The share to draw: what's left for sources that report it that way, otherwise what's used.
    func shownFraction(remaining: Bool) -> Double? {
        usedFraction.map { remaining ? 1 - $0 : $0 }
    }
}

extension TokenUsage {
    /// "31.2M tokens · 30.1M cached · 210K out"
    var summary: String {
        var parts = ["\(Self.compact(total)) tokens"]
        if cachedInput > 0 { parts.append("\(Self.compact(cachedInput)) cached") }
        parts.append("\(Self.compact(output)) out")
        return parts.joined(separator: " · ")
    }

    /// 950, 12.4K, 31.2M
    static func compact(_ count: Int) -> String {
        // Thresholds sit where rounding to one decimal flips the unit, so 999,960 reads "1.0M", not "1000.0K".
        switch count {
        case 999_950...: return String(format: "%.1fM", Double(count) / 1_000_000)
        case 1_000...: return String(format: "%.1fK", Double(count) / 1_000)
        default: return "\(count)"
        }
    }
}

/// Tokens per hour of today as small bars; hours still ahead are left as faint ticks.
struct HourlyTokenBars: View {
    let hourly: [Int]
    var height: CGFloat = 22

    var body: some View {
        let peak = max(hourly.max() ?? 0, 1)
        let now = Calendar.current.component(.hour, from: Date())
        VStack(spacing: 3) {
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(Array(hourly.enumerated()), id: \.offset) { hour, tokens in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(hour > now ? Color.primary.opacity(0.08) : hour == now ? UsageTone.fresh : UsageTone.fresh.opacity(0.65))
                        .frame(height: tokens > 0 ? max(height * CGFloat(tokens) / CGFloat(peak), 2) : 1)
                        .frame(maxWidth: .infinity)
                        .help("\(hour):00  \(TokenUsage.compact(tokens)) tokens")
                }
            }
            .frame(height: height, alignment: .bottom)
            // Each label starts a quarter of the day, so it sits under its hour's bar.
            HStack(spacing: 0) {
                ForEach([0, 6, 12, 18], id: \.self) { hour in
                    Text(String(format: "%02d:00", hour)).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .font(.system(size: 9))
            .monospacedDigit()
            .foregroundStyle(.tertiary)
        }
    }
}

/// Where today's tokens went: read from the cache, new input, and output.
struct TokenLegend: View {
    let tokens: TokenUsage

    var body: some View {
        HStack(spacing: 12) {
            item(UsageTone.cached, tokens.cachedInput, "cached")
            item(UsageTone.fresh, tokens.freshInput, "new input")
            item(UsageTone.output, tokens.output, "output")
        }
    }

    private func item(_ color: Color, _ count: Int, _ label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(TokenUsage.compact(count)).monospacedDigit()
            Text(label).foregroundStyle(.secondary)
        }
    }
}
