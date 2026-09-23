import Foundation

/// A WCSession-shaped transport that injects every documented failure mode so we can
/// adversarially try to break the wrapper:
///  - `reachable` toggling (sendMessage only works when reachable)
///  - `sendMessageWorks` transient failures even while reachable
///  - `blackout` total channel down (neither path delivers); this models a hard wedge/reboot-only
///  - the CONTEXT WEDGE: driving `updateContext` faster than `wedgeMinInterval` builds
///    pressure and silently wedges context delivery until the session is re-activated
///    (the exact rdar://21364664 behavior that caused "works then stalls").
final class FlakyTransport {
    public var clock: () -> TimeInterval = { 0 }
    public var onDeliver: ((HeartRate) -> Void)?

    public var isActivated = false
    public var reachable = true
    public var sendMessageWorks = true
    public var blackout = false
    public var wedgeMinInterval: TimeInterval = 4.0
    public var wedgePressureLimit = 2
    public var contextLatency: TimeInterval = 1.5

    public private(set) var wedged = false
    public private(set) var contextCalls = 0
    public private(set) var sendMessageCalls = 0
    private var lastContextAt = -Double.infinity
    private var pressure = 0
    private var pending: (hr: HeartRate, at: TimeInterval)?

    public var isReachable: Bool { reachable && !blackout && isActivated }

    public func activate() {
        isActivated = true
        if !blackout { wedged = false; pressure = 0 }   // re-activation clears a soft wedge
    }

    func sendMessage(_ hr: HeartRate, delivered: @escaping (TimeInterval) -> Void) {
        sendMessageCalls += 1
        guard isActivated, reachable, !blackout, sendMessageWorks else { return }
        onDeliver?(hr)
        pendingAcks.append((clock() + acknowledgementLatency, delivered))
    }

    var acknowledgementLatency: TimeInterval = 0
    private var pendingAcks: [(at: TimeInterval, deliver: (TimeInterval) -> Void)] = []

    public func updateContext(_ hr: HeartRate) {
        guard isActivated else { return }
        contextCalls += 1
        let now = clock()
        if now - lastContextAt < wedgeMinInterval {
            pressure += 1
            if pressure > wedgePressureLimit { wedged = true }
        } else {
            pressure = max(0, pressure - 1)
        }
        lastContextAt = now
        guard !wedged, !blackout else { return }
        pending = (hr, now + contextLatency)   // coalescing: latest only
    }

    /// Driver pumps due context deliveries.
    public func pump(now: TimeInterval) {
        let due = pendingAcks.filter { $0.at <= now }
        pendingAcks.removeAll { $0.at <= now }
        if !blackout { due.forEach { $0.deliver(now) } }
        if let p = pending, p.at <= now {
            pending = nil
            if !blackout { onDeliver?(p.hr) }
        }
    }
}
