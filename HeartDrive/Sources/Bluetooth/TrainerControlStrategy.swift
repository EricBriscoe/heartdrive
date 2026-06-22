import Foundation

/// Abstracts the two ways a Wahoo trainer accepts ERG target-power commands:
/// standard FTMS and the Wahoo proprietary characteristic. The manager selects
/// a strategy based on which control characteristic the trainer exposes.
protocol ErgControlStrategy {
    var displayName: String { get }
    /// FTMS acknowledges every command via indications and must be subscribed
    /// before any write; the Wahoo characteristic does not.
    var needsIndications: Bool { get }
    /// One-time commands sent once the control characteristic is ready
    /// (FTMS Request Control / Wahoo unlock).
    func prepareCommands() -> [Data]
    func setTargetPowerCommand(watts: Int) -> Data
}

struct FTMSErgStrategy: ErgControlStrategy {
    let displayName = "FTMS"
    let needsIndications = true
    func prepareCommands() -> [Data] { [FTMSControlPoint.requestControl] }
    func setTargetPowerCommand(watts: Int) -> Data { FTMSControlPoint.setTargetPower(watts: watts) }
}

struct WahooErgStrategy: ErgControlStrategy {
    let displayName = "Wahoo"
    let needsIndications = false
    func prepareCommands() -> [Data] { [WahooTrainer.unlock] }
    func setTargetPowerCommand(watts: Int) -> Data { WahooTrainer.setErgPower(watts: watts) }
}
