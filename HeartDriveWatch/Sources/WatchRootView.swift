import SwiftUI

struct WatchRootView: View {
    @State private var model = WatchModel.shared
    @State private var targetHR: Double = 140
    @State private var lastFromPhone = 140
    @State private var sendTask: Task<Void, Never>?
    @State private var lastCrownAt: Date?
    @State private var applyingRemoteTarget = false
    @FocusState private var crownFocused: Bool

    var body: some View {
        VStack(spacing: 8) {
            Spacer(minLength: 0)
            heartRate
            targets
            Spacer(minLength: 0)
            controlButton
            if let error = model.workout.lastError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The Digital Crown sets the target heart rate. `.focusable` must precede
        // `.digitalCrownRotation`, and there's no ScrollView competing for the crown.
        .focusable(true)
        .focused($crownFocused)
        .digitalCrownRotation(
            $targetHR, from: 90, through: 200, by: 1,
            sensitivity: .low, isContinuous: false, isHapticFeedbackEnabled: true
        )
        .onAppear {
            crownFocused = true
            if let target = model.connectivity.rideStatus?.targetHeartRate { applyTargetFromPhone(target) }
        }
        .onChange(of: targetHR) { _, newValue in
            // Ignore our own programmatic update from the phone; react only to real
            // crown turns.
            if applyingRemoteTarget {
                applyingRemoteTarget = false
                return
            }
            lastCrownAt = Date()
            // Debounce: send only the settled value, and never echo back a value
            // the phone just told us (which would loop).
            let bpm = Int(newValue.rounded())
            sendTask?.cancel()
            sendTask = Task {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled, bpm != lastFromPhone else { return }
                lastFromPhone = bpm
                model.setTargetHeartRate(bpm)
            }
        }
        .onChange(of: model.connectivity.rideStatus?.targetHeartRate) { _, newValue in
            if let newValue { applyTargetFromPhone(newValue) }
        }
    }

    private func applyTargetFromPhone(_ bpm: Int) {
        // Don't clobber an in-progress crown adjustment with a stale status echo.
        if let lastCrownAt, Date().timeIntervalSince(lastCrownAt) < 2 { return }
        lastFromPhone = bpm
        if Int(targetHR.rounded()) != bpm {
            applyingRemoteTarget = true
            targetHR = Double(bpm)
        }
    }

    private var heartRate: some View {
        VStack(spacing: 0) {
            Text(Display.int(model.workout.currentBPM))
                .font(.system(size: 70, weight: .bold, design: .rounded))
                .foregroundStyle(Color.heartRateZone(bpm: model.workout.currentBPM, target: Int(targetHR.rounded())))
                .monospacedDigit()
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .frame(maxWidth: .infinity)
            Text("BPM")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var targets: some View {
        HStack(spacing: 0) {
            metric(title: "Target", value: "\(Int(targetHR.rounded()))", unit: "bpm")
            if let watts = model.connectivity.rideStatus?.targetPowerWatts {
                metric(title: "Power", value: "\(watts)", unit: "W")
            }
        }
    }

    private func metric(title: String, value: String, unit: String) -> some View {
        VStack(spacing: 0) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
            Text(unit).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var controlButton: some View {
        Button {
            if model.isRunning { model.stop() } else { model.start() }
            crownFocused = true  // re-claim the crown; the tap moved focus to the button
        } label: {
            Text(model.isRunning ? "Stop" : "Start")
                .frame(maxWidth: .infinity)
        }
        .tint(model.isRunning ? .red : .green)
    }
}
