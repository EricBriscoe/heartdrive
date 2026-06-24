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
    /// Called on the main queue when an accepted register update arrives from the phone.
    var onTargetChanged: ((Int) -> Void)?
    var onActiveChanged: ((Bool) -> Void)?

    /// Two-way last-write-wins sync. The watch authors the target via the Crown and the
    /// session-active intent via Start/Stop.
    let target = SyncedValue<Int>(me: .watch)
    let active = SyncedValue<Bool>(me: .watch)

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
        // Drop only an exact re-delivery of the sample we already hold (the workout builder
        // can re-emit the same statistic). Match on `==`, not a `<=` high-water mark: that
        // could latch on one anomalous timestamp and permanently reject the stream. This is the bug
        // that froze the phone hub. A restart clears this via `resetStream()`.
        if let latest, hr.at == latest.at { return }
        let t = now
        if latest == nil { lastDeliveredAt = t; lastReactivateAt = t }
        latest = hr
        lastRecordAt = t
        push(t)
    }

    /// Forget the current sample and delivery/heal state so a freshly-restarted (or stopped)
    /// workout's HR stream is treated as a clean start: no stale high-water mark to reject it,
    /// and no inherited delivery gap that would make `heal()` immediately re-fire.
    func resetStream() {
        latest = nil
        lastDeliveredAt = -.infinity
        lastRecordAt = -.infinity
        lastReactivateAt = -.infinity
    }

    /// A local target edit (Digital Crown). Bumps the register and pushes it promptly, with an
    /// immediate sendMessage nudge when reachable, plus the rate-limited context backstop. A
    /// no-op if unchanged, which is what stops a phone-synced value from echoing back.
    func setLocalTarget(_ bpm: Int) {
        guard target.setLocal(bpm) else { return }
        sendNudge()
        push(now)
    }

    /// A local Start/Stop on the watch. Bumps the session-active intent and pushes it.
    func setLocalActive(_ on: Bool) {
        guard active.setLocal(on) else { return }
        sendNudge()
        push(now)
    }

    /// Immediate best-effort nudge of the current registers over sendMessage when reachable;
    /// the rate-limited context backstop carries anything this misses.
    private func sendNudge() {
        guard let session, session.activationState == .activated, session.isReachable else { return }
        var dict: [String: Any] = [:]
        if let reg = target.register, let d = WCSession.encode(reg) { dict[WCKey.target] = d }
        if let reg = active.register, let d = WCSession.encode(reg) { dict[WCKey.active] = d }
        guard !dict.isEmpty else { return }
        session.sendMessage(dict, replyHandler: { _ in }, errorHandler: { _ in })
    }

    private func handleIncoming(_ payload: [String: Any]) {
        if let reg = WCSession.decode(Register<Int>.self, from: payload[WCKey.target]) {
            DispatchQueue.main.async { [weak self] in
                guard let self, let applied = self.target.receive(reg) else { return }
                self.onTargetChanged?(applied)
            }
        }
        if let reg = WCSession.decode(Register<Bool>.self, from: payload[WCKey.active]) {
            DispatchQueue.main.async { [weak self] in
                guard let self, let applied = self.active.receive(reg) else { return }
                self.onActiveChanged?(applied)
            }
        }
    }

    private func tick() {
        let t = now
        push(t)
        heal(t)
        if latest != nil, let session {
            let ackGap = Int(t - lastDeliveredAt), recGap = Int(t - lastRecordAt), reach = session.isReachable
            hrLog.debug("watch HB reach=\(reach, privacy: .public) ackGap=\(ackGap, privacy: .public)s recGap=\(recGap, privacy: .public)s")
        }
    }

    private func push(_ t: TimeInterval) {
        guard let session, session.activationState == .activated else { return }

        // The context backstop carries everything this device owns: HR and the target
        // register in one coalesced, rate-limited dictionary. A second context writer would
        // risk the over-1/5s wedge (rdar://21364664), so there is exactly one.
        var context: [String: Any] = [:]
        if let hr = latest, let d = WCSession.encode(hr) { context[WCKey.heartRate] = d }
        if let reg = target.register, let d = WCSession.encode(reg) { context[WCKey.target] = d }
        if let reg = active.register, let d = WCSession.encode(reg) { context[WCKey.active] = d }
        guard !context.isEmpty else { return }

        // Live HR nudge over sendMessage when reachable; the phone's reply is the delivery
        // signal. Throttled; the context backstop covers anything it misses.
        if let hr = latest, session.isReachable, t - lastLiveSendAt >= liveInterval,
            let d = WCSession.encode(hr) {
            lastLiveSendAt = t
            session.sendMessage([WCKey.heartRate: d], replyHandler: { [weak self] _ in
                guard let self else { return }
                DispatchQueue.main.async { self.lastDeliveredAt = self.now }
            }, errorHandler: { error in
                hrLog.error("watch: sendMessage failed: \(error.localizedDescription, privacy: .public)")
            })
        }

        if t - lastContextAt >= contextInterval {
            lastContextAt = t
            try? session.updateApplicationContext(context)
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
                hrLog.notice("watch: re-activate (reachable, ackGap \(Int(gap), privacy: .public)s)")
                session.activate()
                lastReactivateAt = t
            }
        } else if t - lastReactivateAt > reactivateAfter {
            // Unreachable: the context backstop carries HR; nudge the session to try to
            // regain the live path, but never restart on unreachability alone.
            hrLog.notice("watch: re-activate (unreachable, ackGap \(Int(gap), privacy: .public)s)")
            session.activate()
            lastReactivateAt = t
        }
    }
}

extension WatchConnectivityManager: WCSessionDelegate {
    func session(
        _ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?
    ) {
        let context = session.receivedApplicationContext
        if !context.isEmpty { handleIncoming(context) }
    }

    func session(
        _ session: WCSession, didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        handleIncoming(message)
        replyHandler([:])
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        handleIncoming(applicationContext)
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            hrLog.notice("watch: reachable→\(reachable, privacy: .public)")
            self.push(self.now)
        }
    }
}
