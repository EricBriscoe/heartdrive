import Foundation

/// Presentation data only; each Bluetooth manager retains its own peripherals.
struct DiscoveredDevice: Identifiable, Equatable {
    let id: UUID
    let name: String
    var rssi: Int
}
