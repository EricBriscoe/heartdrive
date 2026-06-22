import Foundation
import Observation

/// The watch is a heart-rate sensor with a Start/Stop button. It runs the workout
/// (which captures HR + keeps the app alive screen-off) and streams HR one-way to the
/// phone. It holds no target, receives nothing, and does no control; all of that lives
/// on the phone.
@Observable
final class WatchModel {
    static let shared = WatchModel()

    let workout = WatchWorkoutManager()
    @ObservationIgnored let connectivity = WatchConnectivityManager()

    var isRunning: Bool { workout.isRunning }
    var currentBPM: Double? { workout.currentBPM }

    private init() {
        workout.onHeartRate = { [weak self] in self?.sendHeartRate() }
        connectivity.activate()
        workout.requestAuthorization()
    }

    private func sendHeartRate() {
        guard let bpm = workout.currentBPM, let at = workout.currentSampleAt else { return }
        connectivity.send(HeartRate(bpm: bpm, at: at, sentAt: Date()))
    }

    func start() { workout.start() }
    func stop() { workout.end(save: false) }
}
