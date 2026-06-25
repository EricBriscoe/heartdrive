import Foundation

/// How aggressively the loop chases the target. Maps to the closed-loop time
/// constant lambda: larger lambda makes the response slower and less sensitive to model error.
enum ControlAggressiveness: String, CaseIterable, Codable, Identifiable {
    case gentle
    case balanced
    case responsive

    var id: String { rawValue }

    var label: String {
        switch self {
        case .gentle: return "Gentle"
        case .balanced: return "Balanced"
        case .responsive: return "Responsive"
        }
    }

    /// Closed-loop time constant (seconds). The plant's open-loop tau is ~60s and the
    /// dead time ~15s, so these (2τ / τ / 0.5τ) stay well inside the robustness floor
    /// (λ ≥ ~15s, phase margin ≥ 71°) while being far snappier than the old 2–4τ.
    var lambda: Double {
        switch self {
        case .gentle: return 120
        case .balanced: return 60
        case .responsive: return 30
        }
    }

    /// Per-update actuator slew limits (watts per 5s update). The old +5W up-ramp
    /// capped the climb at +1W/s and was the dominant cause of slow resistance build;
    /// these let the controller move. Down stays a touch faster than up so
    /// the loop sheds power promptly on overshoot or cardiac drift.
    var rampUp: Double {
        switch self {
        case .gentle: return 10
        case .balanced: return 15
        case .responsive: return 20
        }
    }

    var rampDown: Double {
        switch self {
        case .gentle: return 15
        case .balanced: return 20
        case .responsive: return 25
        }
    }
}

struct ErgControllerConfig: Equatable {
    var targetHeartRate: Double
    var powerFloor: Int
    var powerCeiling: Int
    var startingPower: Int
    var aggressiveness: ControlAggressiveness = .balanced

    var deadbandBPM: Double = 2.5
    var updateInterval: TimeInterval = 5

    /// Cold-start feedforward fraction: the share of the model-predicted power step used to
    /// seed the operating point before a per-rider holding power has been learned this
    /// session. Under 1 deliberately undershoots, so we approach from below and let feedback
    /// finish. Once a holding point is learned, the seed lands on it directly (see
    /// ErgController.learnedHoldingPower).
    var feedforwardFraction: Double = 0.7

    var maxRampUpPerUpdate: Double { aggressiveness.rampUp }
    var maxRampDownPerUpdate: Double { aggressiveness.rampDown }

    // First-order-plus-dead-time plant model (Hunt et al. population nominals). These are
    // the *priors*: plantGain in particular is refined per-rider at runtime, since the
    // real bpm-per-watt spans 2–4× across riders (see ErgController.effectivePlantGain).
    var plantGain: Double = 0.39  // bpm per watt
    var plantTau: Double = 60  // seconds
    var deadTime: Double = 15  // seconds

    var lambda: Double { aggressiveness.lambda }
}

enum ErgControllerState: Equatable {
    case idle
    case settling
    case tracking
    case holdingNoCadence
    case hrLost
    case atCeiling
    case atFloor
}

struct ErgUpdate: Equatable {
    var targetPower: Int
    var state: ErgControllerState
}

/// Slow, integral-dominant PI controller (no derivative) that converts heart-rate
/// error into an ERG target-power command. Pure and self-contained: the caller
/// drives it on a fixed cadence and applies the returned watts to the trainer.
final class ErgController {
    var config: ErgControllerConfig

    private var running = false
    private var integral = 0.0
    private var lastOutput = 0.0
    private var settleRemaining = 0.0
    private var timeSinceValidHR = 0.0
    private var timeSinceCadence = 0.0
    // Feedforward state: whether the integrator has been seeded to the model operating
    // point yet, and the target it was last seeded for (so a setpoint change shifts it
    // by the delta rather than re-seeding from scratch).
    private var primed = false
    private var operatingTarget = 0.0

    // Per-rider plant-gain estimate (bpm/W), learned from the HR response to the power
    // moves the loop itself makes. nil until the first usable episode completes; until
    // then the population prior (config.plantGain) is used. Reset each control session.
    private var plantGainEstimate: Double?
    // Gain-estimation episode: a span from a setpoint change (or start) until HR first
    // resettles into the target band. ΔHR/ΔP across that span is a steady-state gain
    // sample. Armed on start/target-change, captured on the next valid-HR tick, and
    // abandoned if cadence or HR drops mid-span (which would corrupt the deltas).
    private var episodeArmed = false
    private var episodeActive = false
    private var episodeStartPower = 0.0
    private var episodeStartHR = 0.0
    private var episodeElapsed = 0.0

    // #2 reference shaping: P and I act on this ramped setpoint, not the raw target, so a
    // start or target step never kicks the command. Anchored to the current HR at prime and
    // ramped toward the target with time constant setpointTau.
    private var internalSetpoint = 0.0
    private let setpointTau: TimeInterval = 25

    // #3 conditional integration: hold the integrator for one dead-time window after a move
    // so it can't wind up before HR responds (the dominant overshoot path; back-calculation
    // only catches floor/ceiling/slew clamping, not free-running dead-time wind-up).
    private var integralFreezeRemaining = 0.0

    // #1 learned steady-state operating point: the applied power observed while settled at a
    // given HR. Seeds the integrator on start/target-change so the PI only trims a few watts
    // instead of integrating a large bias across the dead time. EWMA, reset each session.
    private var learnedHoldPower: Double?
    private var learnedHoldHR: Double?
    private let holdLearnRate = 0.05

    private let settleDuration: TimeInterval = 180
    private let hrDropoutGrace: TimeInterval = 20
    // Hold resistance through a brief coast, then release to the floor on a sustained
    // stop. Long enough to ride out a soft-pedal over a crest without dumping resistance
    // (and snapping it back on resume); short enough to release promptly on a real stop.
    private let noCadenceGrace: TimeInterval = 8
    private let validHRRange = 30.0...230.0

    // Adaptive-gain guards (deliberately conservative; verify on-device before widening).
    // Bounds on how far the learned gain may move the controller gain Kc from nominal.
    // Amplification is capped tighter than detuning because too-high Kc is the unsafe
    // direction: it erodes phase margin and can make the resistance hunt.
    private let maxGainMultiplier = 1.4  // Kc ≤ 1.4× nominal (HR-insensitive rider)
    private let minGainMultiplier = 0.45  // Kc ≥ 0.45× nominal (HR-sensitive rider)
    private let gainAdaptRate = 0.35  // EWMA weight applied to each accepted sample
    private let minEpisodePower = 15.0  // W of power span required for a usable sample
    private let minEpisodeHR = 5.0  // bpm of HR span required
    private let minEpisodeTime: TimeInterval = 20  // min span before an episode may close
    private let maxEpisodeTime: TimeInterval = 240  // give up on an episode that never settles

    init(config: ErgControllerConfig) {
        self.config = config
    }

    var isRunning: Bool { running }

    func start() {
        running = true
        integral = Double(config.startingPower)
        lastOutput = Double(config.startingPower)
        settleRemaining = settleDuration
        timeSinceValidHR = 0
        timeSinceCadence = 0
        primed = false
        operatingTarget = config.targetHeartRate
        plantGainEstimate = nil
        episodeArmed = false
        episodeActive = false
        internalSetpoint = config.targetHeartRate
        integralFreezeRemaining = 0
        learnedHoldPower = nil
        learnedHoldHR = nil
    }

    func stop() {
        running = false
    }

    /// Restart the settling indicator and, on a setpoint change, shift the operating
    /// point by the model-predicted feedforward step so resistance moves immediately
    /// instead of waiting for the integral to wind up. Preloading the integrator
    /// (not adding a separate term) keeps it from double-counting the bias.
    func markTargetChanged() {
        if running { settleRemaining = settleDuration }
        guard primed else { return }
        let delta = config.targetHeartRate - operatingTarget
        guard delta != 0 else { return }
        let floor = Double(config.powerFloor)
        let ceiling = Double(max(config.powerFloor, config.powerCeiling))
        // Re-seed the integrator to the holding power for the new target: the learned
        // operating point when we have one, else a damped model step from the old point.
        if let hold = learnedHoldingPower(for: config.targetHeartRate) {
            integral = min(max(hold, floor), ceiling)
        } else {
            integral = min(max(integral + config.feedforwardFraction * delta / effectivePlantGain(), floor), ceiling)
        }
        operatingTarget = config.targetHeartRate
        episodeArmed = true  // re-estimate the rider's gain across the move to the new target
        integralFreezeRemaining = config.deadTime  // ride out the dead time before integrating
    }

    func update(filteredHR: Double?, isPedaling: Bool, dt: TimeInterval) -> ErgUpdate {
        guard running else { return ErgUpdate(targetPower: config.startingPower, state: .idle) }

        let floor = Double(config.powerFloor)
        let ceiling = Double(max(config.powerFloor, config.powerCeiling))
        settleRemaining = max(0, settleRemaining - dt)

        // Slew is a rate, so scale the per-update caps by the *actual* elapsed time. A
        // late or coalesced tick then moves proportionally instead of being silently
        // throttled to a single nominal step.
        let slewScale = config.updateInterval > 0 ? dt / config.updateInterval : 1
        let rampUp = config.maxRampUpPerUpdate * slewScale
        let rampDown = config.maxRampDownPerUpdate * slewScale

        if !isPedaling {
            // A resting HR is not a response to power. Hold the current resistance
            // through a brief coast, then release to the floor on a sustained stop,
            // both preventing the ERG "spiral of death" and ensuring that resuming ramps
            // up from the floor instead of snapping back to the pre-stop wattage at once.
            timeSinceCadence += dt
            abandonGainEpisode()
            if timeSinceCadence <= noCadenceGrace {
                return ErgUpdate(targetPower: Int(lastOutput.rounded()), state: .holdingNoCadence)
            }
            lastOutput = floor
            return ErgUpdate(targetPower: Int(floor), state: .holdingNoCadence)
        }
        timeSinceCadence = 0

        guard let hr = filteredHR, validHRRange.contains(hr) else {
            timeSinceValidHR += dt
            abandonGainEpisode()
            if timeSinceValidHR > hrDropoutGrace {
                // Beyond the grace period: bleed toward the floor rather than hold power blind.
                lastOutput = max(floor, lastOutput - rampDown)
            }
            return ErgUpdate(targetPower: Int(lastOutput.rounded()), state: .hrLost)
        }
        timeSinceValidHR = 0

        let (kc, ki, backCalc) = gains()

        if !primed {
            // Seed the integrator to the steady-state holding power so we start near the
            // power that holds target instead of integrating up across the dead time: the
            // learned operating point if we have one this session, else a damped model step
            // from the current HR.
            let seed = learnedHoldingPower(for: config.targetHeartRate)
                ?? (Double(config.startingPower)
                    + config.feedforwardFraction * (config.targetHeartRate - hr) / effectivePlantGain())
            integral = min(max(seed, floor), ceiling)
            operatingTarget = config.targetHeartRate
            internalSetpoint = hr  // start the shaped setpoint at the current HR (no kick)
            integralFreezeRemaining = config.deadTime
            primed = true
            episodeArmed = true
        }

        if episodeArmed {
            episodeStartPower = lastOutput
            episodeStartHR = hr
            episodeElapsed = 0
            episodeActive = true
            episodeArmed = false
        }

        // #2: ramp the shaped setpoint toward the target (first-order, ~setpointTau), and
        // #3: bleed down the post-move dead-time integral freeze.
        internalSetpoint += (config.targetHeartRate - internalSetpoint) * (1 - exp(-dt / setpointTau))
        integralFreezeRemaining = max(0, integralFreezeRemaining - dt)

        let trueError = config.targetHeartRate - hr
        let shapedError = internalSetpoint - hr
        // P and I act on the shaped (ramped) setpoint so a start or target step doesn't kick
        // the command; the deadband references the shaped error.
        let error = abs(shapedError) <= config.deadbandBPM ? 0 : shapedError

        // PI command before limiting; the integral carries the operating-point bias.
        let unclamped = kc * error + integral
        let actuator = min(max(unclamped, floor), ceiling)
        // The applied command, after BOTH actuator (floor/ceiling) and slew
        // (ramp) limiting.
        let output = min(
            max(actuator, lastOutput - rampDown),
            lastOutput + rampUp)

        // Integrate with back-calculation against the applied output, so the integral
        // can't wind up against the floor/ceiling OR the slew limit, except during the
        // post-move dead-time window, where it's frozen entirely so it can't accumulate
        // before HR has had a chance to respond (the dominant overshoot path).
        if integralFreezeRemaining <= 0 {
            integral += (ki * error + backCalc * (output - unclamped)) * dt
            integral = min(max(integral, floor), ceiling)
        }

        lastOutput = output

        updateGainEstimate(rawError: trueError, hr: hr, dt: dt)
        learnHoldingPoint(trueError: trueError, hr: hr)

        let state: ErgControllerState
        if output >= ceiling && trueError > config.deadbandBPM {
            state = .atCeiling
        } else if output <= floor && trueError < -config.deadbandBPM {
            state = .atFloor
        } else if settleRemaining > 0 {
            state = .settling
        } else {
            state = .tracking
        }
        return ErgUpdate(targetPower: Int(output.rounded()), state: state)
    }

    /// Effective plant gain (bpm/W): the learned per-rider value when available, else the
    /// population prior, clamped so the resulting controller gain stays within a safe
    /// band around nominal.
    private func effectivePlantGain() -> Double {
        let nominal = config.plantGain
        let estimate = plantGainEstimate ?? nominal
        // Kc ∝ 1/plantGain, so a *smaller* gain raises Kc. Clamp the gain itself:
        let lower = nominal / maxGainMultiplier  // floor on gain → ceiling on Kc
        let upper = nominal / minGainMultiplier  // ceiling on gain → floor on Kc
        return min(max(estimate, lower), upper)
    }

    /// SIMC/lambda PI gains for the current aggressiveness and effective plant gain.
    private func gains() -> (kc: Double, ki: Double, backCalc: Double) {
        let kp = effectivePlantGain()
        let kc = (1.0 / kp) * config.plantTau / (config.lambda + config.deadTime)  // W/bpm
        let ki = kc / config.plantTau  // W/(bpm·s); integral time Ti = plantTau
        let backCalc = config.plantTau > 0 ? 1.0 / config.plantTau : 0  // 1/Tt ≈ 1/Ti
        return (kc, ki, backCalc)
    }

    private func abandonGainEpisode() {
        episodeArmed = false
        episodeActive = false
    }

    /// Close the in-progress estimation episode the first time HR resettles into the
    /// target band after a real power move, and fold ΔHR/ΔP into the gain estimate.
    private func updateGainEstimate(rawError: Double, hr: Double, dt: TimeInterval) {
        guard episodeActive else { return }
        episodeElapsed += dt
        let settled = abs(rawError) <= config.deadbandBPM && episodeElapsed >= minEpisodeTime
        guard settled else {
            if episodeElapsed > maxEpisodeTime { episodeActive = false }  // never settled; discard
            return
        }
        episodeActive = false
        let dP = lastOutput - episodeStartPower
        let dHR = hr - episodeStartHR
        // Need genuine excitation in both signals, moving the same way, for a clean
        // steady-state slope. (Cardiac drift only inflates dHR → a higher gain estimate
        // → lower Kc → the safe direction, so it needs no special case.)
        guard abs(dP) >= minEpisodePower, abs(dHR) >= minEpisodeHR, dP * dHR > 0 else { return }
        let sample = min(max(dHR / dP, 0.1), 1.2)  // bpm/W, clamped to a plausible range
        if let estimate = plantGainEstimate {
            plantGainEstimate = estimate + gainAdaptRate * (sample - estimate)
        } else {
            plantGainEstimate = sample
        }
    }

    /// Holding power for `target` extrapolated from the learned operating point by the
    /// per-rider slope; nil until an operating point has been learned this session.
    private func learnedHoldingPower(for target: Double) -> Double? {
        guard let hp = learnedHoldPower, let hhr = learnedHoldHR else { return nil }
        return hp + (target - hhr) / effectivePlantGain()
    }

    /// While HR is settled at the true target and the shaped setpoint has caught up (past the
    /// dead-time freeze), EWMA the applied power and HR as the steady-state operating point.
    /// Cardiac drift slowly lowers the holding power over a long ride; the EWMA tracks it.
    private func learnHoldingPoint(trueError: Double, hr: Double) {
        guard abs(trueError) <= config.deadbandBPM,
            abs(config.targetHeartRate - internalSetpoint) <= config.deadbandBPM,
            integralFreezeRemaining <= 0
        else { return }
        if let hp = learnedHoldPower, let hhr = learnedHoldHR {
            learnedHoldPower = hp + holdLearnRate * (lastOutput - hp)
            learnedHoldHR = hhr + holdLearnRate * (hr - hhr)
        } else {
            learnedHoldPower = lastOutput
            learnedHoldHR = hr
        }
    }
}
