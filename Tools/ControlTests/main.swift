import Foundation

var failures = 0
var checks = 0
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    if !condition() { failures += 1; print("FAIL: \(message)") }
}
func controller() -> ErgController {
    let c = ErgController(
        config: ErgControllerConfig(
            targetHeartRate: 140, powerFloor: 60, powerCeiling: 300, startingPower: 100))
    c.start()
    return c
}
let cold = controller()
for _ in 0..<23 {
    expect(
        cold.update(filteredHR: 80, isPedaling: true, dt: 5).targetPower == 100,
        "warm-up holds starting watts despite low HR")
}
// First increase only after two minutes of valid pedaling observations.
expect(cold.update(filteredHR: 80, isPedaling: true, dt: 5).targetPower == 105, "first 5 W step")
for _ in 0..<5 {
    expect(cold.update(filteredHR: 80, isPedaling: true, dt: 5).targetPower == 105, "wait 30 s between steps")
}
expect(cold.update(filteredHR: 80, isPedaling: true, dt: 5).targetPower == 110, "second 5 W step")
for hr in [137.0, 140, 143] {
    for _ in 0..<30 {
        expect(cold.update(filteredHR: hr, isPedaling: true, dt: 5).targetPower == 110, "inclusive band holds watts")
    }
}
for hr in [130.0, 140, 130, 140, 150, 140] {
    expect(
        cold.update(filteredHR: hr, isPedaling: true, dt: 5).targetPower == 110, "brief excursions do not move watts")
}
let hot = controller()
for _ in 0..<5 { _ = hot.update(filteredHR: 145, isPedaling: true, dt: 5) }
expect(hot.update(filteredHR: 145, isPedaling: true, dt: 5).targetPower == 95, "warm-up allows ordinary reductions")
let hotter = controller()
for _ in 0..<2 { _ = hotter.update(filteredHR: 150, isPedaling: true, dt: 5) }
expect(
    hotter.update(filteredHR: 150, isPedaling: true, dt: 5).targetPower == 90, "sustained 10 bpm excess reduces sooner")
for _ in 0..<2 {
    expect(hotter.update(filteredHR: 150, isPedaling: true, dt: 5).targetPower == 90, "urgent step still waits")
}
expect(hotter.update(filteredHR: 150, isPedaling: true, dt: 5).targetPower == 80, "urgent repeat after 15 s")
let loss = controller()
for _ in 0..<3 {
    expect(loss.update(filteredHR: nil, isPedaling: true, dt: 5).targetPower == 100, "brief HR loss holds")
}
let lost = loss.update(filteredHR: nil, isPedaling: true, dt: 5)
expect(lost.targetPower == 90 && lost.state == .hrLost, "20 s HR loss reduces power")
for _ in 0..<20 { _ = loss.update(filteredHR: .nan, isPedaling: true, dt: 5) }
expect(loss.update(filteredHR: nil, isPedaling: true, dt: 5).targetPower == 60, "loss respects floor")
expect(loss.update(filteredHR: 90, isPedaling: true, dt: 5).targetPower == 60, "resume does not jump to start power")
let coast = controller()
expect(coast.update(filteredHR: 100, isPedaling: false, dt: 5).targetPower == 100, "brief coast holds")
let stopped = coast.update(filteredHR: 100, isPedaling: false, dt: 5)
expect(stopped.targetPower == 90 && stopped.state == .holdingNoCadence, "sustained coast releases")
let cap = controller()
cap.config.powerCeiling = 75
expect(cap.update(filteredHR: 100, isPedaling: true, dt: 5).targetPower == 75, "lowered ceiling applies immediately")
cap.config.powerCeiling = 65
expect(cap.update(filteredHR: nil, isPedaling: false, dt: 5).targetPower == 65, "ceiling applies during dropout")
cap.config.powerFloor = 80
expect(cap.update(filteredHR: 100, isPedaling: true, dt: 5).targetPower == 65, "ceiling wins inverted bounds")
let edit = controller()
for _ in 0..<30 { _ = edit.update(filteredHR: 140, isPedaling: true, dt: 5) }
edit.config.targetHeartRate = 160
edit.markTargetChanged()
for _ in 0..<5 {
    expect(edit.update(filteredHR: 140, isPedaling: true, dt: 5).targetPower == 100, "target edit cannot jump watts")
}
expect(edit.update(filteredHR: 140, isPedaling: true, dt: 5).targetPower == 105, "edited target eventually steps")
let late = controller()
expect(late.update(filteredHR: 80, isPedaling: true, dt: 3600).targetPower == 100, "late callback cannot skip warm-up")
expect(late.update(filteredHR: 80, isPedaling: true, dt: .nan).targetPower == 100, "invalid elapsed time holds")
late.stop()
expect(late.update(filteredHR: 80, isPedaling: true, dt: 5).state == .idle, "stop is idle")
late.start()
expect(late.update(filteredHR: 80, isPedaling: true, dt: 5).targetPower == 100, "restart resets warm-up and power")

var now = Date(timeIntervalSince1970: 1_000_000)
let hub = HeartRateHub(now: { now })
hub.ingest(bpm: 140, sampleTime: now.addingTimeInterval(-3600), source: "watch")
expect(!hub.isFresh && hub.controlBPM == nil, "old measurements rejected")
hub.ingest(bpm: .nan, sampleTime: now, source: "watch")
hub.ingest(bpm: 240, sampleTime: now, source: "watch")
hub.ingest(bpm: 140, sampleTime: now.addingTimeInterval(60), source: "watch")
expect(hub.currentBPM == nil, "invalid values and future measurements rejected")
hub.ingest(bpm: 140, sampleTime: now, source: "watch")
expect(hub.controlBPM == 140, "fresh measurement accepted")
let original = now
now += 5
hub.ingest(bpm: 190, sampleTime: original, source: "watch")
hub.ingest(bpm: 190, sampleTime: original.addingTimeInterval(-1), source: "watch")
expect(hub.lastUpdate == original && hub.controlBPM == 140, "duplicates and reordered measurements ignored")
now += 7
expect(hub.controlBPM == nil, "measurement expires at 12 seconds")
for _ in 0..<30 {
    now += 5
    hub.ingest(bpm: 140, sampleTime: now, source: "watch")
    expect(hub.controlBPM == 140, "identical BPM with new timestamps stays fresh beyond 90 seconds")
}
hub.ingest(bpm: 120, sampleTime: now, source: "strap")
expect(hub.controlBPM == 120, "source change resets smoothing")
now += 20
hub.ingest(bpm: 100, sampleTime: now, source: "strap")
expect(hub.controlBPM == 100, "recovery starts a new filter rather than blending stale HR")
hub.reset()
expect(hub.currentBPM == nil && hub.controlBPM == nil, "reset clears signal")
let legacy = Data(#"{"targetHeartRate":135,"ftp":250,"aggressiveness":"responsive","hrSource":"bluetooth"}"#.utf8)
let settings = try JSONDecoder().decode(RideSettings.self, from: legacy)
expect(
    settings.targetHeartRate == 135 && settings.ftp == 250 && settings.hrSource == .bluetooth,
    "legacy settings survive removed responsiveness option")

// Synthetic first-order riders: smoke-test closed-loop behavior, not physiological validation.
for gain in [0.25, 0.4, 0.6] {
    for tau in [45.0, 90.0] {
        for delay in [3, 6] {
            let c = controller()
            var hr = 90.0
            var pending = Array(repeating: 100.0, count: delay)
            var inBand = 0
            var peak = hr
            for tick in 0..<480 {
                let output = c.update(filteredHR: hr, isPedaling: true, dt: 5)
                expect((60...300).contains(output.targetPower), "simulation obeys power bounds")
                pending.append(Double(output.targetPower))
                let equilibrium = 90 + gain * pending.removeFirst()
                hr += (1 - exp(-5 / tau)) * (equilibrium - hr)
                peak = max(peak, hr)
                if tick >= 300 && abs(hr - 140) <= 3 { inBand += 1 }
            }
            expect(inBand >= 144, "synthetic rider spends at least 80% of final 15 min in band")
            print(
                "SIM gain=\(gain) tau=\(tau) delay=\(delay * 5)s: final-band=\(inBand)/180 peak=\(String(format: "%.1f", peak))"
            )
        }
    }
}

print("\(checks) checks, \(failures) failures")
exit(failures == 0 ? 0 : 1)
