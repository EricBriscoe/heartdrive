import SwiftUI

extension Color {
    /// Heart rate colored against the target, shared by the phone and watch so
    /// both render the number identically: red over, green within ±3 bpm, neutral
    /// below, and dimmed when there's no reading. `.primary` is white on the
    /// always-dark watch and adapts to light/dark on the phone.
    static func heartRateZone(bpm: Double?, target: Int) -> Color {
        guard let bpm else { return .secondary }
        let delta = bpm - Double(target)
        if delta > 3 { return .red }
        if delta < -3 { return .primary }
        return .green
    }
}
