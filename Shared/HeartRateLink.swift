import Foundation

/// Watch-side timing and recovery policy. Both WCSession and LinkSim drive this
/// state machine with a monotonic clock; sample dates are never used as that clock.
struct HeartRateLink {
    enum Recovery { case reactivate, restart }
    struct Send {
        var live: HeartRate?
        var context = false
    }

    private(set) var latest: HeartRate?
    private(set) var lastDeliveredAt = -Double.infinity
    private(set) var lastRecordAt = -Double.infinity
    private var lastContextAt = -Double.infinity
    private var lastLiveSendAt = -Double.infinity
    private var lastReactivateAt = -Double.infinity
    private(set) var generation: UInt64 = 0

    // Overridable only to reproduce the historical context-wedge failure in tests.
    var contextInterval: TimeInterval = 5

    mutating func record(_ hr: HeartRate, now: TimeInterval) -> Bool {
        // Only exact duplicates are suppressed: a future timestamp must not latch
        // the stream. The phone validates measurement age independently.
        if latest?.at == hr.at { return false }
        if latest == nil { lastDeliveredAt = now; lastReactivateAt = now }
        latest = hr
        lastRecordAt = now
        return true
    }

    mutating func reset() {
        latest = nil
        lastDeliveredAt = -.infinity
        lastRecordAt = -.infinity
        lastReactivateAt = -.infinity
        generation &+= 1
        // Keep send cadence across restarts: resetting it can wedge context delivery.
    }

    mutating func delivered(now: TimeInterval, generation: UInt64) {
        guard generation == self.generation, latest != nil else { return }
        lastDeliveredAt = now
    }

    mutating func send(now: TimeInterval, activated: Bool, reachable: Bool, hasRegisters: Bool) -> Send {
        guard activated, latest != nil || hasRegisters else { return Send() }
        var result = Send()
        if let latest, reachable, now - lastLiveSendAt >= 1 {
            lastLiveSendAt = now
            result.live = latest
        }
        if now - lastContextAt >= contextInterval {
            lastContextAt = now
            result.context = true
        }
        return result
    }

    mutating func recover(now: TimeInterval, reachable: Bool) -> Recovery? {
        if lastRecordAt > -.infinity, now - lastRecordAt > 20 {
            lastRecordAt = now
            return .restart
        }
        guard latest != nil else { return nil }
        let gap = now - lastDeliveredAt
        if reachable, gap > 24 {
            lastDeliveredAt = now
            lastReactivateAt = now
            return .restart
        }
        if (!reachable || gap > 8), now - lastReactivateAt > 8 {
            lastReactivateAt = now
            return .reactivate
        }
        return nil
    }
}
