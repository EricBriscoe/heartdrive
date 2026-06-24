import Foundation
import WatchConnectivity

/// Phone side of the watch link: receives heart rate from the watch (one-way) and two-way-syncs
/// the target heart rate and the Start/Stop state in last-write-wins `Register`s carried both
/// directions. HR is high-rate; the target and active intent change at human rate.
final class PhoneConnectivity: NSObject {
    var onHeartRate: ((HeartRate) -> Void)?
    /// Called on the main queue when an accepted register update arrives from the watch.
    var onTargetChanged: ((Int) -> Void)?
    var onActiveChanged: ((Bool) -> Void)?

    /// Two-way LWW sync: the phone authors the target via its UI and the session-active intent
    /// via Start/Stop.
    let target = SyncedValue<Int>(me: .phone)
    let active = SyncedValue<Bool>(me: .phone)

    private var session: WCSession?
    private var lastRecvAt = -Double.infinity
    private var lastContextAt = -Double.infinity
    private let contextInterval: TimeInterval = 5
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    private static var activations = 0

    /// Adopt the persisted target before activating, so the first context write seeds the watch.
    func seedTarget(_ bpm: Int) { target.seed(bpm) }

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        self.session = session
        session.delegate = self
        session.activate()
        Self.activations += 1
        hrLog.notice("phone WCSession activate #\(Self.activations, privacy: .public)")
    }

    /// A local target edit on the phone (any UI). Bumps the register and sends it; no-ops if the
    /// value is unchanged, so applying a watch-synced value can't echo back.
    func sendLocalTarget(_ bpm: Int) {
        guard target.setLocal(bpm) else { return }
        sendState()
    }

    /// A local Start/Stop on the phone. Bumps the session-active intent and sends it.
    func sendLocalActive(_ on: Bool) {
        guard active.setLocal(on) else { return }
        sendState()
    }

    /// Send the current registers (target + active) to the watch. Hops to main so all `sync`
    /// access stays single-threaded. Best-effort live nudge when reachable + a rate-limited
    /// context backstop (one context writer per device; never reopen the rdar wedge).
    private func sendState() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let session = self.session, session.activationState == .activated
            else { return }
            var dict: [String: Any] = [:]
            if let reg = self.target.register, let d = WCSession.encode(reg) { dict[WCKey.target] = d }
            if let reg = self.active.register, let d = WCSession.encode(reg) { dict[WCKey.active] = d }
            guard !dict.isEmpty else { return }
            if session.isReachable {
                session.sendMessage(dict, replyHandler: { _ in }, errorHandler: { _ in })
            }
            let t = self.now
            if t - self.lastContextAt >= self.contextInterval {
                self.lastContextAt = t
                try? session.updateApplicationContext(dict)
            }
        }
    }

    private func receive(_ payload: [String: Any]) {
        if let hr = WCSession.decode(HeartRate.self, from: payload[WCKey.heartRate]) {
            let t = now
            let gap = lastRecvAt > -.infinity ? Int(t - lastRecvAt) : 0
            lastRecvAt = t
            hrLog.debug(
                "phone recv bpm=\(Int(hr.bpm), privacy: .public) at=\(Int(hr.at.timeIntervalSince1970), privacy: .public) gap=\(gap, privacy: .public)s")
            DispatchQueue.main.async { [weak self] in self?.onHeartRate?(hr) }
        }
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
}

extension PhoneConnectivity: WCSessionDelegate {
    func session(
        _ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?
    ) {
        let context = session.receivedApplicationContext
        if !context.isEmpty { receive(context) }
        sendState()   // offer our current target + active; delivered on the watch's next wake
    }

    func session(
        _ session: WCSession, didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        receive(message)
        replyHandler([:])   // ack; the watch's HR self-heal uses this as its delivery signal
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        receive(applicationContext)
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        hrLog.notice("phone: reachable→\(session.isReachable, privacy: .public)")
        if session.isReachable { sendState() }   // re-offer when the watch comes online
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
}
