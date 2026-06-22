import Foundation
import WatchConnectivity

/// Phone side: receives heart rate from the watch. That is the entire watch↔phone
/// The link is one-way, HR only. The phone never sends anything back to the watch.
final class PhoneConnectivity: NSObject {
    var onHeartRate: ((HeartRate) -> Void)?

    private var session: WCSession?
    private var lastRecvAt = -Double.infinity
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    private static var activations = 0

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        self.session = session
        session.delegate = self
        session.activate()
        Self.activations += 1
        hrLog.notice("phone WCSession activate #\(Self.activations, privacy: .public)")
    }

    private func receive(_ payload: [String: Any]) {
        guard let hr = WCSession.decode(HeartRate.self, from: payload) else { return }
        let t = now
        let gap = lastRecvAt > -.infinity ? Int(t - lastRecvAt) : 0
        lastRecvAt = t
        hrLog.notice(
            "phone recv bpm=\(Int(hr.bpm), privacy: .public) at=\(Int(hr.at.timeIntervalSince1970), privacy: .public) gap=\(gap, privacy: .public)s")
        DispatchQueue.main.async { [weak self] in self?.onHeartRate?(hr) }
    }
}

extension PhoneConnectivity: WCSessionDelegate {
    func session(
        _ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?
    ) {
        let context = session.receivedApplicationContext
        if !context.isEmpty { receive(context) }
    }

    func session(
        _ session: WCSession, didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        receive(message)
        replyHandler([:])   // ack; the watch's self-heal uses this as its delivery signal
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        receive(applicationContext)
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        hrLog.notice("phone: reachable→\(session.isReachable, privacy: .public)")
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
}
