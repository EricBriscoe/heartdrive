import Foundation
import Observation
import WatchConnectivity

/// Phone side of the watch link. Receives heart-rate samples and workout-state
/// updates from the watch app, and sends start/stop commands plus ride status
/// back for the watch to display.
@Observable
final class PhoneConnectivity: NSObject {
    private(set) var isReachable = false
    private(set) var watchWorkoutState: WorkoutState = .notStarted
    private(set) var lastError: String?

    @ObservationIgnored var onHeartRate: ((HeartRateSample) -> Void)?
    @ObservationIgnored var onWorkoutState: ((WorkoutState) -> Void)?
    @ObservationIgnored var onTargetHeartRate: ((Int) -> Void)?

    private var session: WCSession?

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        self.session = session
        session.delegate = self
        session.activate()
    }

    func send(command: PhoneCommand) {
        guard let message = try? WatchMessage(.command, command) else { return }
        session?.deliver(message)
    }

    func send(status: RideStatus) {
        guard let message = try? WatchMessage(.rideStatus, status) else { return }
        // Application context, not sendMessage: it coalesces to the latest value,
        // needs no reachability, and never backs up a queue, so 5s status updates
        // can't flood the watch↔phone link that the HealthKit HR mirror rides on.
        try? session?.updateApplicationContext(message.dictionary)
    }

    /// `driveControl` is false for the context read on activation: that value is
    /// persisted state and may be stale, so it only refreshes the target + display
    /// It must never drive start/stop. Live deltas drive control.
    private func handle(_ dictionary: [String: Any], driveControl: Bool = true) {
        guard let message = WatchMessage(dictionary: dictionary) else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch message.type {
            case .heartRate:
                if let sample = message.decode(HeartRateSample.self) { self.onHeartRate?(sample) }
            case .watchState:
                if let snapshot = message.decode(WatchSnapshot.self) {
                    self.watchWorkoutState = snapshot.workoutState
                    if let target = snapshot.target { self.onTargetHeartRate?(target) }
                    if driveControl { self.onWorkoutState?(snapshot.workoutState) }
                }
            case .command, .rideStatus:
                break
            }
        }
    }
}

extension PhoneConnectivity: WCSessionDelegate {
    func session(
        _ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?
    ) {
        let context = session.receivedApplicationContext
        if !context.isEmpty { handle(context, driveControl: false) }
        DispatchQueue.main.async { [weak self] in
            self?.isReachable = session.isReachable
            if let error { self?.lastError = error.localizedDescription }
        }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async { [weak self] in self?.isReachable = session.isReachable }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        handle(message)
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        handle(userInfo)
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        handle(applicationContext)
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
}
