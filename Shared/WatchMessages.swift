import Foundation
import WatchConnectivity

enum WatchMessageType: String, Codable {
    case heartRate
    case workoutState
    case command
    case rideStatus
}

struct HeartRateSample: Codable, Equatable {
    var bpm: Double
    var timestamp: Date
}

enum WorkoutState: String, Codable {
    case notStarted
    case running
    case paused
    case ended
}

struct WorkoutStateUpdate: Codable, Equatable {
    var state: WorkoutState
}

enum PhoneCommand: String, Codable {
    case startWorkout
    case stopWorkout
    case remirror  // re-establish the mirror for a running workout; never starts one
}

struct RideStatus: Codable, Equatable {
    var targetHeartRate: Int
    var targetPowerWatts: Int?
}

/// A type-tagged envelope that round-trips through WatchConnectivity's
/// `[String: Any]` dictionaries by carrying a JSON-encoded payload.
struct WatchMessage {
    static let typeKey = "t"
    static let dataKey = "d"

    let type: WatchMessageType
    let data: Data

    init(type: WatchMessageType, data: Data) {
        self.type = type
        self.data = data
    }

    init<T: Encodable>(_ type: WatchMessageType, _ payload: T) throws {
        self.type = type
        self.data = try JSONEncoder().encode(payload)
    }

    var dictionary: [String: Any] {
        [WatchMessage.typeKey: type.rawValue, WatchMessage.dataKey: data]
    }

    init?(dictionary: [String: Any]) {
        guard
            let rawType = dictionary[WatchMessage.typeKey] as? String,
            let type = WatchMessageType(rawValue: rawType),
            let data = dictionary[WatchMessage.dataKey] as? Data
        else { return nil }
        self.type = type
        self.data = data
    }

    func decode<T: Decodable>(_ kind: T.Type) -> T? {
        try? JSONDecoder().decode(kind, from: data)
    }
}

extension WCSession {
    /// Delivers live when the peer is reachable, otherwise queues for background
    /// delivery. Shared by both the phone and watch sides.
    func deliver(_ message: WatchMessage) {
        guard activationState == .activated else { return }
        let payload = message.dictionary
        if isReachable {
            // Live send; if it fails (e.g. the peer briefly backgrounded) fall
            // back to the queued path so samples aren't silently dropped.
            sendMessage(payload, replyHandler: nil) { _ in
                WCSession.default.transferUserInfo(payload)
            }
        } else {
            transferUserInfo(payload)
        }
    }
}
