import CoreBluetooth
import Foundation

enum BLEUUID {
    static let fitnessMachineService = CBUUID(string: "1826")
    static let indoorBikeData = CBUUID(string: "2AD2")
    static let fitnessMachineControlPoint = CBUUID(string: "2AD9")
    static let fitnessMachineStatus = CBUUID(string: "2ADA")

    static let cyclingPowerService = CBUUID(string: "1818")
    static let cyclingPowerMeasurement = CBUUID(string: "2A63")
    static let wahooControlPoint = CBUUID(string: "A026E005-0A7D-4AB3-97FA-F1500F9FEB8B")

    static let trainerServices = [fitnessMachineService, cyclingPowerService]
}

/// Sequential little-endian reader with bounds checking for BLE packet payloads.
private struct ByteReader {
    private let bytes: [UInt8]
    private var index = 0

    init(_ data: Data) { bytes = [UInt8](data) }

    private var remaining: Int { bytes.count - index }

    mutating func u8() -> Int? {
        guard remaining >= 1 else { return nil }
        defer { index += 1 }
        return Int(bytes[index])
    }

    mutating func u16() -> Int? {
        guard remaining >= 2 else { return nil }
        defer { index += 2 }
        return Int(bytes[index]) | (Int(bytes[index + 1]) << 8)
    }

    mutating func i16() -> Int? {
        guard let value = u16() else { return nil }
        return Int(Int16(bitPattern: UInt16(value)))
    }

    mutating func skip(_ count: Int) { index += count }
}

/// FTMS Indoor Bike Data (0x2AD2): a uint16 flags field followed by optional
/// fields whose presence is determined bit-by-bit.
struct IndoorBikeData {
    var speedKPH: Double?
    var cadenceRPM: Double?
    var powerWatts: Int?
    var heartRate: Int?

    static func parse(_ data: Data) -> IndoorBikeData {
        var reader = ByteReader(data)
        var result = IndoorBikeData()
        guard let flags = reader.u16() else { return result }

        // Bit 0 is inverted: instantaneous speed is present when the bit is 0.
        if flags & 0x0001 == 0, let raw = reader.u16() { result.speedKPH = Double(raw) * 0.01 }
        if flags & 0x0002 != 0 { _ = reader.u16() }  // average speed
        if flags & 0x0004 != 0, let raw = reader.u16() { result.cadenceRPM = Double(raw) * 0.5 }
        if flags & 0x0008 != 0 { _ = reader.u16() }  // average cadence
        if flags & 0x0010 != 0 { reader.skip(3) }  // total distance (uint24)
        if flags & 0x0020 != 0 { _ = reader.i16() }  // resistance level
        if flags & 0x0040 != 0 { result.powerWatts = reader.i16() }  // instantaneous power
        if flags & 0x0080 != 0 { _ = reader.i16() }  // average power
        if flags & 0x0100 != 0 { reader.skip(5) }  // expended energy
        if flags & 0x0200 != 0, let hr = reader.u8() { result.heartRate = hr }
        return result
    }
}

/// Instantaneous power from Cycling Power Measurement (0x2A63), used as a
/// fallback when FTMS Indoor Bike Data is unavailable.
enum CyclingPowerMeasurement {
    static func instantaneousPower(_ data: Data) -> Int? {
        var reader = ByteReader(data)
        guard reader.u16() != nil else { return nil }  // flags
        return reader.i16()  // instantaneous power follows immediately
    }
}

/// FTMS Fitness Machine Control Point (0x2AD9) command builders.
enum FTMSControlPoint {
    static let requestControl = Data([0x00])

    static func setTargetPower(watts: Int) -> Data {
        let value = UInt16(bitPattern: Int16(clamping: watts))
        return Data([0x05, UInt8(value & 0xFF), UInt8(value >> 8)])
    }
}

/// FTMS Control Point response indication: [0x80, requestOpcode, resultCode].
struct FTMSResponse {
    let requestOpcode: UInt8
    let resultCode: UInt8

    var isSuccess: Bool { resultCode == 0x01 }

    init?(_ data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count >= 3, bytes[0] == 0x80 else { return nil }
        requestOpcode = bytes[1]
        resultCode = bytes[2]
    }

    var resultDescription: String {
        switch resultCode {
        case 0x01: return "success"
        case 0x02: return "opcode not supported"
        case 0x03: return "invalid parameter"
        case 0x04: return "operation failed"
        case 0x05: return "control not permitted"
        default: return "unknown (\(resultCode))"
        }
    }
}

/// FTMS Fitness Machine Status (0x2ADA): broadcast to every connected client
/// when a setting changes, which lets us notice another app controlling the trainer.
enum FTMSStatus {
    case targetPowerChanged(Int)
    case simulationParametersChanged
    case controlPermissionLost
    case other(UInt8)

    init(_ data: Data) {
        let bytes = [UInt8](data)
        guard let opcode = bytes.first else {
            self = .other(0)
            return
        }
        switch opcode {
        case 0x08:
            guard bytes.count >= 3 else {
                self = .other(opcode)
                return
            }
            let raw = UInt16(bytes[1]) | (UInt16(bytes[2]) << 8)
            self = .targetPowerChanged(Int(Int16(bitPattern: raw)))
        case 0x12: self = .simulationParametersChanged
        case 0xFF: self = .controlPermissionLost
        default: self = .other(opcode)
        }
    }
}

/// Wahoo proprietary control (characteristic A026E005 within Cycling Power Service).
enum WahooTrainer {
    static let unlock = Data([0x20, 0xEE, 0xFC])

    static func setErgPower(watts: Int) -> Data {
        let value = UInt16(clamping: max(0, watts))
        return Data([0x42, UInt8(value & 0xFF), UInt8(value >> 8)])
    }
}
