import Foundation
import HealthKit
import Observation

/// Phone side of HealthKit workout-session mirroring. When the watch starts
/// mirroring its workout, the system hands us the mirrored session; we then
/// receive heart-rate samples reliably (background- and screen-off-safe), which
/// the WCSession channel can't guarantee.
@Observable
final class WorkoutMirror: NSObject {
    private(set) var isMirroring = false

    @ObservationIgnored var onHeartRate: ((HeartRateSample) -> Void)?
    @ObservationIgnored var onStateChange: ((WorkoutState) -> Void)?

    private let healthStore = HKHealthStore()
    private var mirroredSession: HKWorkoutSession?

    func activate() {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        requestAuthorization()
        healthStore.workoutSessionMirroringStartHandler = { [weak self] session in
            DispatchQueue.main.async {
                session.delegate = self
                self?.mirroredSession = session
                self?.isMirroring = true
                self?.onStateChange?(.running)
            }
        }
    }

    private func requestAuthorization() {
        var read: Set<HKObjectType> = []
        if let hr = HKObjectType.quantityType(forIdentifier: .heartRate) { read.insert(hr) }
        healthStore.requestAuthorization(toShare: [HKObjectType.workoutType()], read: read) { _, _ in }
    }

    /// Launches the companion watch app and starts its workout when the
    /// rider taps Start on the phone while the watch app is closed. Idempotent:
    /// if the watch app is already running, its own start guard makes this a no-op.
    func startWatchWorkout() {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .cycling
        configuration.locationType = .indoor
        healthStore.startWatchApp(with: configuration) { _, _ in }
    }
}

extension WorkoutMirror: HKWorkoutSessionDelegate {
    func workoutSession(
        _ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState, date: Date
    ) {
        if toState == .ended || toState == .stopped {
            DispatchQueue.main.async { [weak self] in
                self?.isMirroring = false
                self?.mirroredSession = nil
                self?.onStateChange?(.ended)
            }
        }
    }

    func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {}

    func workoutSession(_ workoutSession: HKWorkoutSession, didReceiveDataFromRemoteWorkoutSession data: [Data]) {
        let samples = data.compactMap { try? JSONDecoder().decode(HeartRateSample.self, from: $0) }
        guard !samples.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            for sample in samples { self?.onHeartRate?(sample) }
        }
    }

    func workoutSession(_ workoutSession: HKWorkoutSession, didDisconnectFromRemoteDeviceWithError error: Error?) {
        DispatchQueue.main.async { [weak self] in self?.isMirroring = false }
    }
}
