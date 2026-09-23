import Foundation
import WatchConnectivity
import os

/// One coalesced application-context writer per device carries all these keys.
enum WCKey {
    static let heartRate = "hr"
    static let target = "cfg"
    static let active = "run"
}

extension WCSession {
    static func encode<T: Encodable>(_ value: T) -> Data? {
        try? JSONEncoder().encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from value: Any?) -> T? {
        guard let data = value as? Data else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

/// Stream with: log stream --predicate 'subsystem == "com.ericbriscoe.HeartDrive"'.
let hrLog = Logger(subsystem: "com.ericbriscoe.HeartDrive", category: "hr")
