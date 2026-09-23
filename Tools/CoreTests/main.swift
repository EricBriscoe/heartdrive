import Foundation

var checks = 0
var failures = 0
func expect(_ value: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    if !value() { failures += 1; print("FAIL: \(message)") }
}
func hr(_ time: Double, _ bpm: Double = 120) -> HeartRate {
    HeartRate(bpm: bpm, at: Date(timeIntervalSince1970: time))
}
struct Random: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

// Link boundaries and historical timestamp latch regression.
do {
    var link = HeartRateLink()
    expect(link.record(hr(5000), now: 0), "first sample accepted")
    expect(!link.record(hr(5000), now: 1), "exact duplicate ignored")
    expect(link.record(hr(2), now: 2), "future timestamp cannot latch sender")
    let send = link.send(now: 2, activated: true, reachable: true, hasRegisters: false)
    expect(send.live == hr(2) && send.context, "send current sample on both paths")
    expect(link.send(now: 2.5, activated: true, reachable: true, hasRegisters: false).live == nil,
           "live sends throttled to one second")
    expect(!link.send(now: 6.999, activated: true, reachable: true, hasRegisters: false).context,
           "context cannot send before five seconds")
    expect(link.send(now: 7, activated: true, reachable: true, hasRegisters: false).context,
           "context sends at exact five-second boundary")
    expect(link.recover(now: 8, reachable: true) == nil, "reactivation threshold is strict")
    expect(link.recover(now: 9, reachable: true) == .reactivate, "delivery gap reactivates")
    _ = link.record(hr(23), now: 23)
    expect(link.recover(now: 24, reachable: true) != .restart, "restart threshold is strict")
    expect(link.recover(now: 25, reachable: true) == .restart, "reachable delivery failure restarts")
}
do {
    var link = HeartRateLink()
    _ = link.record(hr(0), now: 0)
    let generation = link.generation
    _ = link.send(now: 0, activated: true, reachable: true, hasRegisters: false)
    link.reset()
    expect(link.recover(now: 100, reachable: true) == nil, "stopped stream stays stopped")
    expect(link.record(hr(-100), now: 1), "new stream accepts earlier timestamp")
    link.delivered(now: 50, generation: generation)
    expect(link.lastDeliveredAt == 1, "old asynchronous reply cannot acknowledge new workout")
    expect(!link.send(now: 1, activated: true, reachable: false, hasRegisters: false).context,
           "restart preserves context throttle")
    link.delivered(now: 3, generation: link.generation)
    expect(link.lastDeliveredAt == 3, "current asynchronous reply acknowledges delivery")
    expect(link.recover(now: 21, reachable: false) != .restart, "capture stall threshold is strict")
    expect(link.recover(now: 21.001, reachable: false) == .restart, "capture stall restarts even offline")
}
do {
    var link = HeartRateLink()
    expect(link.send(now: 0, activated: true, reachable: true, hasRegisters: true).context,
           "settings sync works before HR capture")
    expect(!link.send(now: 5, activated: false, reachable: true, hasRegisters: true).context,
           "inactive session never sends")
    expect(link.send(now: 5, activated: true, reachable: true, hasRegisters: true).context,
           "activation does not lose queued context")
}

// Seeded bursts, resets and reachability flaps cannot break the shared rate limits.
for seed in 0..<100 {
    var rng = Random(state: UInt64(seed))
    var link = HeartRateLink()
    var lastContext = -Double.infinity, lastLive = -Double.infinity
    for step in 0..<500 {
        let now = Double(step) / 4
        if rng.next() % 17 == 0 { link.reset() }
        _ = link.record(hr(now), now: now)
        let reachable = rng.next() % 3 != 0
        let send = link.send(now: now, activated: true, reachable: reachable, hasRegisters: true)
        if send.context {
            expect(now - lastContext >= 5, "context cadence seed=\(seed) step=\(step)")
            lastContext = now
        }
        if send.live != nil {
            expect(reachable && now - lastLive >= 1, "live cadence seed=\(seed) step=\(step)")
            lastLive = now
        }
    }
}

// Synchronization uses valid histories: one author never issues two values for
// the same version. Final exchange must converge despite delayed/duplicate delivery.
for seed in 0..<100 {
    var rng = Random(state: UInt64(seed))
    let phone = SyncedValue<Int>(me: .phone), watch = SyncedValue<Int>(me: .watch)
    phone.seed(120)
    watch.seed(120)
    var messages: [(toPhone: Bool, value: Register<Int>)] = []
    for step in 0..<100 {
        let authorIsPhone = rng.next() % 2 == 0
        let author = authorIsPhone ? phone : watch
        if author.setLocal(100 + Int(rng.next() % 60)), let value = author.register {
            messages.append((!authorIsPhone, value))
        }
        if !messages.isEmpty {
            let message = messages[Int(rng.next() % UInt64(messages.count))]
            let recipient = message.toPhone ? phone : watch
            _ = recipient.receive(message.value)
            expect(recipient.receive(message.value) == nil, "duplicate no-op seed=\(seed) step=\(step)")
            let state = recipient.register!
            expect(!recipient.setLocal(state.value) && recipient.register == state,
                   "received value cannot echo seed=\(seed) step=\(step)")
        }
    }
    let p = phone.register!, w = watch.register!
    _ = phone.receive(w)
    _ = watch.receive(p)
    expect(phone.register == watch.register, "convergence seed=\(seed)")
    let encoded = try JSONEncoder().encode(phone.register!)
    let decoded = try JSONDecoder().decode(Register<Int>.self, from: encoded)
    expect(decoded == phone.register!, "wire round trip seed=\(seed)")
}
do {
    let phone = SyncedValue<Bool>(me: .phone), watch = SyncedValue<Bool>(me: .watch)
    // Distinct initial values produce genuine simultaneous version-one edits.
    phone.seed(false); watch.seed(true)
    _ = phone.setLocal(true); _ = watch.setLocal(false)
    let p = phone.register!, w = watch.register!
    _ = phone.receive(w); _ = watch.receive(p)
    expect(phone.register == watch.register && watch.register?.value == true, "phone wins version tie")
}

// Malformed packets cannot fabricate measurements; complete prefix fields remain usable.
do {
    let truncated = IndoorBikeData.parse(Data([0x43, 0x00, 0xA0])) // average speed + power
    expect(truncated.powerWatts == nil, "truncated average speed cannot become power")
    expect(HeartRateMeasurement.bpm(Data()) == nil, "empty HR packet")
    expect(HeartRateMeasurement.bpm(Data([1, 120])) == nil, "truncated 16-bit HR")
    expect(HeartRateMeasurement.bpm(Data([0, 120])) == 120, "8-bit HR")
    expect(HeartRateMeasurement.bpm(Data([1, 44, 1])) == 300, "16-bit HR")
    expect(CyclingPowerMeasurement.instantaneousPower(Data([0, 0, 255, 255])) == -1, "signed power")
}

// Enumerate all optional-field combinations consumed by IndoorBikeData. For
// every packet prefix, a measurement exists iff its own complete field exists.
for flags in 0..<1024 {
    var bytes: [UInt8] = [UInt8(flags & 255), UInt8(flags >> 8)]
    var speedEnd: Int?, cadenceEnd: Int?, powerEnd: Int?
    if flags & 1 == 0 { bytes += [0xD2, 0x04]; speedEnd = bytes.count }
    if flags & 2 != 0 { bytes += [0, 0] }
    if flags & 4 != 0 { bytes += [0xB4, 0]; cadenceEnd = bytes.count }
    if flags & 8 != 0 { bytes += [0, 0] }
    if flags & 16 != 0 { bytes += [0, 0, 0] }
    if flags & 32 != 0 { bytes += [0, 0] }
    if flags & 64 != 0 { bytes += [0xFA, 0]; powerEnd = bytes.count }
    if flags & 128 != 0 { bytes += [0, 0] }
    if flags & 256 != 0 { bytes += [0, 0, 0, 0, 0] }
    if flags & 512 != 0 { bytes += [137] }
    for length in 0...bytes.count {
        let sample = IndoorBikeData.parse(Data(bytes.prefix(length)))
        let label = "flags=\(flags) length=\(length)"
        expect(sample.speedKPH == (speedEnd.map { length >= $0 } == true ? 12.34 : nil), "speed \(label)")
        expect(sample.cadenceRPM == (cadenceEnd.map { length >= $0 } == true ? 90 : nil), "cadence \(label)")
        expect(sample.powerWatts == (powerEnd.map { length >= $0 } == true ? 250 : nil), "power \(label)")
    }
}
for seed in 0..<5000 {
    var rng = Random(state: UInt64(seed))
    let bytes = (0..<Int(rng.next() % 40)).map { _ in UInt8(truncatingIfNeeded: rng.next() >> 32) }
    let data = Data(bytes)
    _ = IndoorBikeData.parse(data)
    _ = CyclingPowerMeasurement.instantaneousPower(data)
    _ = HeartRateMeasurement.bpm(data)
    _ = FTMSResponse(data)
    _ = FTMSStatus(data)
    let watts = Int(truncatingIfNeeded: rng.next())
    let command = FTMSControlPoint.setTargetPower(watts: watts)
    expect(command.count == 3 && command[0] == 5, "FTMS command shape seed=\(seed)")
    let signed = Int(Int16(bitPattern: UInt16(command[1]) | UInt16(command[2]) << 8))
    expect(signed == Int(Int16(clamping: watts)), "FTMS clamp seed=\(seed)")
    let wahoo = WahooTrainer.setErgPower(watts: watts)
    expect(wahoo.count == 3 && wahoo[0] == 0x42, "Wahoo command shape seed=\(seed)")
    expect(Int(wahoo[1]) | Int(wahoo[2]) << 8 == Int(UInt16(clamping: max(0, watts))), "Wahoo clamp seed=\(seed)")
}

// Buffered/invalid samples never extend freshness, and switching HR sources
// starts a new filter rather than blending unrelated measurements.
do {
    var now = Date(timeIntervalSince1970: 100)
    let hub = HeartRateHub(now: { now })
    hub.ingest(bpm: 120, sampleTime: now, source: "watch")
    now += 11
    hub.ingest(bpm: 150, sampleTime: now - 11, source: "watch")
    expect(hub.currentBPM == 120, "duplicate cannot change BPM")
    now += 1
    expect(!hub.isFresh && hub.controlBPM == nil, "duplicate cannot extend freshness")
    for bpm in [Double.nan, .infinity, -.infinity, 29, 231] {
        hub.ingest(bpm: bpm, sampleTime: now, source: "watch")
        expect(!hub.isFresh, "invalid BPM cannot revive signal")
    }
    hub.ingest(bpm: 160, sampleTime: now + 3, source: "watch")
    expect(!hub.isFresh, "future sample rejected")
    hub.ingest(bpm: 140, sampleTime: now, source: "strap")
    expect(hub.controlBPM == 140, "source switch resets filter")
    hub.reset()
    expect(hub.currentBPM == nil && hub.controlBPM == nil, "reset clears stream")
}
print("Core checks: \(checks), failures: \(failures)")
if failures > 0 { exit(1) }
