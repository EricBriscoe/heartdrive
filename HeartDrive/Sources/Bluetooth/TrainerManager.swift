import CoreBluetooth
import Foundation
import Observation

enum TrainerConnectionState: Equatable {
    case poweredOff
    case unauthorized
    case idle
    case scanning
    case connecting
    case connected
}

struct DiscoveredTrainer: Identifiable, Equatable {
    let id: UUID
    let name: String
    var rssi: Int
}

@Observable
final class TrainerManager: NSObject {
    private(set) var connectionState: TrainerConnectionState = .idle
    private(set) var discovered: [DiscoveredTrainer] = []
    private(set) var connectedName: String?
    private(set) var controlReady = false
    private(set) var controlModeName: String?
    private(set) var statusMessage: String?
    private(set) var controlConflict = false

    private(set) var powerWatts: Int?
    private(set) var cadenceRPM: Double?
    private(set) var speedKPH: Double?
    private(set) var lastDataAt: Date?

    var isReady: Bool { connectionState == .connected && controlReady }
    var isPedaling: Bool {
        if let cadenceRPM { return cadenceRPM > 0.5 }
        if let powerWatts { return powerWatts > 0 }
        return true
    }

    private var central: CBCentralManager!
    private var peripheralsByID: [UUID: CBPeripheral] = [:]
    private var connected: CBPeripheral?
    private var intentionalDisconnect = false

    private var strategy: ErgControlStrategy?
    private var controlChar: CBCharacteristic?
    private var ftmsControl: CBCharacteristic?
    private var wahooControl: CBCharacteristic?
    private var pendingServiceDiscoveries = 0

    private var lastWrittenWatts: Int?
    private var lastWriteAt: Date?
    private var lastIndoorBikeAt: Date?
    private var controlWatchdog: DispatchWorkItem?
    private var recentCommands: [(watts: Int, at: Date)] = []
    private var conflictClearWork: DispatchWorkItem?

    private let savedTrainerKey = "lastTrainerID"

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    func scan() {
        guard central.state == .poweredOn else { return }
        discovered.removeAll()
        connectionState = .scanning
        statusMessage = "Scanning for trainers…"
        central.scanForPeripherals(
            withServices: BLEUUID.trainerServices, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    func stopScan() {
        central.stopScan()
        if connectionState == .scanning { connectionState = .idle }
    }

    func connect(_ trainer: DiscoveredTrainer) {
        guard let peripheral = peripheralsByID[trainer.id] else { return }
        connect(peripheral)
        UserDefaults.standard.set(trainer.id.uuidString, forKey: savedTrainerKey)
    }

    func disconnect() {
        intentionalDisconnect = true
        if let connected { central.cancelPeripheralConnection(connected) }
        resetConnectionState()
        connectionState = .idle
        statusMessage = nil
    }

    func setTargetPower(_ watts: Int) {
        guard let peripheral = connected, let controlChar, let strategy, controlReady else { return }
        let now = Date()
        if lastWrittenWatts == watts, let at = lastWriteAt, now.timeIntervalSince(at) < 5 { return }
        lastWrittenWatts = watts
        lastWriteAt = now
        peripheral.writeValue(strategy.setTargetPowerCommand(watts: watts), for: controlChar, type: .withResponse)
        recentCommands.append((watts, now))
        recentCommands.removeAll { now.timeIntervalSince($0.at) > 10 }
    }

    private func handleStatus(_ status: FTMSStatus) {
        switch status {
        case .simulationParametersChanged, .controlPermissionLost:
            flagControlConflict()
        case .targetPowerChanged(let watts):
            let now = Date()
            let isOurs = recentCommands.contains { abs($0.watts - watts) <= 3 && now.timeIntervalSince($0.at) < 10 }
            if !isOurs { flagControlConflict() }
        case .other:
            break
        }
    }

    private func flagControlConflict() {
        controlConflict = true
        conflictClearWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.controlConflict = false }
        conflictClearWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
    }

    private func connect(_ peripheral: CBPeripheral) {
        intentionalDisconnect = false
        central.stopScan()
        connected = peripheral
        peripheral.delegate = self
        connectionState = .connecting
        connectedName = peripheral.name
        statusMessage = "Connecting…"
        central.connect(peripheral, options: nil)
    }

    private func attemptKnownReconnect() {
        guard
            connected == nil,
            let stored = UserDefaults.standard.string(forKey: savedTrainerKey),
            let uuid = UUID(uuidString: stored),
            let peripheral = central.retrievePeripherals(withIdentifiers: [uuid]).first
        else { return }
        peripheralsByID[uuid] = peripheral
        connect(peripheral)
    }

    private func resetConnectionState() {
        controlWatchdog?.cancel()
        controlWatchdog = nil
        controlReady = false
        controlModeName = nil
        strategy = nil
        controlChar = nil
        ftmsControl = nil
        wahooControl = nil
        powerWatts = nil
        cadenceRPM = nil
        speedKPH = nil
        lastWrittenWatts = nil
        controlConflict = false
        conflictClearWork?.cancel()
        conflictClearWork = nil
        recentCommands.removeAll()
    }

    private func markControlReady(_ ready: Bool, message: String) {
        controlWatchdog?.cancel()
        controlWatchdog = nil
        controlReady = ready
        statusMessage = message
    }

    private func scheduleControlWatchdog() {
        controlWatchdog?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.controlReady else { return }
            self.statusMessage =
                "Connected, but couldn't take control. Reconnect and make sure no other app is controlling the trainer."
        }
        controlWatchdog = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: work)
    }

    private func finalizeControlSetup() {
        guard let peripheral = connected else { return }
        if let ftmsControl {
            strategy = FTMSErgStrategy()
            controlChar = ftmsControl
        } else if let wahooControl {
            strategy = WahooErgStrategy()
            controlChar = wahooControl
        } else {
            statusMessage = "Connected, but this trainer exposes no ERG control."
            return
        }
        controlModeName = strategy?.displayName
        guard let strategy, let controlChar else { return }
        if strategy.needsIndications {
            peripheral.setNotifyValue(true, for: controlChar)
        } else {
            sendPrepareCommands()
        }
    }

    private func sendPrepareCommands() {
        guard let peripheral = connected, let strategy, let controlChar else { return }
        for command in strategy.prepareCommands() {
            peripheral.writeValue(command, for: controlChar, type: .withResponse)
        }
        if !strategy.needsIndications {
            markControlReady(true, message: "Control ready (\(strategy.displayName)).")
        }
    }
}

extension TrainerManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            if connectionState == .idle { statusMessage = nil }
            attemptKnownReconnect()
        case .poweredOff:
            connectionState = .poweredOff
            statusMessage = "Bluetooth is off."
        case .unauthorized:
            connectionState = .unauthorized
            statusMessage = "Bluetooth permission is required."
        default:
            break
        }
    }

    func centralManager(
        _ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? "Trainer"
        peripheralsByID[peripheral.identifier] = peripheral
        let entry = DiscoveredTrainer(id: peripheral.identifier, name: name, rssi: RSSI.intValue)
        if let index = discovered.firstIndex(where: { $0.id == entry.id }) {
            discovered[index].rssi = entry.rssi
        } else {
            discovered.append(entry)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connectionState = .connected
        connectedName = peripheral.name
        statusMessage = "Discovering services…"
        scheduleControlWatchdog()
        peripheral.discoverServices(BLEUUID.trainerServices)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        statusMessage = "Failed to connect: \(error?.localizedDescription ?? "unknown")"
        connectionState = .idle
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        resetConnectionState()
        if intentionalDisconnect {
            connected = nil
            connectionState = .idle
        } else {
            connectionState = .connecting
            statusMessage = "Reconnecting…"
            central.connect(peripheral, options: nil)
        }
    }
}

extension TrainerManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else { return }
        pendingServiceDiscoveries = services.count
        for service in services {
            switch service.uuid {
            case BLEUUID.fitnessMachineService:
                peripheral.discoverCharacteristics(
                    [BLEUUID.indoorBikeData, BLEUUID.fitnessMachineControlPoint, BLEUUID.fitnessMachineStatus],
                    for: service)
            case BLEUUID.cyclingPowerService:
                peripheral.discoverCharacteristics(
                    [BLEUUID.cyclingPowerMeasurement, BLEUUID.wahooControlPoint],
                    for: service)
            default:
                pendingServiceDiscoveries -= 1
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for characteristic in service.characteristics ?? [] {
            switch characteristic.uuid {
            case BLEUUID.indoorBikeData, BLEUUID.cyclingPowerMeasurement, BLEUUID.fitnessMachineStatus:
                peripheral.setNotifyValue(true, for: characteristic)
            case BLEUUID.fitnessMachineControlPoint:
                ftmsControl = characteristic
            case BLEUUID.wahooControlPoint:
                wahooControl = characteristic
            default:
                break
            }
        }
        pendingServiceDiscoveries -= 1
        if pendingServiceDiscoveries <= 0 { finalizeControlSetup() }
    }

    func peripheral(
        _ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?
    ) {
        guard characteristic.uuid == controlChar?.uuid, characteristic.isNotifying else { return }
        sendPrepareCommands()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value else { return }
        switch characteristic.uuid {
        case BLEUUID.indoorBikeData:
            let parsed = IndoorBikeData.parse(data)
            lastIndoorBikeAt = Date()
            if let power = parsed.powerWatts { powerWatts = power }
            if let cadence = parsed.cadenceRPM { cadenceRPM = cadence }
            if let speed = parsed.speedKPH { speedKPH = speed }
            lastDataAt = Date()
        case BLEUUID.cyclingPowerMeasurement:
            let stale = lastIndoorBikeAt.map { Date().timeIntervalSince($0) > 3 } ?? true
            if stale, let power = CyclingPowerMeasurement.instantaneousPower(data) {
                powerWatts = power
                lastDataAt = Date()
            }
        case BLEUUID.fitnessMachineControlPoint:
            guard let response = FTMSResponse(data) else { return }
            if response.requestOpcode == 0x00 {
                markControlReady(
                    response.isSuccess,
                    message: response.isSuccess
                        ? "Control ready (FTMS)."
                        : "Trainer refused control: \(response.resultDescription).")
            }
        case BLEUUID.fitnessMachineStatus:
            handleStatus(FTMSStatus(data))
        default:
            break
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            statusMessage = "Write failed: \(error.localizedDescription)"
            lastWrittenWatts = nil  // let the next tick retry the same target
        }
    }
}
