import CoreBluetooth
import Foundation
import Observation
import os

enum HRMonitorConnectionState: Equatable {
    case poweredOff
    case unauthorized
    case idle
    case scanning
    case connecting
    case connected
}

/// Reads heart rate from a standard BLE heart-rate monitor (GATT Heart Rate Service 0x180D,
/// Heart Rate Measurement 0x2A37) as an alternative to the Apple Watch. A read-only mirror of
/// `TrainerManager`'s central pattern (scan → connect → subscribe → parse → emit) with none of
/// the ERG/control machinery. Owns its own `CBCentralManager`; the phone already runs a second
/// central (`TrainerManager`) and a peripheral (`HeartRateBroadcaster`) concurrently.
@Observable
final class HeartRateMonitorManager: NSObject {
    private(set) var connectionState: HRMonitorConnectionState = .idle
    private(set) var discovered: [DiscoveredDevice] = []
    private(set) var connectedName: String?
    private(set) var statusMessage: String?

    /// Fired on every Heart Rate Measurement notification with (bpm, receiptTime). 0x2A37 carries
    /// no sample timestamp, so receipt time is the sample time, which is fine for `HeartRateHub`'s dedupe.
    var onHeartRate: ((Int, Date) -> Void)?

    /// Whether to reconnect to the paired monitor when Bluetooth powers on. Set by AppModel from
    /// the HR-source setting so a strap is only auto-connected while the Bluetooth source is chosen.
    var autoReconnect = false

    /// Most recent reading accepted from the strap, for the Settings row and for logs.
    private(set) var lastBPM: Int?
    private(set) var lastBPMAt: Date?

    private static let log = Logger(subsystem: "com.ericbriscoe.HeartDrive", category: "hrm")

    private var central: CBCentralManager!
    private var peripheralsByID: [UUID: CBPeripheral] = [:]
    private var connected: CBPeripheral?

    private let savedMonitorKey = "pairedHRMonitorID"

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    func scan() {
        guard central.state == .poweredOn else { return }
        discovered.removeAll()
        connectionState = .scanning
        statusMessage = "Scanning for heart-rate monitors…"
        central.scanForPeripherals(
            withServices: [BLEUUID.heartRateService], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    func stopScan() {
        central.stopScan()
        if connectionState == .scanning { connectionState = connected == nil ? .idle : .connected }
    }

    func connect(_ monitor: DiscoveredDevice) {
        guard let peripheral = peripheralsByID[monitor.id] else { return }
        connect(peripheral)
        UserDefaults.standard.set(monitor.id.uuidString, forKey: savedMonitorKey)
    }

    /// Reconnect to the previously paired monitor, if Bluetooth is on and one was saved. Safe to
    /// call when Bluetooth isn't ready yet; it no-ops, and `centralManagerDidUpdateState` retries
    /// on power-on when `autoReconnect` is set.
    func reconnectIfPaired() {
        guard
            connected == nil,
            central.state == .poweredOn,
            let stored = UserDefaults.standard.string(forKey: savedMonitorKey),
            let uuid = UUID(uuidString: stored),
            let peripheral = central.retrievePeripherals(withIdentifiers: [uuid]).first
        else { return }
        peripheralsByID[uuid] = peripheral
        connect(peripheral)
    }

    private func connect(_ peripheral: CBPeripheral) {
        central.stopScan()
        connected = peripheral
        peripheral.delegate = self
        connectionState = .connecting
        connectedName = peripheral.name
        statusMessage = "Connecting…"
        Self.log.info("connecting to \(peripheral.name ?? "unnamed", privacy: .public)")
        central.connect(peripheral, options: nil)
    }
}

extension HeartRateMonitorManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Self.log.info("central state \(central.state.rawValue)")
        switch central.state {
        case .poweredOn:
            if connectionState == .poweredOff || connectionState == .unauthorized { connectionState = .idle }
            if autoReconnect { reconnectIfPaired() }
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
        let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? "Heart-rate monitor"
        peripheralsByID[peripheral.identifier] = peripheral
        let entry = DiscoveredDevice(id: peripheral.identifier, name: name, rssi: RSSI.intValue)
        if let index = discovered.firstIndex(where: { $0.id == entry.id }) {
            discovered[index].rssi = entry.rssi
        } else {
            discovered.append(entry)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Self.log.info("connected to \(peripheral.name ?? "unnamed", privacy: .public)")
        connectionState = .connected
        connectedName = peripheral.name
        statusMessage = "Connected."
        peripheral.discoverServices([BLEUUID.heartRateService])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        Self.log.error("connect failed: \(error?.localizedDescription ?? "unknown", privacy: .public)")
        statusMessage = "Failed to connect: \(error?.localizedDescription ?? "unknown")"
        connectionState = .idle
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        Self.log.notice(
            "disconnected: \(error?.localizedDescription ?? "no error", privacy: .public)"
        )
        connectedName = nil
        lastBPM = nil
        lastBPMAt = nil
        connectionState = .connecting
        statusMessage = "Reconnecting…"
        central.connect(peripheral, options: nil)
    }
}

extension HeartRateMonitorManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            Self.log.error("service discovery failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        let services = (peripheral.services ?? []).filter { $0.uuid == BLEUUID.heartRateService }
        if services.isEmpty { Self.log.error("no Heart Rate Service on the connected device") }
        for service in services {
            peripheral.discoverCharacteristics([BLEUUID.heartRateMeasurement], for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error {
            Self.log.error("characteristic discovery failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        for characteristic in service.characteristics ?? [] where characteristic.uuid == BLEUUID.heartRateMeasurement {
            peripheral.setNotifyValue(true, for: characteristic)
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?
    ) {
        if let error {
            Self.log.error("notify subscribe failed: \(error.localizedDescription, privacy: .public)")
        } else {
            Self.log.info("HR notifications \(characteristic.isNotifying ? "on" : "off", privacy: .public)")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            Self.log.error("HR update failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        // Range-gate at the source so a glitchy strap can't push 0/garbage into the hub's EWMA or
        // the Zwift rebroadcast. Matches ErgController.validHRRange.
        guard characteristic.uuid == BLEUUID.heartRateMeasurement, let data = characteristic.value else { return }
        guard let bpm = HeartRateMeasurement.bpm(data), (30...230).contains(bpm) else {
            Self.log.debug("dropped out-of-range or unparseable HR frame (\(data.count) bytes)")
            return
        }
        lastBPM = bpm
        lastBPMAt = Date()
        onHeartRate?(bpm, Date())
    }
}
