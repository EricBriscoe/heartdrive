import Foundation
import WatchConnectivity

/// Watch→phone heart-rate sender; this is the only link between the devices. Coalesces to
/// ≤1 send / 1.5s (pushing WCSession faster wedges it), live over `sendMessage` (the
/// watch stays reachable during a workout) with an `updateApplicationContext` backstop
/// that self-heals a dropped send. It never receives anything from the phone.
final class WatchConnectivityManager: NSObject {
    private var session: WCSession?
    private var latest: HeartRate?
    private var throttle: Throttle?
    private var backstopTimer: Timer?

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        self.session = session
        session.delegate = self
        session.activate()
        throttle = Throttle(interval: 1.5) { [weak self] in self?.emit() }
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in self?.backstop() }
        RunLoop.main.add(timer, forMode: .common)
        backstopTimer = timer
    }

    /// Safe to call on every HR sample; the throttle caps the WCSession rate.
    func send(_ hr: HeartRate) {
        latest = hr
        throttle?.call()
    }

    private func emit() {
        guard let session, let hr = latest, session.activationState == .activated,
            let dict = WCSession.envelope(hr)
        else { return }
        hrLog.notice("watch→phone bpm=\(Int(hr.bpm), privacy: .public) reachable=\(session.isReachable, privacy: .public)")
        if session.isReachable {
            session.sendMessage(dict, replyHandler: nil) { _ in
                try? WCSession.default.updateApplicationContext(dict)
            }
        } else {
            try? session.updateApplicationContext(dict)
        }
    }

    private func backstop() {
        guard let session, let hr = latest else { return }
        session.push(hr)
    }
}

extension WatchConnectivityManager: WCSessionDelegate {
    func session(
        _ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?
    ) {}

    func sessionReachabilityDidChange(_ session: WCSession) {
        // Re-send the latest reading the moment the link comes back.
        DispatchQueue.main.async { [weak self] in self?.throttle?.call() }
    }
}
