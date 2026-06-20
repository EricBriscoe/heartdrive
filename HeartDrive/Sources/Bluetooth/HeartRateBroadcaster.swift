import CoreBluetooth
import Foundation
import Observation

/// Re-advertises the rider's heart rate as a standard BLE Heart Rate Service
/// (0x180D) peripheral so Zwift (on a separate device) can pair it like any
/// chest strap and show the watch's heart rate in-game. Notifies at a steady
/// ~1 Hz like a real strap so the central never times the sensor out.
@Observable
final class HeartRateBroadcaster: NSObject {
    enum State: Equatable {
        case off
        case advertising
        case connected
    }

    private(set) var state: State = .off

    private var manager: CBPeripheralManager?
    private var characteristic: CBMutableCharacteristic?
    private var latestBPM: Int?
    private var shouldAdvertise = false
    private var heartbeat: Timer?

    private let serviceUUID = CBUUID(string: "180D")
    private let measurementUUID = CBUUID(string: "2A37")
    private var advertisement: [String: Any] {
        [CBAdvertisementDataServiceUUIDsKey: [serviceUUID], CBAdvertisementDataLocalNameKey: "HeartDrive"]
    }

    func start() {
        shouldAdvertise = true
        if manager == nil {
            manager = CBPeripheralManager(delegate: self, queue: nil)
        } else {
            configureAndAdvertise()
        }
    }

    func stop() {
        shouldAdvertise = false
        stopHeartbeat()
        manager?.stopAdvertising()
        manager?.removeAllServices()
        characteristic = nil
        state = .off
    }

    func update(bpm: Int) {
        latestBPM = bpm
        sendCurrent()
    }

    private func sendCurrent() {
        guard let manager, let characteristic, let bpm = latestBPM, state != .off else { return }
        // Re-assert advertising if the system dropped it (e.g. a brief background).
        if shouldAdvertise, manager.state == .poweredOn, !manager.isAdvertising {
            manager.startAdvertising(advertisement)
        }
        // Heart Rate Measurement: flags byte (0x00 = uint8 BPM) followed by the value.
        let payload = Data([0x00, UInt8(clamping: bpm)])
        manager.updateValue(payload, for: characteristic, onSubscribedCentrals: nil)
    }

    private func configureAndAdvertise() {
        guard let manager, manager.state == .poweredOn, shouldAdvertise else { return }
        manager.removeAllServices()
        let characteristic = CBMutableCharacteristic(
            type: measurementUUID,
            properties: [.notify],
            value: nil,
            permissions: [.readable])
        let service = CBMutableService(type: serviceUUID, primary: true)
        service.characteristics = [characteristic]
        manager.add(service)
        self.characteristic = characteristic
        manager.startAdvertising(advertisement)
        state = .advertising
        startHeartbeat()
    }

    private func startHeartbeat() {
        stopHeartbeat()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.sendCurrent() }
        RunLoop.main.add(timer, forMode: .common)
        heartbeat = timer
    }

    private func stopHeartbeat() {
        heartbeat?.invalidate()
        heartbeat = nil
    }
}

extension HeartRateBroadcaster: CBPeripheralManagerDelegate {
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        if peripheral.state == .poweredOn {
            configureAndAdvertise()
        } else {
            stopHeartbeat()
            state = .off
        }
    }

    func peripheralManager(
        _ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic
    ) {
        state = .connected
        sendCurrent()
    }

    func peripheralManager(
        _ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic
    ) {
        state = shouldAdvertise ? .advertising : .off
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        sendCurrent()
    }
}
