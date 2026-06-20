import Foundation

/// Shared rendering of optional metrics, so the "value or em-dash" idiom isn't
/// repeated across the phone and watch UIs.
enum Display {
    static func int(_ value: Int?) -> String { value.map(String.init) ?? "—" }
    static func int(_ value: Double?) -> String { value.map { String(Int($0.rounded())) } ?? "—" }
    static func decimal(_ value: Double?, _ places: Int) -> String {
        value.map { String(format: "%.\(places)f", $0) } ?? "—"
    }
}
