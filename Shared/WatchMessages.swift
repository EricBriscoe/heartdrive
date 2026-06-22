import Foundation
import WatchConnectivity
import os

/// The only thing that crosses the watch↔phone boundary: a heart-rate reading,
/// streamed one-way (watch→phone). `at` is the sample's measurement time; the phone
/// orders and de-duplicates by it, and `sentAt` makes each application-context payload
/// unique so the system never silently drops a repeat.
struct HeartRate: Codable, Equatable {
    var bpm: Double
    var at: Date
    var sentAt: Date
}

extension WCSession {
    private static let payloadKey = "s"

    static func envelope<T: Encodable>(_ value: T) -> [String: Any]? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return [payloadKey: data]
    }

    /// Publish the latest value as application context: coalescing, background-capable,
    /// reachability-free: the self-healing backstop behind the live `sendMessage` path.
    func push<T: Encodable>(_ value: T) {
        guard activationState == .activated, let dict = WCSession.envelope(value) else { return }
        try? updateApplicationContext(dict)
    }

    static func decode<T: Decodable>(_ type: T.Type, from payload: [String: Any]) -> T? {
        guard let data = payload[payloadKey] as? Data else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

/// Shared os_log channel so we can verify on-device that HR flows
/// (watch push → phone receive) instead of shipping blind builds. Stream with:
/// `log stream --predicate 'subsystem == "com.ericbriscoe.HeartDrive"'`.
let hrLog = Logger(subsystem: "com.ericbriscoe.HeartDrive", category: "hr")

/// Coalesces bursty calls to at most one action per `interval` (leading edge + a single
/// trailing fire carrying the latest value). HKLiveWorkoutBuilder delivers HR in
/// sub-second bursts, and pushing WCSession faster than ~1/s is documented to wedge the
/// channel into a multi-second stall (rdar://21364664); this gate prevents that.
/// Main-thread only.
final class Throttle {
    private let interval: TimeInterval
    private let action: () -> Void
    private var lastRun = Date.distantPast
    private var trailing: Timer?

    init(interval: TimeInterval, action: @escaping () -> Void) {
        self.interval = interval
        self.action = action
    }

    func call() {
        let elapsed = Date().timeIntervalSince(lastRun)
        if elapsed >= interval {
            run()
        } else if trailing == nil {
            let timer = Timer(timeInterval: interval - elapsed, repeats: false) { [weak self] _ in self?.run() }
            RunLoop.main.add(timer, forMode: .common)
            trailing = timer
        }
    }

    private func run() {
        lastRun = Date()
        trailing?.invalidate()
        trailing = nil
        action()
    }
}
