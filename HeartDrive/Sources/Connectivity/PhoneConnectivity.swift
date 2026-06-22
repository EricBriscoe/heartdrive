import Foundation
import WatchConnectivity

/// Phone side: receives heart rate from the watch. That is the entire watch↔phone
/// The link is one-way, HR only. The phone never sends anything back to the watch.
final class PhoneConnectivity: NSObject {
    var onHeartRate: ((HeartRate) -> Void)?

    private var session: WCSession?

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        self.session = session
        session.delegate = self
        session.activate()
    }

    private func receive(_ payload: [String: Any]) {
        guard let hr = WCSession.decode(HeartRate.self, from: payload) else { return }
        hrLog.notice("phone recv bpm=\(Int(hr.bpm), privacy: .public)")
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

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) { receive(message) }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        receive(applicationContext)
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
}
