import Foundation
import Observation
import WatchConnectivity

/// Watch side of the link: streams heart rate and workout state to the phone,
/// and receives start/stop commands plus ride status for display.
@Observable
final class WatchConnectivityManager: NSObject {
    private(set) var rideStatus: RideStatus?
    private(set) var isReachable = false

    /// The rider's "save ride to Health" choice, persisted so it survives a
    /// mid-ride watch relaunch (which clears the in-memory rideStatus). Defaults
    /// to false (discard) only if the phone has never sent a status this install.
    var saveWorkoutPreference: Bool {
        rideStatus?.saveWorkout ?? UserDefaults.standard.bool(forKey: Self.saveWorkoutKey)
    }

    @ObservationIgnored var onCommand: ((PhoneCommand) -> Void)?
    @ObservationIgnored var onReachable: (() -> Void)?

    private static let saveWorkoutKey = "hd.saveWorkout"
    private var session: WCSession?
    private var snapshotState: WorkoutState = .notStarted
    private var snapshotTarget: Int?

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        self.session = session
        session.delegate = self
        session.activate()
    }

    func sendHeartRate(_ sample: HeartRateSample) {
        guard let message = try? WatchMessage(.heartRate, sample) else { return }
        session?.deliver(message)
    }

    func updateWorkoutState(_ state: WorkoutState) {
        snapshotState = state
        sendSnapshot()
    }

    func updateTarget(_ bpm: Int) {
        snapshotTarget = bpm
        sendSnapshot()
    }

    /// Latest workout state + crown target → phone via application context:
    /// reliable + coalesced (watch→phone sendMessage/transferUserInfo isn't), with
    /// a fresh `sentAt` each time so the system never silently dedups it.
    private func sendSnapshot() {
        let snapshot = WatchSnapshot(sentAt: Date(), workoutState: snapshotState, target: snapshotTarget)
        guard let message = try? WatchMessage(.watchState, snapshot) else { return }
        try? session?.updateApplicationContext(message.dictionary)
    }

    private func handle(_ dictionary: [String: Any]) {
        guard let message = WatchMessage(dictionary: dictionary) else { return }
        DispatchQueue.main.async { [weak self] in
            switch message.type {
            case .command:
                if let command = message.decode(PhoneCommand.self) { self?.onCommand?(command) }
            case .rideStatus:
                if let status = message.decode(RideStatus.self) {
                    self?.rideStatus = status
                    if let save = status.saveWorkout {
                        UserDefaults.standard.set(save, forKey: Self.saveWorkoutKey)
                    }
                }
            case .heartRate, .watchState:
                break
            }
        }
    }
}

extension WatchConnectivityManager: WCSessionDelegate {
    func session(
        _ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?
    ) {
        let context = session.receivedApplicationContext
        if !context.isEmpty { handle(context) }
        DispatchQueue.main.async { [weak self] in
            self?.isReachable = session.isReachable
            if session.isReachable { self?.onReachable?() }
        }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async { [weak self] in
            self?.isReachable = session.isReachable
            if session.isReachable { self?.onReachable?() }
        }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) { handle(message) }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) { handle(userInfo) }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        handle(applicationContext)
    }
}
