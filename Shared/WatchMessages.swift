import Foundation
import WatchConnectivity
import os

/// A heart-rate reading, streamed one-way (watch→phone). `at` is the sample's measurement
/// time. The phone orders and deduplicates by it, keeping each fresh payload unique
/// so the coalescing context channel never silently drops a new value.
struct HeartRate: Codable, Equatable {
    var bpm: Double
    var at: Date
}

/// Which device authored a synced value. Ordered so the phone wins a genuine simultaneous
/// edit (it owns the control loop): `.watch < .phone`.
enum SyncDevice: String, Codable, Comparable {
    case watch
    case phone
    static func < (a: SyncDevice, b: SyncDevice) -> Bool { a == .watch && b == .phone }
}

/// A last-write-wins register for one two-way-synced scalar setting (e.g. target heart rate),
/// carried in both directions across the link. Ordered by a **monotonic version counter**,
/// not a wall-clock timestamp: the phone and watch clocks drift independently, so physical
/// time can't be trusted to decide which write is newer. `origin` breaks version ties.
struct Register<Value: Codable & Equatable>: Codable, Equatable {
    var value: Value
    var version: UInt64
    var origin: SyncDevice

    /// Fold `incoming` into self; returns true iff this changed local state. The rule is a
    /// total order on (version, origin), making the merge commutative, associative, and
    /// idempotent, so reordering and re-delivery are harmless and can never latch.
    mutating func merge(_ incoming: Register) -> Bool {
        let newer = incoming.version > version
            || (incoming.version == version && origin < incoming.origin)
        guard newer else { return false }
        self = incoming
        return true
    }
}

/// Drives a single two-way-synced scalar. Local edits bump the version and must be sent;
/// received registers are merged and applied but never bumped or re-sent; that asymmetry is
/// what structurally prevents echo loops (no timers, no "applying remote" flags). Not
/// thread-safe by design: each owner confines all access to the main queue.
final class SyncedValue<Value: Codable & Equatable> {
    private(set) var register: Register<Value>?
    private let me: SyncDevice
    private var lastSeenPeerVersion: UInt64 = 0

    init(me: SyncDevice) { self.me = me }

    /// Adopt an initial value without sending (e.g. the phone seeding from persisted settings
    /// at launch). Seeded weak (version 0) so any genuine edit on either device supersedes it.
    func seed(_ value: Value) {
        if register == nil { register = Register(value: value, version: 0, origin: me) }
    }

    /// A local edit. Returns true iff the value changed (caller then sends).
    func setLocal(_ value: Value) -> Bool {
        if register?.value == value { return false }
        let next = max(register?.version ?? 0, lastSeenPeerVersion) + 1
        register = Register(value: value, version: next, origin: me)
        return true
    }

    /// A register arrived from the peer. Returns the new value iff local state changed (caller
    /// applies it but must not send because received updates don't echo).
    func receive(_ incoming: Register<Value>) -> Value? {
        lastSeenPeerVersion = max(lastSeenPeerVersion, incoming.version)
        if register == nil {
            register = incoming
            return incoming.value
        }
        return register!.merge(incoming) ? register!.value : nil
    }
}

/// Keys for the multiplexed WCSession payloads. A single application-context dictionary can
/// carry several at once; there is exactly one rate-limited context writer per device, so a
/// second one can't reopen the over-1/5s wedge (rdar://21364664).
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

/// Shared os_log channel so the link can be verified on-device. Stream with:
/// `log stream --predicate 'subsystem == "com.ericbriscoe.HeartDrive"'`.
let hrLog = Logger(subsystem: "com.ericbriscoe.HeartDrive", category: "hr")
