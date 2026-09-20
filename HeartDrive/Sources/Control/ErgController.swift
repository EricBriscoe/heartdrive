import Foundation

struct ErgControllerConfig: Equatable {
    var targetHeartRate: Double
    var powerFloor: Int
    var powerCeiling: Int
    var startingPower: Int
    let updateInterval: TimeInterval = 5
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

/// Zone-oriented step-and-wait control. No rider model or learned state.
/// The caller supplies elapsed time and only fresh HR/pedaling observations.
final class ErgController {
    var config: ErgControllerConfig
    private(set) var isRunning = false
    private var watts = 0
    private var warmupRemaining = 120.0
    private var sinceAdjustment = 0.0
    private var outsideFor = 0.0
    private var highFor = 0.0
    private var direction = 0
    private var hrMissingFor = 0.0
    private var notPedalingFor = 0.0

    init(config: ErgControllerConfig) { self.config = config }

    func start() {
        isRunning = true
        watts = config.startingPower
        warmupRemaining = 120
        hrMissingFor = 0
        notPedalingFor = 0
        markTargetChanged()
    }

    func stop() { isRunning = false }

    /// A target edit never jumps the watts or reuses evidence from the old target.
    func markTargetChanged() {
        sinceAdjustment = 0
        resetEvidence()
    }

    func update(filteredHR: Double?, isPedaling: Bool, dt: TimeInterval) -> ErgUpdate {
        guard isRunning else { return result(.idle) }
        // A delayed callback is not evidence of a sustained physiological state.
        let elapsed = dt.isFinite ? min(max(dt, 0), config.updateInterval) : 0
        let validHR = filteredHR.flatMap { $0.isFinite && (30...230).contains($0) ? $0 : nil }
        hrMissingFor = validHR == nil ? hrMissingFor + elapsed : 0
        notPedalingFor = isPedaling ? 0 : notPedalingFor + elapsed

        guard let hr = validHR, isPedaling else {
            markTargetChanged()
            // Hold a brief dropout/coast; then release gradually. No upward steps.
            if hrMissingFor >= 20 || notPedalingFor >= 8 {
                watts -= Int((10 * elapsed / config.updateInterval).rounded())
            }
            return result(validHR == nil ? .hrLost : .holdingNoCadence)
        }

        warmupRemaining = max(0, warmupRemaining - elapsed)
        sinceAdjustment += elapsed
        let error = hr - config.targetHeartRate
        let nextDirection = error > 3 ? -1 : (error < -3 ? 1 : 0)
        if nextDirection != direction {
            outsideFor = 0
            direction = nextDirection
        }
        outsideFor = direction == 0 ? 0 : outsideFor + elapsed
        highFor = error >= 10 ? highFor + elapsed : 0

        // Persistent large excess HR may shed power sooner, even during warm-up.
        if highFor >= 15 && sinceAdjustment >= 15 {
            watts -= 10
            markTargetChanged()
        } else if outsideFor >= 15 && sinceAdjustment >= 30 {
            if direction < 0 || warmupRemaining == 0 {
                watts += direction * 5
                markTargetChanged()
            }
        }
        let output = result(warmupRemaining > 0 ? .settling : .tracking)
        if error < -3 && output.targetPower == upperBound {
            return result(.atCeiling)
        }
        if error > 3 && output.targetPower == lowerBound {
            return result(.atFloor)
        }
        return output
    }

    private var lowerBound: Int { max(0, min(config.powerFloor, config.powerCeiling)) }
    private var upperBound: Int { max(0, config.powerCeiling) }

    /// Bounds apply LAST, on every path, including changed settings and dropout.
    private func result(_ state: ErgControllerState) -> ErgUpdate {
        watts = min(upperBound, max(lowerBound, watts))
        return ErgUpdate(targetPower: watts, state: state)
    }

    private func resetEvidence() {
        direction = 0
        outsideFor = 0
        highFor = 0
    }
}
