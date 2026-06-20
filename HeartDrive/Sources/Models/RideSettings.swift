import Foundation
import Observation

struct RideSettings: Codable, Equatable {
    var targetHeartRate: Int = 140
    var powerFloor: Int = 60
    var powerCeiling: Int = 200
    var startingPower: Int = 110
    var aggressiveness: ControlAggressiveness = .balanced
    var broadcastToZwift: Bool = false
    var cadenceTarget: Int = 90
    var showCadenceGuide: Bool = false
}

extension RideSettings {
    // Tolerant decode so adding new fields never discards a user's saved settings.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = RideSettings()
        targetHeartRate = try container.decodeIfPresent(Int.self, forKey: .targetHeartRate) ?? defaults.targetHeartRate
        powerFloor = try container.decodeIfPresent(Int.self, forKey: .powerFloor) ?? defaults.powerFloor
        powerCeiling = try container.decodeIfPresent(Int.self, forKey: .powerCeiling) ?? defaults.powerCeiling
        startingPower = try container.decodeIfPresent(Int.self, forKey: .startingPower) ?? defaults.startingPower
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
    var powerFloor: Int
    var powerCeiling: Int
    var startingPower: Int
    var aggressiveness: ControlAggressiveness
    var broadcastToZwift: Bool
    var cadenceTarget: Int
    var showCadenceGuide: Bool

    @ObservationIgnored private static let storageKey = "rideSettings"

    init() {
        let loaded = SettingsStore.loadSnapshot() ?? RideSettings()
        targetHeartRate = loaded.targetHeartRate
        powerFloor = loaded.powerFloor
        powerCeiling = loaded.powerCeiling
        startingPower = loaded.startingPower
        aggressiveness = loaded.aggressiveness
        broadcastToZwift = loaded.broadcastToZwift
        cadenceTarget = loaded.cadenceTarget
        showCadenceGuide = loaded.showCadenceGuide
    }

    var snapshot: RideSettings {
        RideSettings(
            targetHeartRate: targetHeartRate,
            powerFloor: powerFloor,
            powerCeiling: powerCeiling,
            startingPower: startingPower,
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
