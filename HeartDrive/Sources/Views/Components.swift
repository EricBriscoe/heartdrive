import SwiftUI

struct MetricCard<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: systemImage)
                .font(.caption)
                .foregroundStyle(.secondary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }
}

struct StatusBadge: View {
    let text: String
    let systemImage: String
    let color: Color

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }
}

extension ErgControllerState {
    var label: String {
        switch self {
        case .idle: return "Ready"
        case .settling: return "Settling…"
        case .tracking: return "Holding target"
        case .holdingNoCadence: return "Paused. Pedal to resume"
        case .hrLost: return "Heart rate lost"
        case .atCeiling: return "At power ceiling: HR above target"
        case .atFloor: return "At power floor"
        }
    }

    var color: Color {
        switch self {
        case .idle: return .secondary
        case .settling: return .orange
        case .tracking: return .green
        case .holdingNoCadence: return .gray
        case .hrLost: return .red
        case .atCeiling: return .orange
        case .atFloor: return .blue
        }
    }

    var systemImage: String {
        switch self {
        case .idle: return "pause.circle"
        case .settling: return "hourglass"
        case .tracking: return "checkmark.circle.fill"
        case .holdingNoCadence: return "figure.cycling"
        case .hrLost: return "heart.slash.fill"
        case .atCeiling: return "arrow.up.circle.fill"
        case .atFloor: return "arrow.down.circle.fill"
        }
    }
}

extension WatchLinkState {
    var icon: String {
        switch self {
        case .live, .reconnecting: return "heart.fill"
        case .lost: return "heart.slash"
        case .idle: return "heart"
        }
    }

    var color: Color {
        switch self {
        case .live: return .green
        case .reconnecting: return .orange
        case .lost: return .red
        case .idle: return .secondary
        }
    }

    var pulses: Bool {
        switch self {
        case .live, .reconnecting: return true
        case .lost, .idle: return false
        }
    }

    func label(source: String?) -> String {
        switch self {
        case .live: return source ?? "Apple Watch"
        case .reconnecting: return "Watch live"
        case .lost: return "Reconnecting…"
        case .idle: return "Start on Watch"
        }
    }

    func heroColor(inBand: Bool) -> Color {
        switch self {
        case .live: return inBand ? .green : .primary
        case .reconnecting, .lost, .idle: return .secondary
        }
    }
}
