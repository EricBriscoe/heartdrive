import Foundation
import Observation

/// Single source of truth for the rider's heart rate on the phone. Holds the raw
/// latest value plus an EWMA-smoothed value (the control loop consumes the
/// smoothed one) and tracks freshness so dropouts and stuck sensors are detected.
@Observable
final class HeartRateHub {
    private(set) var currentBPM: Double?
    private(set) var smoothedBPM: Double?
    private(set) var lastUpdate: Date?
    private(set) var source: String?

    @ObservationIgnored var filterTau: Double = 12
    @ObservationIgnored var staleAfter: TimeInterval = 12
    @ObservationIgnored private var lastSampleTime: Date?
    @ObservationIgnored private var unchangedSince: Date?
    @ObservationIgnored private let stuckTimeout: TimeInterval = 30

    var isFresh: Bool {
        guard let lastUpdate else { return false }
        if let unchangedSince, Date().timeIntervalSince(unchangedSince) > stuckTimeout { return false }
        return Date().timeIntervalSince(lastUpdate) < staleAfter
    }

    /// The value the controller should use, or nil when stale/stuck/absent.
    var controlBPM: Double? { isFresh ? smoothedBPM : nil }

    func ingest(_ sample: HeartRateSample, source: String) {
        ingest(bpm: sample.bpm, sampleTime: sample.timestamp, source: source)
    }

    func ingest(bpm: Double, sampleTime: Date, source: String) {
        // Drop duplicates / out-of-order samples (a queued transfer can arrive
        // after a newer live message and would otherwise corrupt the EWMA).
        if let lastSampleTime, sampleTime <= lastSampleTime { return }

        let now = Date()
        if let last = lastUpdate, let previous = smoothedBPM {
            let dt = max(0.1, now.timeIntervalSince(last))
            let alpha = 1 - exp(-dt / filterTau)
            smoothedBPM = previous + alpha * (bpm - previous)
        } else {
            smoothedBPM = bpm
        }

        if currentBPM == bpm {
            if unchangedSince == nil { unchangedSince = now }
        } else {
            unchangedSince = nil
        }

        currentBPM = bpm
        lastSampleTime = sampleTime
        lastUpdate = now
        self.source = source
    }

    func reset() {
        currentBPM = nil
        smoothedBPM = nil
        lastUpdate = nil
        lastSampleTime = nil
        unchangedSince = nil
        source = nil
    }
}
