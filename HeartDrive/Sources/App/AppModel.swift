import Foundation
import Observation

/// Health of the watch link, derived from how recently the companion app last
/// reached us (over any channel), not from WCSession reachability, which drops
/// on wrist-down while the workout keeps running.
enum WatchLinkState {
    case idle
    case live
    case reconnecting
    case lost
}

@Observable
final class AppModel {
    let trainer = TrainerManager()
    let heart = HeartRateHub()
    let connectivity = PhoneConnectivity()
    let workoutMirror = WorkoutMirror()
    let broadcaster = HeartRateBroadcaster()
    let settings = SettingsStore()

    private(set) var isControlling = false
    private(set) var lastUpdate: ErgUpdate?
    private(set) var lastWatchContact: Date?

    @ObservationIgnored private let controller: ErgController
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var recoveryTimer: Timer?
    @ObservationIgnored private let lostAfter: TimeInterval = 30

    var controllerState: ErgControllerState { isControlling ? (lastUpdate?.state ?? .settling) : .idle }
    var targetPower: Int? { isControlling ? lastUpdate?.targetPower : nil }
    var canStart: Bool { trainer.isReady }

    var watchLink: WatchLinkState {
        guard isControlling else { return .idle }
        guard let last = lastWatchContact else { return .reconnecting }
        let age = Date().timeIntervalSince(last)
        if age < heart.staleAfter { return .live }
        if age < lostAfter { return .reconnecting }
        return .lost
    }

    init() {
        controller = ErgController(config: AppModel.config(from: settings.snapshot))
        connectivity.onHeartRate = { [weak self] sample in self?.ingestHeartRate(sample) }
        workoutMirror.onHeartRate = { [weak self] sample in self?.ingestHeartRate(sample) }
        connectivity.onWorkoutState = { [weak self] update in self?.handleWatchWorkout(update.state) }
        workoutMirror.onStateChange = { [weak self] state in self?.handleWatchWorkout(state) }
        connectivity.activate()
        workoutMirror.activate()
        if settings.broadcastToZwift { broadcaster.start() }
        startRecoveryLoop()
    }

    /// Always-on watchdog: while we're controlling but HR has gone stale, keep
    /// nudging the watch to re-establish its mirror until heart rate returns.
    private func startRecoveryLoop() {
        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in self?.recoverHeartRateIfNeeded() }
        RunLoop.main.add(timer, forMode: .common)
        recoveryTimer = timer
    }

    private func recoverHeartRateIfNeeded() {
        guard isControlling, !heart.isFresh else { return }
        connectivity.send(command: .remirror)
    }

    private func ingestHeartRate(_ sample: HeartRateSample) {
        lastWatchContact = Date()
        heart.ingest(sample, source: "Apple Watch")
        broadcaster.update(bpm: Int(sample.bpm.rounded()))
    }

    /// Keeps the phone's control state in sync with the watch's workout, driven by
    /// start/stop on either device. Edge-triggered (guarded by `isControlling`) so
    /// the command that caused a transition is never reflected back into a loop.
    private func handleWatchWorkout(_ state: WorkoutState) {
        lastWatchContact = Date()
        switch state {
        case .running where !isControlling: startControl(notifyWatch: false)
        case .ended where isControlling: stopControl(notifyWatch: false)
        default: break
        }
    }

    func startControl(notifyWatch: Bool = true) {
        guard !isControlling else { return }
        controller.config = AppModel.config(from: settings.snapshot)
        controller.start()
        isControlling = true
        if notifyWatch {
            // Wake the watch: the command starts it instantly if its app is already
            // running; startWatchWorkout launches it from closed. Both idempotent.
            connectivity.send(command: .startWorkout)
            workoutMirror.startWatchWorkout()
        }
        startTimer()
    }

    func stopControl(notifyWatch: Bool = true) {
        guard isControlling else { return }
        controller.stop()
        isControlling = false
        timer?.invalidate()
        timer = nil
        if notifyWatch { connectivity.send(command: .stopWorkout) }
        if trainer.isReady { trainer.setTargetPower(settings.powerFloor) }
        heart.reset()
        lastUpdate = nil
        lastWatchContact = nil
    }

    func adjustTargetHeartRate(by delta: Int) {
        settings.targetHeartRate = min(200, max(90, settings.targetHeartRate + delta))
        settings.save()
    }

    func setBroadcasting(_ on: Bool) {
        settings.broadcastToZwift = on
        settings.save()
        if on { broadcaster.start() } else { broadcaster.stop() }
    }

    func adjustCadenceTarget(by delta: Int) {
        settings.cadenceTarget = min(130, max(40, settings.cadenceTarget + delta))
        settings.save()
    }

    func setCadenceGuide(_ on: Bool) {
        settings.showCadenceGuide = on
        settings.save()
    }

    private func startTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: controller.config.updateInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    private func tick() {
        let newConfig = AppModel.config(from: settings.snapshot)
        if newConfig != controller.config {
            controller.config = newConfig
            controller.markTargetChanged()
        }

        let update = controller.update(
            filteredHR: heart.controlBPM,
            isPedaling: trainer.isPedaling,
            dt: controller.config.updateInterval)
        lastUpdate = update

        if trainer.isReady {
            let watts = update.state == .holdingNoCadence ? settings.powerFloor : update.targetPower
            trainer.setTargetPower(watts)
        }
        connectivity.send(
            status: RideStatus(
                targetHeartRate: settings.targetHeartRate, targetPowerWatts: update.targetPower,
                saveWorkout: settings.saveWorkoutToHealth))
    }

    private static func config(from settings: RideSettings) -> ErgControllerConfig {
        ErgControllerConfig(
            targetHeartRate: Double(settings.targetHeartRate),
            powerFloor: settings.powerFloor,
            powerCeiling: settings.powerCeiling,
            startingPower: settings.startingPower,
            aggressiveness: settings.aggressiveness)
    }
}
