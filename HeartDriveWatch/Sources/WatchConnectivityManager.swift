import Foundation
import WatchConnectivity

/// Watch→phone heart-rate sender; this is the only link between the devices. Tools/LinkSim covers
/// context wedge, reachability flap, transient send failures, blackout, capture stall,
/// bursts, and 300 randomized runs.
///
/// Strategy:
///  - live HR over `sendMessage` when reachable (throttled to `liveInterval`); the phone
///    replies, which is the only reliable delivery confirmation
///  - a coalescing `updateApplicationContext` backstop runs at most once per `contextInterval`.
///    Driving it faster silently wedges the channel (rdar://21364664), the original bug
///  - self-heal: re-activate the session on a sustained delivery gap, and ask the owner
///    to restart the workout if delivery or HR capture stays dead, matching
///    what the manual Restart button does.
final class WatchConnectivityManager: NSObject {
    var onRequestRestart: (() -> Void)?

    private var session: WCSession?
    private var latest: HeartRate?
    private var tickTimer: Timer?

    private let liveInterval: TimeInterval = 1
    private let contextInterval: TimeInterval = 5
    private let reactivateAfter: TimeInterval = 8
    private let restartAfter: TimeInterval = 24
    private let captureStallAfter: TimeInterval = 20

    private var lastContextAt = -Double.infinity
    private var lastLiveSendAt = -Double.infinity
    private var lastDeliveredAt = -Double.infinity
    private var lastRecordAt = -Double.infinity
    private var lastReactivateAt = -Double.infinity

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        self.session = session
        session.delegate = self
        session.activate()
        tickTimer?.invalidate()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    /// Call on every new HR sample.
    func record(_ hr: HeartRate) {
        if let latest, hr.at <= latest.at { return }   // drop out-of-order / duplicate
        let t = now
        if latest == nil { lastDeliveredAt = t; lastReactivateAt = t }
        latest = hr
        lastRecordAt = t
        push(t)
    }

    private func tick() {
        let t = now
        push(t)
        heal(t)
    }

    private func push(_ t: TimeInterval) {
        guard let session, session.activationState == .activated, let hr = latest,
            let dict = WCSession.envelope(hr)
        else { return }
        if session.isReachable, t - lastLiveSendAt >= liveInterval {
            lastLiveSendAt = t
            session.sendMessage(dict, replyHandler: { [weak self] _ in
                guard let self else { return }
                DispatchQueue.main.async { self.lastDeliveredAt = self.now }
            }, errorHandler: { error in
                hrLog.error("watch: sendMessage failed: \(error.localizedDescription, privacy: .public)")
            })
        }
        if t - lastContextAt >= contextInterval {
            lastContextAt = t
            try? session.updateApplicationContext(dict)
        }
    }

    private func heal(_ t: TimeInterval) {
        // HR capture itself stalled (no new sample): only a fresh workout revives it.
        if lastRecordAt > -.infinity, t - lastRecordAt > captureStallAfter {
            hrLog.notice("watch: HR capture stalled → restart")
            onRequestRestart?()
            lastRecordAt = t
            return
        }
        guard latest != nil, let session else { return }
        let gap = t - lastDeliveredAt
        if session.isReachable {
            if gap > restartAfter {
                hrLog.notice("watch: live delivery dead \(Int(gap), privacy: .public)s → restart")
                onRequestRestart?()
                lastDeliveredAt = t
                lastReactivateAt = t
            } else if gap > reactivateAfter, t - lastReactivateAt > reactivateAfter {
                session.activate()
                lastReactivateAt = t
            }
        } else if t - lastReactivateAt > reactivateAfter {
            // Unreachable: the context backstop carries HR; nudge the session to try to
            // regain the live path, but never restart on unreachability alone.
            session.activate()
            lastReactivateAt = t
        }
    }
}

extension WatchConnectivityManager: WCSessionDelegate {
    func session(
        _ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?
    ) {}

    func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async { [weak self] in guard let self else { return }; self.push(self.now) }
    }
}
