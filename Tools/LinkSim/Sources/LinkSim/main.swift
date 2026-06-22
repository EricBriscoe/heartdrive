import Foundation

// Deterministic simulator: drives a virtual clock, generates HR samples, ticks the
// sender, lets an `adversary` mutate the transport over time, and measures whether the
// receiver ever stalls while the channel was capable of delivering.
final class Sim {
    var now = 0.0
    let transport = FlakyTransport()
    let receiver: HeartRateReceiver
    var sender: HeartRateSender!
    var restarts = 0
    var hrSuppressed = false
    private var bpm = 78.0

    init(contextInterval: TimeInterval, staleAfter: TimeInterval = 12, enableHealing: Bool = true) {
        receiver = HeartRateReceiver(staleAfter: staleAfter)
        transport.clock = { [unowned self] in self.now }
        transport.onDeliver = { [unowned self] hr in self.receiver.ingest(hr, now: self.now) }
        sender = HeartRateSender(transport: transport, contextInterval: contextInterval, enableHealing: enableHealing)
        sender.onRequestRestart = { [unowned self] in
            self.restarts += 1
            // A workout restart re-activates the session (clears a soft wedge) and the
            // fresh workout resumes HR immediately. Model that as a re-activation.
            self.transport.activate()
        }
        transport.activate()
    }

    struct Result { var maxStaleGap = 0.0; var restarts = 0; var wedged = false }

    /// `adversary` mutates the transport each step and returns whether the channel is
    /// physically capable right now (false during a forced blackout, when staleness is
    /// unavoidable and excluded from the gap metric).
    func run(_ duration: TimeInterval, hrInterval: TimeInterval = 5,
             adversary: (Sim) -> Bool = { _ in true }) -> Result {
        var r = Result()
        var nextHR = now, nextTick = now
        var staleSince: TimeInterval?
        let end = now + duration
        while now < end {
            let capable = adversary(self)
            transport.pump(now: now)
            if now >= nextHR {
                if hrSuppressed {
                    nextHR = now + hrInterval
                } else {
                    bpm += Double((Int(now) % 5) - 2)
                    sender.record(HeartRate(bpm: bpm, at: now), now: now)
                    nextHR += hrInterval
                }
            }
            if now >= nextTick { sender.tick(now: now); nextTick += 2 }
            transport.pump(now: now)
            if transport.wedged { r.wedged = true }
            let fresh = receiver.isFresh(now: now)
            if now > 8, capable {
                if !fresh { if staleSince == nil { staleSince = now } }
                else if let s = staleSince { r.maxStaleGap = max(r.maxStaleGap, now - s); staleSince = nil }
            } else {
                staleSince = nil
            }
            now += 0.25
        }
        if let s = staleSince { r.maxStaleGap = max(r.maxStaleGap, now - s) }
        r.restarts = restarts
        return r
    }
}

struct Check { let name: String; let pass: Bool; let detail: String }
var checks: [Check] = []
func expect(_ name: String, _ pass: Bool, _ detail: String) {
    checks.append(Check(name: name, pass: pass, detail: detail))
    print("  [\(pass ? "PASS" : "FAIL")] \(name) — \(detail)")
}
func gap(_ v: Double) -> String { String(format: "%.1fs", v) }

let stale = 12.0

print("# 1. Steady, reachable")
do {
    let r = Sim(contextInterval: 5).run(120)
    expect("stays fresh", r.maxStaleGap < stale, "max stale \(gap(r.maxStaleGap))")
    expect("never wedges", !r.wedged, "wedged=\(r.wedged)")
    expect("no restarts", r.restarts == 0, "restarts=\(r.restarts)")
}

print("\n# 2. Reproduce the bug: OLD behavior (over-driven context, no self-heal)")
do {
    let r = Sim(contextInterval: 0, enableHealing: false).run(120) { $0.transport.reachable = false; return true }
    expect("reproduces the wedge", r.wedged, "context wedged=\(r.wedged)")
    expect("reproduces the permanent stall", r.maxStaleGap >= stale, "max stale \(gap(r.maxStaleGap)) (stuck)")
}

print("\n# 2b. Defense in depth: same over-drive, but WITH the wrapper's self-heal")
do {
    let r = Sim(contextInterval: 0).run(120) { $0.transport.reachable = false; return true }
    expect("still wedges the channel", r.wedged, "wedged=\(r.wedged)")
    expect("but self-heals (no stall)", r.maxStaleGap < stale, "max stale \(gap(r.maxStaleGap)) — re-activation clears it")
}

print("\n# 3. The fix: disciplined cadence, same context-only conditions")
do {
    let r = Sim(contextInterval: 5).run(120) { $0.transport.reachable = false; return true }
    expect("never wedges", !r.wedged, "wedged=\(r.wedged)")
    expect("stays fresh", r.maxStaleGap < stale, "max stale \(gap(r.maxStaleGap))")
}

print("\n# 4. Reachability flapping every ~7s")
do {
    let r = Sim(contextInterval: 5).run(150) { $0.transport.reachable = (Int($0.now / 7) % 2 == 0); return true }
    expect("never wedges", !r.wedged, "wedged=\(r.wedged)")
    expect("stays fresh", r.maxStaleGap < stale, "max stale \(gap(r.maxStaleGap))")
}

print("\n# 5. Reachability stuck false (watch screen-off bug): over-heal check")
do {
    let r = Sim(contextInterval: 5).run(150) { $0.transport.reachable = false; return true }
    expect("stays fresh via context", r.maxStaleGap < stale, "max stale \(gap(r.maxStaleGap))")
    expect("no false restarts", r.restarts == 0, "restarts=\(r.restarts)")
}

print("\n# 6. Transient sendMessage failures while reachable")
do {
    let r = Sim(contextInterval: 5).run(150) {
        $0.transport.reachable = true
        $0.transport.sendMessageWorks = (Int($0.now) % 13 >= 4)
        return true
    }
    expect("never wedges", !r.wedged, "wedged=\(r.wedged)")
    expect("stays fresh", r.maxStaleGap < stale, "max stale \(gap(r.maxStaleGap))")
}

print("\n# 7. Total channel blackout (30s) then recovery")
do {
    let s = Sim(contextInterval: 5)
    let r = s.run(180) {
        let black = $0.now >= 60 && $0.now < 90
        $0.transport.blackout = black
        return !black
    }
    expect("recovers, no permanent stall", r.maxStaleGap < stale, "max stale (capable windows) \(gap(r.maxStaleGap))")
    expect("fresh at end", s.receiver.isFresh(now: s.now), "fresh=\(s.receiver.isFresh(now: s.now))")
}

print("\n# 8. Bursty HR (samples every 0.3s)")
do {
    let s = Sim(contextInterval: 5)
    let r = s.run(120, hrInterval: 0.3)
    expect("never wedges (throttle holds)", !r.wedged, "wedged=\(r.wedged), contextCalls=\(s.transport.contextCalls)")
    expect("stays fresh", r.maxStaleGap < stale, "max stale \(gap(r.maxStaleGap))")
}

print("\n# 9. Chaos: reachability flap + transient send failures + periodic wedges, all at once")
do {
    let r = Sim(contextInterval: 5).run(200) { s in
        s.transport.reachable = (Int(s.now / 4) % 3 != 0)
        s.transport.sendMessageWorks = (Int(s.now / 3) % 4 != 0)
        return true
    }
    expect("stays fresh under combined chaos", r.maxStaleGap < stale, "max stale \(gap(r.maxStaleGap))")
}

print("\n# 10. HR capture stall (no samples for 30s)")
do {
    let s = Sim(contextInterval: 5)
    let r = s.run(150) { sim in sim.hrSuppressed = (sim.now >= 50 && sim.now < 80); return true }
    expect("detects capture stall + requests restart", r.restarts >= 1, "restarts=\(r.restarts)")
    expect("recovers when samples return", s.receiver.isFresh(now: s.now), "fresh=\(s.receiver.isFresh(now: s.now))")
}

print("\n# 11. Delayed activation (transport not activated until t=6s)")
do {
    let s = Sim(contextInterval: 5)
    s.transport.isActivated = false
    let r = s.run(120) { sim in if sim.now >= 6, !sim.transport.isActivated { sim.transport.activate() }; return sim.transport.isActivated }
    expect("recovers once activated", r.maxStaleGap < stale, "max stale (active windows) \(gap(r.maxStaleGap))")
}

// Tiny seeded PRNG for deterministic fuzzing.
struct LCG {
    var s: UInt64
    init(_ seed: UInt64) { s = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 { s = s &* 6364136223846793005 &+ 1442695040888963407; return s }
    mutating func unit() -> Double { Double(next() >> 11) * (1.0 / 9007199254740992.0) }
    mutating func chance(_ p: Double) -> Bool { unit() < p }
}

print("\n# 12. Fuzz: 300 randomized adversaries. Hunt for any permanent stall")
do {
    var stalls = 0, worst = 0.0
    for seed in 0..<300 {
        var rng = LCG(UInt64(seed))
        let s = Sim(contextInterval: 5)
        var blackoutUntil = -1.0
        let r = s.run(120) { sim in
            if rng.chance(0.12) { sim.transport.reachable.toggle() }
            sim.transport.sendMessageWorks = !rng.chance(0.25)
            if blackoutUntil < sim.now, rng.chance(0.008) { blackoutUntil = sim.now + 2 + rng.unit() * 8 }
            let black = sim.now < blackoutUntil
            sim.transport.blackout = black
            return !black
        }
        worst = max(worst, r.maxStaleGap)
        if r.maxStaleGap >= stale { stalls += 1 }
    }
    expect("no permanent stall in any of 300 random runs", stalls == 0, "\(stalls)/300 stalled; worst gap \(gap(worst))")
}

let failed = checks.filter { !$0.pass }
print("\n==== \(checks.count - failed.count)/\(checks.count) checks passed ====")
if !failed.isEmpty {
    print("FAILURES:")
    failed.forEach { print("  - \($0.name): \($0.detail)") }
    exit(1)
}
print("ALL GREEN: wrapper survives every injected failure mode")
