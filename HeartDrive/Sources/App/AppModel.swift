import Foundation
import Observation

/// Health of the watch heart-rate feed, derived from HR recency (the actual data flow)
/// Uses HealthKit authorization state, not WCSession reachability, which drops on wrist-down.
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
    let broadcaster = HeartRateBroadcaster()
    let settings = SettingsStore()

    private(set) var isControlling = false
    private(set) var lastUpdate: ErgUpdate?

    @ObservationIgnored private let controller: ErgController
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private let lostAfter: TimeInterval = 30

    var controllerState: ErgControllerState { isControlling ? (lastUpdate?.state ?? .settling) : .idle }
    var targetPower: Int? { isControlling ? lastUpdate?.targetPower : nil }

    var watchLink: WatchLinkState {
        guard isControlling else { return .idle }
        if heart.isFresh { return .live }
        guard let last = heart.lastUpdate else { return .reconnecting }
        return Date().timeIntervalSince(last) < lostAfter ? .reconnecting : .lost
    }

    init() {
        controller = ErgController(config: AppModel.config(from: settings.snapshot))
        connectivity.onHeartRate = { [weak self] hr in self?.ingest(hr) }
        connectivity.activate()
        if settings.broadcastToZwift { broadcaster.start() }
    }

    private func ingest(_ hr: HeartRate) {
        heart.ingest(bpm: hr.bpm, sampleTime: hr.at, source: "Apple Watch")
        broadcaster.update(bpm: Int(hr.bpm.rounded()))
    }

    func startControl() {
        guard !isControlling else { return }
        controller.config = AppModel.config(from: settings.snapshot)
        controller.start()
        isControlling = true
        startTimer()
    }

    func stopControl() {
        guard isControlling else { return }
        controller.stop()
        isControlling = false
        timer?.invalidate()
        timer = nil
        if trainer.isReady { trainer.setTargetPower(settings.powerFloor) }
        heart.reset()
        lastUpdate = nil
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
