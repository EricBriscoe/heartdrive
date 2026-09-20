import Foundation
import Observation

/// Validated, lightly smoothed HR. Freshness requires a recent measurement,
/// not merely recent delivery of a buffered Watch message.
@Observable
final class HeartRateHub {
    private(set) var currentBPM: Double?
    private(set) var smoothedBPM: Double?
    private(set) var lastUpdate: Date?
    private(set) var source: String?

    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let filterTau = 5.0
    @ObservationIgnored private let staleAfter = 12.0
    @ObservationIgnored private var lastSampleTime: Date?

    init(now: @escaping () -> Date = Date.init) { self.now = now }

    var isFresh: Bool {
        guard let lastUpdate, let lastSampleTime else { return false }
        let date = now()
        return date.timeIntervalSince(lastUpdate) < staleAfter
            && (-2..<staleAfter).contains(date.timeIntervalSince(lastSampleTime))
    }

    var controlBPM: Double? { isFresh ? smoothedBPM : nil }

    func ingest(bpm: Double, sampleTime: Date, source: String) {
        let date = now()
        guard bpm.isFinite, (30...230).contains(bpm),
            (-2..<staleAfter).contains(date.timeIntervalSince(sampleTime))
        else { return }
        // Reject duplicates and reordering within a source. Source changes reset the
        // filter; stale high-water marks expire so a clock correction can recover.
        if self.source == source, let lastSampleTime,
            date.timeIntervalSince(lastSampleTime) < staleAfter,
            sampleTime <= lastSampleTime
        {
            return
        }

        if self.source == source, isFresh, let last = lastSampleTime, let previous = smoothedBPM {
            let alpha = 1 - exp(-max(0, sampleTime.timeIntervalSince(last)) / filterTau)
            smoothedBPM = previous + alpha * (bpm - previous)
        } else {
            smoothedBPM = bpm
        }
        currentBPM = bpm
        lastSampleTime = sampleTime
        lastUpdate = date
        self.source = source
    }

    func reset() {
        currentBPM = nil
        smoothedBPM = nil
        lastUpdate = nil
        lastSampleTime = nil
        source = nil
    }
}
