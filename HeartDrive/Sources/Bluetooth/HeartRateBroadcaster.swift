import CoreBluetooth
import Foundation
import Observation
import os

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
    /// Centrals (e.g. Zwift) currently subscribed to the measurement characteristic, keyed by
    /// identifier so a duplicate subscribe or a missed unsubscribe can't skew the count.
    private(set) var subscribers: Set<UUID> = []
    var subscriberCount: Int { subscribers.count }
    /// Whether a reading has ever been handed to the broadcaster (the value it would send).
    var hasReading: Bool { latestBPM != nil }
    /// The BPM most recently pushed to subscribers, for the dashboard and for logs.
    private(set) var lastSentBPM: Int?
    private(set) var lastSentAt: Date?

    private static let log = Logger(subsystem: "com.ericbriscoe.HeartDrive", category: "broadcast")

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
        Self.log.info("start requested")
        if manager == nil {
            manager = CBPeripheralManager(delegate: self, queue: nil)
        } else {
            configureAndAdvertise()
        }
    }

    func stop() {
        shouldAdvertise = false
        Self.log.info("stop requested")
        stopHeartbeat()
        manager?.stopAdvertising()
        manager?.removeAllServices()
        characteristic = nil
        subscribers.removeAll()
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
            Self.log.notice("advertising had stopped; restarting")
            manager.startAdvertising(advertisement)
        }
        // Heart Rate Measurement: flags byte (0x00 = uint8 BPM) followed by the value.
        let payload = Data([0x00, UInt8(clamping: bpm)])
        // `updateValue` returns false when the transmit queue is full; iOS then calls
        // `peripheralManagerIsReady`, which resends. Only count a queued send as sent.
        guard manager.updateValue(payload, for: characteristic, onSubscribedCentrals: nil) else {
            Self.log.debug("transmit queue full; will resend when ready")
            return
        }
        if !subscribers.isEmpty {
            lastSentBPM = bpm
            lastSentAt = Date()
        }
    }

    private func configureAndAdvertise() {
        guard let manager, manager.state == .poweredOn, shouldAdvertise else { return }
        // Removing the service drops any subscribers without a didUnsubscribe callback.
        manager.removeAllServices()
        subscribers.removeAll()
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
        Self.log.info("service added; advertising as HeartDrive")
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
        Self.log.info("peripheral manager state \(peripheral.state.rawValue)")
        if peripheral.state == .poweredOn {
            configureAndAdvertise()
        } else {
            stopHeartbeat()
            subscribers.removeAll()
            state = .off
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let error {
            Self.log.error("add service failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        if let error {
            Self.log.error("advertising failed: \(error.localizedDescription, privacy: .public)")
        } else {
            Self.log.info("advertising started")
        }
    }

    func peripheralManager(
        _ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic
    ) {
        subscribers.insert(central.identifier)
        Self.log.info("central subscribed (\(self.subscriberCount) total), latest bpm \(self.latestBPM ?? -1)")
        state = .connected
        sendCurrent()
    }

    func peripheralManager(
        _ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic
    ) {
        subscribers.remove(central.identifier)
        Self.log.info("central unsubscribed (\(self.subscriberCount) remain)")
        if subscribers.isEmpty {
            state = shouldAdvertise ? .advertising : .off
        }
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        sendCurrent()
    }
}
