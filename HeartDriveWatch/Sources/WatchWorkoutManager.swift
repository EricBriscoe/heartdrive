import Foundation
import HealthKit
import Observation

/// Runs an indoor-cycling HKWorkoutSession on the watch and streams HR to the
/// phone via workout-session mirroring. A watchdog keeps re-establishing the
/// mirror until it's confirmed active, so a dropped link always self-heals.
@Observable
final class WatchWorkoutManager: NSObject {
    private(set) var currentBPM: Double?
    private(set) var isRunning = false
    private(set) var lastError: String?

    @ObservationIgnored var onHeartRate: ((HeartRateSample) -> Void)?
    @ObservationIgnored var onStateChange: ((WorkoutState) -> Void)?

    private let healthStore = HKHealthStore()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    private let heartRateUnit = HKUnit.count().unitDivided(by: .minute())

    private var mirroring = false
    private var mirrorWatchdog: Timer?
    private var startDate: Date?
    private let minWorkoutDuration: TimeInterval = 120

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

    /// Begins a workout. Call on the main thread: the `session == nil` guard that
    /// keeps the phone's two wake paths (WC command + `startWatchApp`) from making
    /// a second session isn't internally synchronized.
    func start() {
        guard HKHealthStore.isHealthDataAvailable(), session == nil else { return }
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
            self.startDate = startDate
            session.startActivity(with: startDate)
            builder.beginCollection(withStart: startDate) { [weak self] _, error in
                if let error { DispatchQueue.main.async { self?.lastError = error.localizedDescription } }
            }
            startMirrorWatchdog()
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Called when the phone nudges us: make sure a workout is running and the
    /// mirror is up.
    func ensureActive() {
        if session == nil {
            start()
        } else if session?.state == .running {
            startMirroring()
        }
    }

    /// Re-establish the mirror for an already-running workout, without ever
    /// starting a new one, so a late recovery nudge can't resurrect a workout
    /// the user has stopped.
    func remirror() {
        if session?.state == .running { startMirroring() }
    }

    func end(save: Bool) {
        mirrorWatchdog?.invalidate()
        mirrorWatchdog = nil
        mirroring = false
        guard let session = self.session, let builder = self.builder else { return }
        // Tear down synchronously so a second stop (a double-tap, or the phone
        // echoing the command) is a no-op and can't double-finish the builder.
        self.session = nil
        self.builder = nil
        isRunning = false
        let elapsed = startDate.map { Date().timeIntervalSince($0) } ?? 0
        startDate = nil

        session.end()
        // Only persist real rides; skip short start/stops and sessions the rider
        // opted not to save, so they don't clutter Apple Health. Discard directly:
        // calling endCollection first would log a spurious state-machine error.
        guard save, elapsed >= minWorkoutDuration else {
            builder.discardWorkout()
            return
        }
        builder.endCollection(withEnd: Date()) { [weak self] _, error in
            if let error { DispatchQueue.main.async { self?.lastError = error.localizedDescription } }
            builder.finishWorkout { [weak self] _, error in
                if let error { DispatchQueue.main.async { self?.lastError = error.localizedDescription } }
            }
        }
    }

    private func startMirroring() {
        guard let session, session.state == .running else { return }
        session.startMirroringToCompanionDevice { [weak self] success, error in
            DispatchQueue.main.async {
                self?.mirroring = success
                if let error { self?.lastError = "Mirror: \(error.localizedDescription)" }
            }
        }
    }

    private func startMirrorWatchdog() {
        mirrorWatchdog?.invalidate()
        let timer = Timer(timeInterval: 6, repeats: true) { [weak self] _ in
            guard let self, self.session?.state == .running, !self.mirroring else { return }
            self.startMirroring()
        }
        RunLoop.main.add(timer, forMode: .common)
        mirrorWatchdog = timer
    }

    private func deliver(_ sample: HeartRateSample) {
        if let session, let data = try? JSONEncoder().encode(sample) {
            session.sendToRemoteWorkoutSession(data: data) { _, _ in }
        }
        onHeartRate?(sample)
    }
}

extension WatchWorkoutManager: HKWorkoutSessionDelegate {
    func workoutSession(
        _ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState, date: Date
    ) {
        DispatchQueue.main.async { [weak self] in
            self?.isRunning = (toState == .running)
            switch toState {
            case .running: self?.onStateChange?(.running)
            case .paused: self?.onStateChange?(.paused)
            case .ended, .stopped: self?.onStateChange?(.ended)
            default: break
            }
        }
        if toState == .running { startMirroring() }
    }

    func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        DispatchQueue.main.async { [weak self] in self?.lastError = error.localizedDescription }
    }

    func workoutSession(_ workoutSession: HKWorkoutSession, didDisconnectFromRemoteDeviceWithError error: Error?) {
        // The phone-side mirror dropped; flag it so the watchdog re-establishes it.
        DispatchQueue.main.async { [weak self] in
            self?.mirroring = false
            self?.startMirroring()
        }
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
        let sample = HeartRateSample(bpm: bpm, timestamp: Date())
        DispatchQueue.main.async { [weak self] in
            self?.currentBPM = bpm
            self?.deliver(sample)
        }
    }
}
