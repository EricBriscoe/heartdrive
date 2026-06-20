import Foundation
import Observation

@Observable
final class WatchModel {
    static let shared = WatchModel()

    let workout = WatchWorkoutManager()
    let connectivity = WatchConnectivityManager()

    var isRunning: Bool { workout.isRunning }

    private init() {
        workout.onHeartRate = { [weak self] sample in
            self?.connectivity.sendHeartRate(sample)
        }
        workout.onStateChange = { [weak self] state in
            self?.connectivity.updateWorkoutState(state)
        }
        connectivity.onCommand = { [weak self] command in
            switch command {
            case .startWorkout: self?.workout.ensureActive()
            case .stopWorkout: self?.stop()
            case .recoverMirror: self?.workout.hardRemirror()  // phone isn't getting HR; rebuild the mirror
            }
        }
        // When the phone reconnects (e.g. after a restart), just re-announce that a
        // workout is running. Re-mirroring is left to the phone's recovery kick when
        // it isn't receiving HR, so a healthy mirror isn't torn down on
        // every wrist-raise (which flaps reachability).
        connectivity.onReachable = { [weak self] in
            guard let self, self.workout.isRunning else { return }
            self.connectivity.updateWorkoutState(.running)
        }
        connectivity.activate()
        workout.requestAuthorization()
    }

    func start() { workout.start() }
    func stop() { workout.end(save: connectivity.saveWorkoutPreference) }
    func setTargetHeartRate(_ bpm: Int) { connectivity.updateTarget(bpm) }
}
