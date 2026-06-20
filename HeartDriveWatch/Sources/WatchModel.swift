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
            self?.connectivity.sendWorkoutState(state)
        }
        connectivity.onCommand = { [weak self] command in
            switch command {
            case .startWorkout: self?.workout.ensureActive()
            case .stopWorkout: self?.stop()
            case .remirror: self?.workout.remirror()
            }
        }
        // When the phone reconnects (e.g. after a restart), re-announce that a
        // workout is running and re-establish the mirror so HR re-attaches.
        connectivity.onReachable = { [weak self] in
            guard let self, self.workout.isRunning else { return }
            self.connectivity.sendWorkoutState(.running)
            self.workout.ensureActive()
        }
        connectivity.activate()
        workout.requestAuthorization()
    }

    func start() { workout.start() }
    func stop() { workout.end() }
}
