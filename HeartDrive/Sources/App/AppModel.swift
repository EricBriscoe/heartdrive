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
    static let shared = AppModel()

    let trainer = TrainerManager()
    let heart = HeartRateHub()
    let connectivity = PhoneConnectivity()
    let broadcaster = HeartRateBroadcaster()
    let settings = SettingsStore()

    private(set) var isControlling = false
    private(set) var lastUpdate: ErgUpdate?

    @ObservationIgnored private let controller: ErgController
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastTickAt: Date?
    @ObservationIgnored private let lostAfter: TimeInterval = 30

    var controllerState: ErgControllerState { isControlling ? (lastUpdate?.state ?? .settling) : .idle }
    var targetPower: Int? { isControlling ? lastUpdate?.targetPower : nil }

    var watchLink: WatchLinkState {
        guard isControlling else { return .idle }
        if heart.isFresh { return .live }
        guard let last = heart.lastUpdate else { return .reconnecting }
        return Date().timeIntervalSince(last) < lostAfter ? .reconnecting : .lost
    }

    private init() {
        controller = ErgController(config: AppModel.config(from: settings.snapshot))
        connectivity.onHeartRate = { [weak self] hr in self?.ingest(hr) }
        connectivity.onTargetChanged = { [weak self] bpm in self?.applyRemoteTarget(bpm) }
        connectivity.seedTarget(settings.targetHeartRate)
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
        lastTickAt = nil
        if trainer.isReady { trainer.setTargetPower(settings.powerFloor) }
        heart.reset()
        lastUpdate = nil
    }

    func adjustTargetHeartRate(by delta: Int) {
        settings.targetHeartRate = min(200, max(90, settings.targetHeartRate + delta))
        settings.save()
    }

    /// Reconcile after any phone-side change to `settings.targetHeartRate` (see RootView). If
    /// the new value differs from the synced register it's a local edit → push it to the watch;
    /// a value that merely mirrors an already-synced one (a remote apply) leaves them equal and
    /// no-ops, so there's no echo and no need for an "applying remote" flag.
    func reconcileTargetEdit() {
        if connectivity.sync.register?.value != settings.targetHeartRate {
            connectivity.sendLocalTarget(settings.targetHeartRate)
        }
    }

    /// Apply a target synced from the watch. Mirrors it into settings (the running loop picks
    /// it up on its next tick); never sends because received updates don't echo.
    private func applyRemoteTarget(_ bpm: Int) {
        let v = min(200, max(90, bpm))
        guard settings.targetHeartRate != v else { return }
        settings.targetHeartRate = v
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
        lastTickAt = nil
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

        // Drive the controller on the *actual* elapsed time, clamped so a late or
        // coalesced tick can't integrate or slew an outsized step at once.
        let now = Date()
        let nominal = controller.config.updateInterval
        let dt = lastTickAt.map { min(max(now.timeIntervalSince($0), 0.5), nominal * 2) } ?? nominal
        lastTickAt = now

        let update = controller.update(
            filteredHR: heart.controlBPM,
            isPedaling: trainer.isPedaling,
            dt: dt)
        lastUpdate = update

        if trainer.isReady {
            trainer.setTargetPower(update.targetPower)
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
