import Foundation
import WatchConnectivity

/// Phone side of the watch link: receives heart rate from the watch (one-way) and
/// two-way-syncs the target heart rate in a last-write-wins `Register` carried both
/// directions. HR is high-rate; the target changes at human rate.
final class PhoneConnectivity: NSObject {
    var onHeartRate: ((HeartRate) -> Void)?
    /// Called on the main queue when an accepted target-register update arrives from the watch.
    var onTargetChanged: ((Int) -> Void)?

    /// Two-way LWW sync of the target heart rate (phone authors via its UI).
    let sync = TargetSync(me: .phone)

    private var session: WCSession?
    private var lastRecvAt = -Double.infinity
    private var lastContextAt = -Double.infinity
    private let contextInterval: TimeInterval = 5
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    private static var activations = 0

    /// Adopt the persisted target before activating, so the first context write seeds the watch.
    func seedTarget(_ bpm: Int) { sync.seed(bpm) }

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        self.session = session
        session.delegate = self
        session.activate()
        Self.activations += 1
        hrLog.notice("phone WCSession activate #\(Self.activations, privacy: .public)")
    }

    /// A local target edit on the phone (any UI). Bumps the register and sends it; no-ops if
    /// the value is unchanged, so applying a watch-synced value can't echo back.
    func sendLocalTarget(_ bpm: Int) {
        guard sync.setLocal(bpm) else { return }
        sendTarget()
    }

    /// Send the current target register to the watch. Hops to main so all `sync` access stays
    /// single-threaded. Best-effort live nudge when reachable + a rate-limited context backstop.
    private func sendTarget() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let session = self.session, session.activationState == .activated,
                let reg = self.sync.register, let d = WCSession.encode(reg)
            else { return }
            if session.isReachable {
                session.sendMessage([WCKey.target: d], replyHandler: { _ in }, errorHandler: { _ in })
            }
            let t = self.now
            if t - self.lastContextAt >= self.contextInterval {
                self.lastContextAt = t
                try? session.updateApplicationContext([WCKey.target: d])
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
                guard let self, let applied = self.sync.receive(reg) else { return }
                self.onTargetChanged?(applied)
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
        sendTarget()   // offer our current target; delivered on the watch's next wake if needed
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
        if session.isReachable { sendTarget() }   // re-offer the target when the watch comes online
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
}
