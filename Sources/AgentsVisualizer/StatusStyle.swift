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

/// Status glyph. Running items pulse so motion alone tells "something is happening" at a glance.
struct StatusGlyph: View {
    let symbol: String
    let color: Color
    let isActive: Bool
    var size: CGFloat = 12

    var body: some View {
        Group {
            if isActive {
                PulsingDot(color: color, size: size * 0.75)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: size, weight: .semibold))
                    .foregroundStyle(color)
            }
        }
        .frame(width: size + 4, height: size + 4)
        .accessibilityHidden(true)
    }
}

struct PulsingDot: View {
    let color: Color
    let size: CGFloat
    private let expandedState = State(initialValue: false)  // see AgentList for why not `@State`
    private var expanded: Bool {
        get { expandedState.wrappedValue }
        nonmutating set { expandedState.wrappedValue = newValue }
    }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if !reduceMotion {
                Circle()
                    .stroke(color.opacity(expanded ? 0 : 0.7), lineWidth: 1.5)
                    .frame(width: size, height: size)
                    .scaleEffect(expanded ? 2.1 : 1)
            }
            Circle()
                .fill(color)
                .frame(width: size, height: size)
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { expanded = true }
        }
    }
}

/// "3 min ago", refreshed on its own so idle snapshots do not have to re-render the whole dashboard.
struct RelativeTime: View {
    let date: Date?

    var body: some View {
        if let date {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(Self.format(date, now: context.date))
                    .monospacedDigit()
                    .help(date.formatted(date: .abbreviated, time: .standard))
            }
        }
    }

    static func format(_ date: Date, now: Date) -> String {
        if now.timeIntervalSince(date) < 45 { return String(localized: "now") }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: now)
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
