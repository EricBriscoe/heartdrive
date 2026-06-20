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
    @ObservationIgnored var onWorkoutState: ((WorkoutStateUpdate) -> Void)?

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
        session?.deliver(message)
    }

    private func handle(_ dictionary: [String: Any]) {
        guard let message = WatchMessage(dictionary: dictionary) else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch message.type {
            case .heartRate:
                if let sample = message.decode(HeartRateSample.self) { self.onHeartRate?(sample) }
            case .workoutState:
                if let update = message.decode(WorkoutStateUpdate.self) {
                    self.watchWorkoutState = update.state
                    self.onWorkoutState?(update)
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

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
}
