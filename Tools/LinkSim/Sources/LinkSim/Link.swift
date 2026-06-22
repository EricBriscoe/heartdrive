import Foundation

// The resilient watch->phone heart-rate wrapper. Pure Foundation, tick-driven (no
// internal real timers), transport-injected, so it is deterministically testable
// against a simulated-flaky transport AND drops straight into the app over a real
// WCSession adapter. `at`/`now` are monotonic seconds, each device's own clock; `at`
// is only ever compared against other `at` values from the same sender, so the two
// devices' clocks need not agree.

public struct HeartRate: Equatable {
    public var bpm: Double
    public var at: TimeInterval
    public init(bpm: Double, at: TimeInterval) { self.bpm = bpm; self.at = at }
}

/// The flaky cross-device channel, abstracted. Real impl wraps WCSession; the sim
/// impl injects every documented failure mode.
public protocol HRTransport: AnyObject {
    var isActivated: Bool { get }
    var isReachable: Bool { get }
    func activate()
    /// Low-latency live send. Returns false if not delivered (unreachable/failed) so
    /// the sender has a real delivery signal.
    @discardableResult func sendMessage(_ hr: HeartRate) -> Bool
    /// Coalescing latest-value backstop, no delivery confirmation. MUST NOT be driven
    /// faster than ~1/5s or the channel silently wedges (rdar://21364664).
    func updateContext(_ hr: HeartRate)
}

/// Sender side (watch). Guarantees:
///  - never drives `updateContext` faster than `contextInterval` (can't wedge the channel)
///  - re-sends the latest value so a dropped/coalesced send self-heals next cycle
///  - escalates re-activate -> restart only when the LIVE path is failing while reachable,
///    or when HR capture itself has stalled, so it recovers without thrashing.
public final class HeartRateSender {
    public var onRequestRestart: (() -> Void)?

    private let transport: HRTransport
    public let contextInterval: TimeInterval
    private let liveInterval: TimeInterval
    private let reactivateAfter: TimeInterval
    private let restartAfter: TimeInterval
    private let captureStallAfter: TimeInterval
    private let enableHealing: Bool

    private var latest: HeartRate?
    private var lastContextAt = -Double.infinity
    private var lastLiveSendAt = -Double.infinity
    private var lastLiveAt = -Double.infinity
    private var lastReactivateAt = -Double.infinity
    private var lastRecordAt = -Double.infinity

    public init(transport: HRTransport,
                contextInterval: TimeInterval = 5,
                liveInterval: TimeInterval = 1,
                reactivateAfter: TimeInterval = 8,
                restartAfter: TimeInterval = 24,
                captureStallAfter: TimeInterval = 20,
                enableHealing: Bool = true) {
        self.transport = transport
        self.contextInterval = contextInterval
        self.liveInterval = liveInterval
        self.reactivateAfter = reactivateAfter
        self.restartAfter = restartAfter
        self.captureStallAfter = captureStallAfter
        self.enableHealing = enableHealing
    }

    /// Call on every new HR sample.
    public func record(_ hr: HeartRate, now: TimeInterval) {
        if let latest, hr.at <= latest.at { return }   // drop out-of-order / duplicate
        if latest == nil { lastLiveAt = now; lastReactivateAt = now }
        latest = hr
        lastRecordAt = now
        send(now: now)
    }

    /// Call periodically (~2s) to backstop and self-heal even if samples pause.
    public func tick(now: TimeInterval) {
        send(now: now)
        if enableHealing { heal(now: now) }
    }

    private func send(now: TimeInterval) {
        guard transport.isActivated, let hr = latest else { return }
        if transport.isReachable, now - lastLiveSendAt >= liveInterval {
            lastLiveSendAt = now
            if transport.sendMessage(hr) { lastLiveAt = now }
        }
        if now - lastContextAt >= contextInterval {
            transport.updateContext(hr)
            lastContextAt = now
        }
    }

    private func heal(now: TimeInterval) {
        // HR capture itself stalled (no new sample): restart the workout to revive it.
        if lastRecordAt > -Double.infinity, now - lastRecordAt > captureStallAfter {
            onRequestRestart?()
            lastRecordAt = now
            return
        }
        guard latest != nil else { return }
        if transport.isReachable {
            // We can send live but it isn't landing, which is a real, recoverable fault.
            let gap = now - lastLiveAt
            if gap > restartAfter {
                onRequestRestart?()
                lastLiveAt = now
                lastReactivateAt = now
            } else if gap > reactivateAfter, now - lastReactivateAt > reactivateAfter {
                transport.activate()
                lastReactivateAt = now
            }
        } else if now - lastReactivateAt > reactivateAfter {
            // Unreachable: the context backstop is carrying HR; just nudge the session to
            // try to regain the live path. Never restart on unreachability alone.
            transport.activate()
            lastReactivateAt = now
        }
    }
}

/// Receiver side (phone). De-duplicates by sample time and tracks freshness; the
/// "never stuck" guarantee lives here: control consumes HR only while fresh.
public final class HeartRateReceiver {
    public private(set) var bpm: Double?
    public private(set) var lastUpdate = -Double.infinity
    private var lastSampleAt = -Double.infinity
    public let staleAfter: TimeInterval

    public init(staleAfter: TimeInterval = 12) { self.staleAfter = staleAfter }

    public func ingest(_ hr: HeartRate, now: TimeInterval) {
        if hr.at <= lastSampleAt { return }   // dedup / ordering
        lastSampleAt = hr.at
        bpm = hr.bpm
        lastUpdate = now
    }

    public func isFresh(now: TimeInterval) -> Bool { now - lastUpdate < staleAfter }
}
