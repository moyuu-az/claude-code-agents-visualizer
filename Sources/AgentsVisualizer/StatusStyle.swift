import AgentsVisualizerCore
import SwiftUI

extension SessionStatus {
    var label: LocalizedStringKey {
        switch self {
        case .needsInput: "Needs input"
        case .running: "Running"
        case .idle: "Done"
        case .ended: "Ended"
        }
    }

    var color: Color {
        switch self {
        case .needsInput: .orange
        case .running: .green
        case .idle: .blue
        case .ended: .secondary
        }
    }

    var symbol: String {
        switch self {
        case .needsInput: "exclamationmark.bubble.fill"
        case .running: "circle.fill"
        case .idle: "checkmark.circle.fill"
        case .ended: "stop.circle"
        }
    }
}

extension AgentStatus {
    var label: LocalizedStringKey {
        switch self {
        case .running: "Running"
        case .completed: "Completed"
        case .failed: "Failed"
        case .stopped: "Stopped"
        case .interrupted: "Interrupted"
        }
    }

    var color: Color {
        switch self {
        case .running: .green
        case .completed: .secondary
        case .failed: .red
        case .stopped, .interrupted: .orange
        }
    }

    var symbol: String {
        switch self {
        case .running: "circle.fill"
        case .completed: "checkmark"
        case .failed: "xmark.octagon.fill"
        case .stopped: "stop.fill"
        case .interrupted: "exclamationmark.triangle.fill"
        }
    }
}

extension SessionSurface {
    var label: LocalizedStringKey {
        switch self {
        case .desktop: "Desktop"
        case .terminal: "CLI"
        case .vscode: "VS Code"
        case .ssh: "SSH"
        case .background: "Background"
        }
    }

    var symbol: String {
        switch self {
        case .desktop: "macwindow"
        case .terminal: "terminal"
        case .vscode: "chevron.left.forwardslash.chevron.right"
        case .ssh: "network"
        case .background: "moon.stars"
        }
    }
}

/// Session status glyph: a spinning ring while running, a pulsing bubble when it needs you, and a bounce
/// when it settles into a new state, so changes catch the eye without reading any text.
struct StatusGlyph: View {
    let status: SessionStatus
    var size: CGFloat = 14
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            switch status {
            case .running:
                RunningRing(color: status.color, size: size)
            case .needsInput:
                symbol.symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
            case .idle, .ended:
                symbol.symbolEffect(.bounce, value: status)
            }
        }
        .frame(width: size + 4, height: size + 4)
        .accessibilityHidden(true)
    }

    private var symbol: some View {
        Image(systemName: status.symbol)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(status.color)
    }
}

/// Final-state mark for a finished agent; bounces once when the agent completes.
struct AgentStatusMark: View {
    let status: AgentStatus

    var body: some View {
        Image(systemName: status.symbol)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(status.color)
            .symbolEffect(.bounce, value: status)
            .accessibilityHidden(true)
    }
}

extension Image {
    /// A periodic wiggle on macOS 15+, a pulse before that.
    @ViewBuilder
    func attentionSeeking() -> some View {
        if #available(macOS 15.0, *) {
            symbolEffect(.wiggle.byLayer, options: .repeat(.periodic(delay: 2)))
        } else {
            symbolEffect(.pulse, options: .repeating)
        }
    }
}

/// "3 min ago". The clock comes from the environment so the whole dashboard ticks once per interval,
/// instead of every row scheduling its own relayout.
struct RelativeTime: View {
    let date: Date?
    @Environment(\.dashboardClock) private var now

    var body: some View {
        if let date {
            Text(Self.format(date, now: now))
                .monospacedDigit()
                .help(date.formatted(date: .abbreviated, time: .standard))
        }
    }

    static func format(_ date: Date, now: Date) -> String {
        if now.timeIntervalSince(date) < 45 { return String(localized: "now") }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: max(now, date))
    }
}

private struct DashboardClockKey: EnvironmentKey {
    static let defaultValue = Date()
}

extension EnvironmentValues {
    /// Coarse "now" shared by every relative timestamp; see `RelativeTime`.
    var dashboardClock: Date {
        get { self[DashboardClockKey.self] }
        set { self[DashboardClockKey.self] = newValue }
    }
}

/// Small rounded label used for surfaces, branches and agent types.
struct Tag: View {
    let text: Text
    var symbol: String?
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol).imageScale(.small) }
            text.lineLimit(1)
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(tint)
        .padding(.horizontal, 5)
        .padding(.vertical, 1.5)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}
