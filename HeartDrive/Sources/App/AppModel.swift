import Foundation
import HealthKit
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
    let hrMonitor = HeartRateMonitorManager()
    let settings = SettingsStore()

    private(set) var isControlling = false
    private(set) var lastUpdate: ErgUpdate?

    @ObservationIgnored private let controller: ErgController
    @ObservationIgnored private let controlLogger = ControlLogger()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastTickAt: Date?
    @ObservationIgnored private let lostAfter: TimeInterval = 30
    @ObservationIgnored private let healthStore = HKHealthStore()

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
        connectivity.onHeartRate = { [weak self] hr in self?.ingestWatch(hr) }
        connectivity.onTargetChanged = { [weak self] bpm in self?.applyRemoteTarget(bpm) }
        connectivity.onActiveChanged = { [weak self] active in self?.applyRemoteActive(active) }
        hrMonitor.onHeartRate = { [weak self] bpm, at in self?.ingestBLE(bpm, at) }
        connectivity.seedTarget(settings.targetHeartRate)
        connectivity.activate()
        requestWatchLaunchAuthorization()
        if settings.broadcastToZwift { broadcaster.start() }
        hrMonitor.autoReconnect = settings.hrSource == .bluetooth
        if hrMonitor.autoReconnect { hrMonitor.reconnectIfPaired() }
    }

    private func ingestWatch(_ hr: HeartRate) {
        acceptHR(bpm: hr.bpm, sampleTime: hr.at, source: .appleWatch)
    }

    private func ingestBLE(_ bpm: Int, _ at: Date) {
        acceptHR(bpm: Double(bpm), sampleTime: at, source: .bluetooth)
    }

    /// Funnel both HR sources through one gate so only the rider's selected source feeds the hub —
    /// the hub blends its last samples, so letting the watch and a strap both in would corrupt the
    /// control heart rate. The Zwift rebroadcast rides along with whichever source wins.
    private func acceptHR(bpm: Double, sampleTime: Date, source: HRSource) {
        guard source == settings.hrSource else { return }
        let label = source == .bluetooth ? (hrMonitor.connectedName ?? source.label) : source.label
        heart.ingest(bpm: bpm, sampleTime: sampleTime, source: label)
        broadcaster.update(bpm: Int(bpm.rounded()))
    }

    /// User tapped Start on the phone: begin control, wake the watch to start its workout, and
    /// sync the active intent so the two stay in lockstep.
    func startControl() {
        guard !isControlling else { return }
        beginControl()
        connectivity.sendLocalActive(true)
        // The watch is the HealthKit HR source; in Bluetooth mode the strap replaces it, so don't
        // wake the watch — a true phone-only ride.
        if settings.hrSource == .appleWatch { launchWatchWorkout() }
    }

    /// User tapped Stop on the phone.
    func stopControl() {
        guard isControlling else { return }
        endControl()
        connectivity.sendLocalActive(false)
    }

    private func beginControl() {
        guard !isControlling else { return }
        controller.config = AppModel.config(from: settings.snapshot)
        controller.start()
        controlLogger.start()
        isControlling = true
        startTimer()
    }

    private func endControl() {
        guard isControlling else { return }
        controller.stop()
        controlLogger.stop()
        isControlling = false
        timer?.invalidate()
        timer = nil
        lastTickAt = nil
        if trainer.isReady { trainer.setTargetPower(settings.powerFloor) }
        heart.reset()
        lastUpdate = nil
    }

    /// Apply a Start/Stop intent synced from the watch (e.g. the rider hit Start on their
    /// wrist). Auto-starts trainer control when the trainer is ready; never re-syncs.
    private func applyRemoteActive(_ active: Bool) {
        if active {
            if trainer.isReady { beginControl() }
        } else {
            endControl()
        }
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
        if connectivity.target.register?.value != settings.targetHeartRate {
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

    /// Ask once for permission to share workouts, which `startWatchApp` requires.
    private func requestWatchLaunchAuthorization() {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        healthStore.requestAuthorization(toShare: [HKObjectType.workoutType()], read: []) { _, error in
            if let error {
                hrLog.error("phone: HealthKit auth failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Launch or wake the watch app to start its workout. This is the only way to start the watch app
    /// from the phone. Best-effort: slow or unavailable if the watch is asleep or absent.
    private func launchWatchWorkout() {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let config = HKWorkoutConfiguration()
        config.activityType = .cycling
        config.locationType = .indoor
        healthStore.startWatchApp(with: config) { _, error in
            if let error {
                hrLog.error("phone: startWatchApp failed: \(error.localizedDescription, privacy: .public)")
            }
        }
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

    /// React to the rider switching HR source in Settings: arm/disarm strap auto-reconnect and,
    /// when switching to Bluetooth, reconnect the paired strap so they don't have to re-pair.
    func applyHRSource() {
        // Clear the previous source's reading so switching doesn't leave a stale value lingering
        // until it ages out (~12s); the newly selected source repopulates on its next sample.
        heart.reset()
        hrMonitor.autoReconnect = settings.hrSource == .bluetooth
        if settings.hrSource == .bluetooth { hrMonitor.reconnectIfPaired() }
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

        // Diagnostic: record commanded vs delivered power + control state to spot ERG drop-outs.
        controlLogger.log(
            targetHR: Int(controller.config.targetHeartRate),
            controlHR: heart.controlBPM,
            commandedW: update.targetPower,
            deliveredW: trainer.powerWatts,
            cadence: trainer.cadenceRPM,
            dt: dt,
            state: update.state,
            controlReady: trainer.controlReady,
            isReady: trainer.isReady,
            conflict: trainer.controlConflict,
            mode: trainer.controlModeName)
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
