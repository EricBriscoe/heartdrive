import CoreBluetooth
import Foundation
import Observation

enum HRMonitorConnectionState: Equatable {
    case poweredOff
    case unauthorized
    case idle
    case scanning
    case connecting
    case connected
}

struct DiscoveredHRMonitor: Identifiable, Equatable {
    let id: UUID
    let name: String
    var rssi: Int
}

/// Reads heart rate from a standard BLE heart-rate monitor (GATT Heart Rate Service 0x180D,
/// Heart Rate Measurement 0x2A37) as an alternative to the Apple Watch. A read-only mirror of
/// `TrainerManager`'s central pattern — scan → connect → subscribe → parse → emit — with none of
/// the ERG/control machinery. Owns its own `CBCentralManager`; the phone already runs a second
/// central (`TrainerManager`) and a peripheral (`HeartRateBroadcaster`) concurrently.
@Observable
final class HeartRateMonitorManager: NSObject {
    private(set) var connectionState: HRMonitorConnectionState = .idle
    private(set) var discovered: [DiscoveredHRMonitor] = []
    private(set) var connectedName: String?
    private(set) var statusMessage: String?

    /// Fired on every Heart Rate Measurement notification with (bpm, receiptTime). 0x2A37 carries
    /// no sample timestamp, so receipt time is the sample time — fine for `HeartRateHub`'s dedupe.
    var onHeartRate: ((Int, Date) -> Void)?

    /// Whether to reconnect to the paired monitor when Bluetooth powers on. Set by AppModel from
    /// the HR-source setting so a strap is only auto-connected while the Bluetooth source is chosen.
    var autoReconnect = false

    var isConnected: Bool { connectionState == .connected }

    private var central: CBCentralManager!
    private var peripheralsByID: [UUID: CBPeripheral] = [:]
    private var connected: CBPeripheral?
    private var intentionalDisconnect = false

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

    func connect(_ monitor: DiscoveredHRMonitor) {
        guard let peripheral = peripheralsByID[monitor.id] else { return }
        connect(peripheral)
        UserDefaults.standard.set(monitor.id.uuidString, forKey: savedMonitorKey)
    }

    func disconnect() {
        intentionalDisconnect = true
        if let connected { central.cancelPeripheralConnection(connected) }
        connected = nil
        connectedName = nil
        connectionState = .idle
        statusMessage = nil
        UserDefaults.standard.removeObject(forKey: savedMonitorKey)
    }

    /// Reconnect to the previously paired monitor, if Bluetooth is on and one was saved. Safe to
    /// call when Bluetooth isn't ready yet — it no-ops, and `centralManagerDidUpdateState` retries
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
        intentionalDisconnect = false
        central.stopScan()
        connected = peripheral
        peripheral.delegate = self
        connectionState = .connecting
        connectedName = peripheral.name
        statusMessage = "Connecting…"
        central.connect(peripheral, options: nil)
    }
}

extension HeartRateMonitorManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
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
        let entry = DiscoveredHRMonitor(id: peripheral.identifier, name: name, rssi: RSSI.intValue)
        if let index = discovered.firstIndex(where: { $0.id == entry.id }) {
            discovered[index].rssi = entry.rssi
        } else {
            discovered.append(entry)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connectionState = .connected
        connectedName = peripheral.name
        statusMessage = "Connected."
        peripheral.discoverServices([BLEUUID.heartRateService])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        statusMessage = "Failed to connect: \(error?.localizedDescription ?? "unknown")"
        connectionState = .idle
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        connectedName = nil
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

extension HeartRateMonitorManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for service in peripheral.services ?? [] where service.uuid == BLEUUID.heartRateService {
            peripheral.discoverCharacteristics([BLEUUID.heartRateMeasurement], for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for characteristic in service.characteristics ?? [] where characteristic.uuid == BLEUUID.heartRateMeasurement {
            peripheral.setNotifyValue(true, for: characteristic)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        // Range-gate at the source so a glitchy strap can't push 0/garbage into the hub's EWMA or
        // the Zwift rebroadcast. Matches ErgController.validHRRange.
        guard characteristic.uuid == BLEUUID.heartRateMeasurement, let data = characteristic.value,
            let bpm = HeartRateMeasurement.bpm(data), (30...230).contains(bpm)
        else { return }
        onHeartRate?(bpm, Date())
    }
}
