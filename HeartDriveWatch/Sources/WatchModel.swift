import Foundation
import Observation

/// The watch is a heart-rate sensor with a Start/Stop button and a Digital Crown that sets the
/// target heart rate. It runs the workout (which captures HR + keeps the app alive screen-off),
/// streams HR one-way to the phone, and two-way-syncs the target and the Start/Stop state
/// (last-write-wins). Trainer control still lives on the phone.
@Observable
final class WatchModel {
    static let shared = WatchModel()

    let workout = WatchWorkoutManager()
    @ObservationIgnored let connectivity = WatchConnectivityManager()

    var isRunning: Bool { workout.isRunning }
    var currentBPM: Double? { workout.currentBPM }
    /// Latest known target heart rate, set by the Crown or synced from the phone. nil until
    /// the first value is known (the phone seeds it shortly after launch).
    var target: Int?

    private init() {
        workout.onHeartRate = { [weak self] in self?.sendHeartRate() }
        connectivity.onRequestRestart = { [weak self] in self?.restart() }
        connectivity.onTargetChanged = { [weak self] bpm in self?.target = bpm }
        connectivity.onActiveChanged = { [weak self] active in self?.applyRemoteActive(active) }
        connectivity.activate()
        workout.requestAuthorization()
    }

    private func sendHeartRate() {
        guard let bpm = workout.currentBPM, let at = workout.currentSampleAt else { return }
        connectivity.record(HeartRate(bpm: bpm, at: at))
    }

    /// A Digital Crown adjustment. No-ops in the sync layer if the value is unchanged, so
    /// reflecting a phone-synced value back through the Crown can't echo to the phone.
    func setTarget(_ bpm: Int) {
        connectivity.setLocalTarget(bpm)
        target = bpm
    }

    /// User tapped Start on the watch; begin the workout and sync the active intent so the
    /// phone starts trainer control too.
    func start() {
        workout.start()
        connectivity.setLocalActive(true)
    }

    /// User tapped Stop; end the workout and sync the inactive intent so the phone stops.
    func stop() {
        workout.end()
        connectivity.resetStream()
        connectivity.setLocalActive(false)
    }

    /// The phone launched us via HealthKit to begin a ride. Start the workout; the phone
    /// already authored the active intent and syncs it to us.
    func startFromPhone() { workout.start() }

    /// Apply a Start/Stop intent synced from the phone. Idempotent; never re-syncs (received
    /// updates don't echo). Does not disturb the manual/auto restart self-heal.
    private func applyRemoteActive(_ active: Bool) {
        if active {
            workout.start()
        } else {
            workout.end()
            connectivity.resetStream()
        }
    }

    /// Restart heart-rate monitoring: tear the workout down (and with it the HR stream)
    /// and start a clean one. This is the local recovery path when the feed stalls; it doesn't
    /// depend on the phone, which has no channel back to the watch. Leaves the synced active
    /// intent untouched, so this bounce never reads as a Stop on the phone.
    func restart() {
        workout.end()
        connectivity.resetStream()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.workout.start() }
    }
}
