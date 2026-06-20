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

    /// Closed-loop time constant (seconds). Defaults center on 3·tau ≈ 180s.
    var lambda: Double {
        switch self {
        case .gentle: return 240
        case .balanced: return 180
        case .responsive: return 120
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
    var maxRampUpPerUpdate: Double = 5
    var maxRampDownPerUpdate: Double = 10

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
    }

    func stop() {
        running = false
    }

    /// Restart the settling indicator after a meaningful setpoint or tuning change.
    func markTargetChanged() {
        if running { settleRemaining = settleDuration }
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

        let rawError = config.targetHeartRate - hr
        let error = abs(rawError) <= config.deadbandBPM ? 0 : rawError

        // PI command before any limiting.
        let unclamped = config.controllerGain * error + integral
        // Actuator saturation is floor/ceiling only, never the ramp limiter.
        let actuator = min(max(unclamped, floor), ceiling)

        // Conditional integration: stop accumulating only when pinned at an
        // actuator limit and the error pushes further into it.
        let saturatedHigh = actuator >= ceiling && error > 0
        let saturatedLow = actuator <= floor && error < 0
        if !saturatedHigh && !saturatedLow {
            integral += config.integralGain * error * dt
        }
        // Back-calculation against actuator saturation only, then bound the
        // integral (the power operating point) to the usable range.
        integral += config.backCalcGain * (actuator - unclamped) * dt
        integral = min(max(integral, floor), ceiling)

        // Ramp limiting is pure output shaping and never feeds the integral.
        let output = min(
            max(actuator, lastOutput - config.maxRampDownPerUpdate),
            lastOutput + config.maxRampUpPerUpdate)
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
