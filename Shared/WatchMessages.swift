import Foundation
import WatchConnectivity
import os

/// The only thing that crosses the watch↔phone boundary: a heart-rate reading, streamed
/// one-way (watch→phone). `at` is the sample's measurement time; the phone orders and
/// de-duplicates by it, and it makes each fresh payload unique so the coalescing context
/// channel never silently drops a new value.
struct HeartRate: Codable, Equatable {
    var bpm: Double
    var at: Date
}

extension WCSession {
    private static let payloadKey = "s"

    static func envelope<T: Encodable>(_ value: T) -> [String: Any]? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return [payloadKey: data]
    }

    static func decode<T: Decodable>(_ type: T.Type, from payload: [String: Any]) -> T? {
        guard let data = payload[payloadKey] as? Data else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

/// Shared os_log channel so the HR feed can be verified on-device. Stream with:
/// `log stream --predicate 'subsystem == "com.ericbriscoe.HeartDrive"'`.
let hrLog = Logger(subsystem: "com.ericbriscoe.HeartDrive", category: "hr")
