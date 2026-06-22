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

    /// Fraction of the model-predicted power step applied as feedforward when seeding
    /// the operating point (on start and on target change). Under 1 deliberately
    /// undershoots, so we approach the target from below and let feedback finish despite the wide per-rider spread in bpm-per-watt.
    var feedforwardFraction: Double = 0.7

    var maxRampUpPerUpdate: Double { aggressiveness.rampUp }
    var maxRampDownPerUpdate: Double { aggressiveness.rampDown }

    // First-order-plus-dead-time plant model (Hunt et al. population nominals).
    var plantGain: Double = 0.39  // bpm per watt
    var plantTau: Double = 60  // seconds
    var deadTime: Double = 15  // seconds

    var lambda: Double { aggressiveness.lambda }
    var controllerGain: Double { (1.0 / plantGain) * plantTau / (lambda + deadTime) }  // W/bpm (Kc)
    var integralGain: Double { controllerGain / plantTau }  // W/(bpm·s) (Ki)
    var backCalcGain: Double { plantTau > 0 ? 1.0 / plantTau : 0 }  // 1/Tt ≈ 1/Ti
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
    // Feedforward state: whether the integrator has been seeded to the model operating
    // point yet, and the target it was last seeded for (so a setpoint change shifts it
    // by the delta rather than re-seeding from scratch).
    private var primed = false
    private var operatingTarget = 0.0
    private let settleDuration: TimeInterval = 180
    private let hrDropoutGrace: TimeInterval = 20
    private let validHRRange = 30.0...230.0

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
        primed = false
        operatingTarget = config.targetHeartRate
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
        let floor = Double(config.powerFloor)
        let ceiling = Double(max(config.powerFloor, config.powerCeiling))
        let step = config.feedforwardFraction * (config.targetHeartRate - operatingTarget) / config.plantGain
        integral = min(max(integral + step, floor), ceiling)
        operatingTarget = config.targetHeartRate
    }

    func update(filteredHR: Double?, isPedaling: Bool, dt: TimeInterval) -> ErgUpdate {
        guard running else { return ErgUpdate(targetPower: config.startingPower, state: .idle) }

        let floor = Double(config.powerFloor)
        let ceiling = Double(max(config.powerFloor, config.powerCeiling))
        settleRemaining = max(0, settleRemaining - dt)

        if !isPedaling {
            // A resting HR is not a response to power; freeze everything.
            return ErgUpdate(targetPower: Int(lastOutput.rounded()), state: .holdingNoCadence)
        }

        guard let hr = filteredHR, validHRRange.contains(hr) else {
            timeSinceValidHR += dt
            if timeSinceValidHR > hrDropoutGrace {
                // Beyond the grace period: bleed toward the floor rather than hold power blind.
                lastOutput = max(floor, lastOutput - config.maxRampDownPerUpdate)
            }
            return ErgUpdate(targetPower: Int(lastOutput.rounded()), state: .hrLost)
        }
        timeSinceValidHR = 0
        if !primed {
            // Seed the operating point from the plant model so we start near the power
            // that holds target instead of integrating up from startingPower.
            let step = config.feedforwardFraction * (config.targetHeartRate - hr) / config.plantGain
            integral = min(max(Double(config.startingPower) + step, floor), ceiling)
            operatingTarget = config.targetHeartRate
            primed = true
        }

        let rawError = config.targetHeartRate - hr
        let error = abs(rawError) <= config.deadbandBPM ? 0 : rawError

        // PI command before limiting; the integral carries the operating-point bias.
        let unclamped = config.controllerGain * error + integral
        let actuator = min(max(unclamped, floor), ceiling)
        // The applied command, after BOTH actuator (floor/ceiling) and slew
        // (ramp) limiting.
        let output = min(
            max(actuator, lastOutput - config.maxRampDownPerUpdate),
            lastOutput + config.maxRampUpPerUpdate)

        // Integrate with back-calculation against the applied output, so the
        // integral can't wind up against the floor/ceiling OR the slew limit. Tracking
        // the rate-limited output (not just the actuator clamp) is what stops a fast
        // ramp from overshooting and keeps the feedforward preload from over-winding.
        integral += (config.integralGain * error + config.backCalcGain * (output - unclamped)) * dt
        integral = min(max(integral, floor), ceiling)

        lastOutput = output

        let state: ErgControllerState
        if output >= ceiling && error > 0 {
            state = .atCeiling
        } else if output <= floor && error < 0 {
            state = .atFloor
        } else if settleRemaining > 0 {
            state = .settling
        } else {
            state = .tracking
        }
        return ErgUpdate(targetPower: Int(output.rounded()), state: state)
    }
}
