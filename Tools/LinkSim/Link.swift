import Foundation

/// Simulator I/O driver only. Timing, deduplication and recovery live in the
/// production HeartRateLink; freshness and smoothing live in HeartRateHub.
final class LinkDriver {
    var onRequestRestart: (() -> Void)?
    private let transport: FlakyTransport
    private var link = HeartRateLink()
    private let enableHealing: Bool

    init(transport: FlakyTransport, contextInterval: TimeInterval, enableHealing: Bool) {
        self.transport = transport
        self.link.contextInterval = contextInterval
        self.enableHealing = enableHealing
    }

    func record(_ hr: HeartRate, now: TimeInterval) {
        guard link.record(hr, now: now) else { return }
        send(now: now)
    }

    func reset() { link.reset() }

    func tick(now: TimeInterval) {
        send(now: now)
        guard enableHealing else { return }
        switch link.recover(now: now, reachable: transport.isReachable) {
        case .restart: onRequestRestart?()
        case .reactivate: transport.activate()
        case nil: break
        }
    }

    private func send(now: TimeInterval) {
        let send = link.send(now: now, activated: transport.isActivated,
                             reachable: transport.isReachable, hasRegisters: false)
        let generation = link.generation
        if let hr = send.live {
            transport.sendMessage(hr) { [weak self] deliveredAt in
                self?.link.delivered(now: deliveredAt, generation: generation)
            }
        }
        if send.context, let hr = link.latest { transport.updateContext(hr) }
    }
}
