import Foundation
import HealthKit
import Observation

/// Runs the indoor-cycling HKWorkoutSession on the watch. Its only jobs are to read live
/// heart rate (the session is what unlocks high-rate HR and background runtime) and
/// report the latest reading; the connectivity layer handles delivery to the phone.
@Observable
final class WatchWorkoutManager: NSObject {
    private(set) var currentBPM: Double?
    private(set) var currentSampleAt: Date?
    private(set) var isRunning = false
    private(set) var lastError: String?

    @ObservationIgnored var onHeartRate: (() -> Void)?

    private let healthStore = HKHealthStore()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    private let heartRateUnit = HKUnit.count().unitDivided(by: .minute())

    func requestAuthorization() {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        var share: Set<HKSampleType> = [HKObjectType.workoutType()]
        var read: Set<HKObjectType> = []
        if let hr = HKObjectType.quantityType(forIdentifier: .heartRate) {
            share.insert(hr)
            read.insert(hr)
        }
        if let energy = HKObjectType.quantityType(forIdentifier: .activeEnergyBurned) {
            share.insert(energy)
            read.insert(energy)
        }
        healthStore.requestAuthorization(toShare: share, read: read) { [weak self] _, error in
            if let error { DispatchQueue.main.async { self?.lastError = error.localizedDescription } }
        }
    }

    /// Begins a workout. Call on the main thread: the `session == nil` guard that keeps a
    /// double-tap (or a restart overlap) from making a second session isn't synchronized.
    func start() {
        guard HKHealthStore.isHealthDataAvailable(), session == nil else { return }
        lastError = nil
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .cycling
        configuration.locationType = .indoor
        do {
            let session = try HKWorkoutSession(healthStore: healthStore, configuration: configuration)
            let builder = session.associatedWorkoutBuilder()
            builder.dataSource = HKLiveWorkoutDataSource(healthStore: healthStore, workoutConfiguration: configuration)
            session.delegate = self
            builder.delegate = self
            self.session = session
            self.builder = builder

            let startDate = Date()
            session.startActivity(with: startDate)
            builder.beginCollection(withStart: startDate) { [weak self] _, error in
                if let error { DispatchQueue.main.async { self?.lastError = error.localizedDescription } }
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Ends and discards the workout. This app controls a trainer, it doesn't log rides.
    /// Tears down synchronously so a second stop (a double-tap or a restart overlap) is a
    /// no-op and can't double-finish the builder.
    func end() {
        guard let session = self.session, let builder = self.builder else { return }
        self.session = nil
        self.builder = nil
        isRunning = false
        currentBPM = nil
        currentSampleAt = nil
        session.end()
        builder.discardWorkout()
    }
}

extension WatchWorkoutManager: HKWorkoutSessionDelegate {
    func workoutSession(
        _ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState, date: Date
    ) {
        DispatchQueue.main.async { [weak self] in
            self?.isRunning = (toState == .running)
        }
    }

    func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        DispatchQueue.main.async { [weak self] in self?.lastError = error.localizedDescription }
    }
}

extension WatchWorkoutManager: HKLiveWorkoutBuilderDelegate {
    func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}

    func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>) {
        guard
            let heartRateType = HKObjectType.quantityType(forIdentifier: .heartRate),
            collectedTypes.contains(heartRateType),
            let statistics = workoutBuilder.statistics(for: heartRateType),
            let quantity = statistics.mostRecentQuantity()
        else { return }
        let bpm = quantity.doubleValue(for: heartRateUnit)
        // The sample's own window-end, not wall-clock now, so the phone can order and
        // de-duplicate readings carried by repeated sends.
        let sampleAt = statistics.mostRecentQuantityDateInterval()?.end ?? Date()
        DispatchQueue.main.async { [weak self] in
            self?.currentBPM = bpm
            self?.currentSampleAt = sampleAt
            self?.onHeartRate?()
        }
    }
}
