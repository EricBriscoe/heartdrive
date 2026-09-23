import Foundation
import WatchConnectivity

/// WCSession adapter for the production HeartRateLink policy exercised by LinkSim.
/// All mutable state is confined to the main queue. There is one coalesced context
/// writer for HR and settings, so separate updates cannot exceed the channel limit.
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
    private var link = HeartRateLink()
    private var tickTimer: Timer?

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
        let t = now
        guard link.record(hr, now: t) else { return }
        push(t)
    }

    /// Forget the current sample and delivery/heal state so a freshly-restarted (or stopped)
    /// workout's HR stream is treated as a clean start: no stale high-water mark to reject it,
    /// and no inherited delivery gap that would make `heal()` immediately re-fire.
    func resetStream() {
        link.reset()
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
        if link.latest != nil, let session {
            let ackGap = Int(t - link.lastDeliveredAt), recGap = Int(t - link.lastRecordAt), reach = session.isReachable
            hrLog.debug("watch HB reach=\(reach, privacy: .public) ackGap=\(ackGap, privacy: .public)s recGap=\(recGap, privacy: .public)s")
        }
    }

    private func push(_ t: TimeInterval) {
        guard let session, session.activationState == .activated else { return }

        // The context backstop carries everything this device owns: HR and the target
        // register in one coalesced, rate-limited dictionary. A second context writer would
        // risk the over-1/5s wedge (rdar://21364664), so there is exactly one.
        var context: [String: Any] = [:]
        if let hr = link.latest, let d = WCSession.encode(hr) { context[WCKey.heartRate] = d }
        if let reg = target.register, let d = WCSession.encode(reg) { context[WCKey.target] = d }
        if let reg = active.register, let d = WCSession.encode(reg) { context[WCKey.active] = d }
        guard !context.isEmpty else { return }

        // Live HR nudge over sendMessage when reachable; the phone's reply is the delivery
        // signal. Throttled; the context backstop covers anything it misses.
        let send = link.send(now: t, activated: true, reachable: session.isReachable,
                             hasRegisters: target.register != nil || active.register != nil)
        let generation = link.generation
        if let hr = send.live, let d = WCSession.encode(hr) {
            session.sendMessage([WCKey.heartRate: d], replyHandler: { [weak self] _ in
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.link.delivered(now: self.now, generation: generation)
                }
            }, errorHandler: { error in
                hrLog.error("watch: sendMessage failed: \(error.localizedDescription, privacy: .public)")
            })
        }

        if send.context { try? session.updateApplicationContext(context) }
    }

    private func heal(_ t: TimeInterval) {
        switch link.recover(now: t, reachable: session?.isReachable ?? false) {
        case .restart:
            hrLog.notice("watch: HR capture or live delivery stalled → restart")
            onRequestRestart?()
        case .reactivate:
            session?.activate()
        case nil:
            break
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
