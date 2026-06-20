import Foundation
import Observation

/// Health of the watch link, derived from heart-rate recency (the actual data
/// flow), not WCSession reachability (which drops on wrist-down) and not generic
/// contact (which would falsely read "live" while heart rate has stopped).
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

    @ObservationIgnored private let controller: ErgController
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private let lostAfter: TimeInterval = 30
    @ObservationIgnored private var controlStartedAt: Date?
    @ObservationIgnored private var lastRecoverKick: Date?
    @ObservationIgnored private let recoverGrace: TimeInterval = 15

    var controllerState: ErgControllerState { isControlling ? (lastUpdate?.state ?? .settling) : .idle }
    var targetPower: Int? { isControlling ? lastUpdate?.targetPower : nil }
    var canStart: Bool { trainer.isReady }

    var watchLink: WatchLinkState {
        guard isControlling else { return .idle }
        if heart.isFresh { return .live }
        guard let last = heart.lastUpdate else { return .reconnecting }
        return Date().timeIntervalSince(last) < lostAfter ? .reconnecting : .lost
    }

    init() {
        controller = ErgController(config: AppModel.config(from: settings.snapshot))
        connectivity.onHeartRate = { [weak self] sample in self?.ingestHeartRate(sample) }
        workoutMirror.onHeartRate = { [weak self] sample in self?.ingestHeartRate(sample) }
        connectivity.onWorkoutState = { [weak self] update in self?.handleWatchWorkout(update.state) }
        connectivity.onTargetHeartRate = { [weak self] bpm in self?.setTargetHeartRate(bpm) }
        workoutMirror.onStateChange = { [weak self] state in self?.handleWatchWorkout(state) }
        connectivity.activate()
        workoutMirror.activate()
        if settings.broadcastToZwift { broadcaster.start() }
    }

    private func ingestHeartRate(_ sample: HeartRateSample) {
        heart.ingest(sample, source: "Apple Watch")
        broadcaster.update(bpm: Int(sample.bpm.rounded()))
    }

    /// Keeps the phone's control state in sync with the watch's workout, driven by
    /// start/stop on either device. Edge-triggered (guarded by `isControlling`) so
    /// the command that caused a transition is never reflected back into a loop.
    private func handleWatchWorkout(_ state: WorkoutState) {
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
        controlStartedAt = Date()
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
        controlStartedAt = nil
        lastRecoverKick = nil
    }

    func adjustTargetHeartRate(by delta: Int) {
        settings.targetHeartRate = min(200, max(90, settings.targetHeartRate + delta))
        settings.save()
    }

    /// Absolute target set from the watch's Digital Crown.
    func setTargetHeartRate(_ bpm: Int) {
        let clamped = min(200, max(90, bpm))
        guard clamped != settings.targetHeartRate else { return }
        settings.targetHeartRate = clamped
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
        recoverMirrorIfStale()
    }

    /// The phone is the only side that knows the HR mirror has gone silent; the
    /// watch keeps reading its own sensor regardless. After a start grace, while HR
    /// is stale, kick the watch (throttled) to hard-rebuild the mirror over the
    /// reliable command channel, not the coalescing application context, which
    /// would drop the repeated, identical recovery signal.
    private func recoverMirrorIfStale() {
        guard !heart.isFresh, let started = controlStartedAt,
            Date().timeIntervalSince(started) > recoverGrace
        else {
            lastRecoverKick = nil
            return
        }
        let sinceKick = lastRecoverKick.map { Date().timeIntervalSince($0) } ?? .infinity
        guard sinceKick > 9 else { return }
        lastRecoverKick = Date()
        connectivity.send(command: .recoverMirror)
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
