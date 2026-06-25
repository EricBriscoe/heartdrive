import Foundation
import Observation

struct RideSettings: Codable, Equatable {
    var targetHeartRate: Int = 140
    var ftp: Int = 200
    var aggressiveness: ControlAggressiveness = .balanced
    var broadcastToZwift: Bool = false
    var cadenceTarget: Int = 90
    var showCadenceGuide: Bool = false

    // The whole resistance band is derived from one number (FTP) instead of three separate
    // settings: a 30% floor, a 150% safety ceiling, and a 50% starting power. 150% sits just
    // above any power the HR loop would legitimately need (top of the anaerobic zone) and
    // caps a sensor-glitch runaway well short of an un-pedalable wall.
    static let floorFraction = 0.30
    static let ceilingFraction = 1.50
    static let startFraction = 0.50
    static func watts(_ ftp: Int, _ fraction: Double) -> Int { Int((Double(ftp) * fraction).rounded()) }

    var powerFloor: Int { Self.watts(ftp, Self.floorFraction) }
    var powerCeiling: Int { Self.watts(ftp, Self.ceilingFraction) }
    var startingPower: Int { Self.watts(ftp, Self.startFraction) }
}

extension RideSettings {
    // Tolerant decode so adding new fields never discards a user's saved settings.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = RideSettings()
        targetHeartRate = try container.decodeIfPresent(Int.self, forKey: .targetHeartRate) ?? defaults.targetHeartRate
        ftp = try container.decodeIfPresent(Int.self, forKey: .ftp) ?? defaults.ftp
        aggressiveness =
            try container.decodeIfPresent(ControlAggressiveness.self, forKey: .aggressiveness)
            ?? defaults.aggressiveness
        broadcastToZwift =
            try container.decodeIfPresent(Bool.self, forKey: .broadcastToZwift) ?? defaults.broadcastToZwift
        cadenceTarget = try container.decodeIfPresent(Int.self, forKey: .cadenceTarget) ?? defaults.cadenceTarget
        showCadenceGuide =
            try container.decodeIfPresent(Bool.self, forKey: .showCadenceGuide) ?? defaults.showCadenceGuide
    }
}

@Observable
final class SettingsStore {
    var targetHeartRate: Int
    var ftp: Int
    var aggressiveness: ControlAggressiveness
    var broadcastToZwift: Bool
    var cadenceTarget: Int
    var showCadenceGuide: Bool

    @ObservationIgnored private static let storageKey = "rideSettings"

    var powerFloor: Int { RideSettings.watts(ftp, RideSettings.floorFraction) }
    var powerCeiling: Int { RideSettings.watts(ftp, RideSettings.ceilingFraction) }
    var startingPower: Int { RideSettings.watts(ftp, RideSettings.startFraction) }

    init() {
        let loaded = SettingsStore.loadSnapshot() ?? RideSettings()
        targetHeartRate = loaded.targetHeartRate
        ftp = loaded.ftp
        aggressiveness = loaded.aggressiveness
        broadcastToZwift = loaded.broadcastToZwift
        cadenceTarget = loaded.cadenceTarget
        showCadenceGuide = loaded.showCadenceGuide
    }

    var snapshot: RideSettings {
        RideSettings(
            targetHeartRate: targetHeartRate,
            ftp: ftp,
            aggressiveness: aggressiveness,
            broadcastToZwift: broadcastToZwift,
            cadenceTarget: cadenceTarget,
            showCadenceGuide: showCadenceGuide)
    }

    func save() {
        if let data = try? JSONEncoder().encode(snapshot) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    private static func loadSnapshot() -> RideSettings? {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(RideSettings.self, from: data)
    }
}
