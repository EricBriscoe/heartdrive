import Foundation
import os

/// Diagnostic CSV logger for the HR→power control loop. Writes one file per ride session into the
/// app's Documents directory (pullable over Finder/Files with file sharing enabled), one row per
/// 5 s tick. Its whole purpose is to answer one question the FIT/Zwift data cannot: does the
/// *commanded* power the controller asks for actually match the *delivered* power the trainer
/// reports (i.e. is ERG holding) and what is the control state when it diverges.
///
/// Deliberately lightweight: a single open FileHandle, ~200 bytes/tick on the main run loop, no
/// dependencies. Remove the call sites in AppModel once the ERG-hold question is settled.
final class ControlLogger {
    private static let log = Logger(subsystem: "com.ericbriscoe.HeartDrive", category: "control")
    /// Keep only the most recent sessions so diagnostic logs can't accumulate without bound.
    private static let maxFiles = 20
    private static let header =
        "time,elapsed_s,target_hr,control_hr,commanded_w,delivered_w,cadence,dt,state,"
        + "control_ready,is_ready,conflict,mode\n"

    private var handle: FileHandle?
    private var startedAt: Date?
    private var fileName: String?

    private let timestamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    var isLogging: Bool { handle != nil }

    /// Open a fresh CSV for a new ride session. No-ops (logging just stays off) if the file can't
    /// be created, so a logging failure can never take down a ride.
    func start(at now: Date = Date()) {
        stop()
        guard let dir = try? FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        else {
            Self.log.error("control: no Documents dir; logging disabled")
            return
        }
        Self.pruneOldLogs(in: dir)
        let name = "control-\(Self.fileStamp(now)).csv"
        let url = dir.appendingPathComponent(name)
        do {
            try Data(Self.header.utf8).write(to: url)
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            self.handle = handle
            self.startedAt = now
            self.fileName = name
            Self.log.info("control: logging to \(name, privacy: .public)")
        } catch {
            Self.log.error("control: open failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Append one tick. `commandedW` is what the controller asked the trainer to hold;
    /// `deliveredW` is the trainer's reported instantaneous power.
    func log(
        now: Date = Date(), targetHR: Int, controlHR: Double?, commandedW: Int, deliveredW: Int?,
        cadence: Double?, dt: TimeInterval, state: ErgControllerState, controlReady: Bool,
        isReady: Bool, conflict: Bool, mode: String?
    ) {
        guard let handle, let startedAt else { return }
        let row = [
            timestamp.string(from: now),
            String(format: "%.1f", now.timeIntervalSince(startedAt)),
            String(targetHR),
            controlHR.map { String(format: "%.1f", $0) } ?? "",
            String(commandedW),
            deliveredW.map(String.init) ?? "",
            cadence.map { String(format: "%.0f", $0) } ?? "",
            String(format: "%.1f", dt),
            String(describing: state),
            controlReady ? "1" : "0",
            isReady ? "1" : "0",
            conflict ? "1" : "0",
            mode ?? "",
        ].joined(separator: ",") + "\n"
        do { try handle.write(contentsOf: Data(row.utf8)) }
        catch { Self.log.error("control: write failed: \(error.localizedDescription, privacy: .public)") }

        // Surface a divergence live in Console so the failure mode is visible mid-ride without
        // pulling the file: under working ERG, delivered should track commanded within a few watts.
        if let deliveredW, isReady, abs(deliveredW - commandedW) > 25 {
            Self.log.notice(
                "control: ERG diverge cmd=\(commandedW)W dev=\(deliveredW)W Δ=\(deliveredW - commandedW)W ready=\(controlReady ? 1 : 0) conflict=\(conflict ? 1 : 0)")
        }
    }

    func stop() {
        guard let handle else { return }
        try? handle.close()
        self.handle = nil
        if let fileName { Self.log.info("control: closed \(fileName, privacy: .public)") }
        startedAt = nil
        fileName = nil
    }

    private static func fileStamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: date)
    }

    /// Delete the oldest `control-*.csv` files so at most `maxFiles` remain after the new session
    /// opens. The yyyyMMdd-HHmmss name sorts lexically = chronologically. Only ever touches our
    /// own diagnostic files.
    private static func pruneOldLogs(in dir: URL) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter({ $0.lastPathComponent.hasPrefix("control-") && $0.pathExtension == "csv" })
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        else { return }
        let excess = files.count - (maxFiles - 1)  // leave room for the file about to be created
        guard excess > 0 else { return }
        for url in files.prefix(excess) { try? fm.removeItem(at: url) }
    }
}
