import SwiftUI

struct WatchRootView: View {
    @State private var model = WatchModel.shared
    @State private var targetHR: Double = 140
    @State private var crownWork: DispatchWorkItem?
    @FocusState private var crownFocused: Bool

    var body: some View {
        VStack(spacing: 8) {
            Spacer(minLength: 0)
            targetRow
            VStack(spacing: 0) {
                Text(Display.int(model.currentBPM))
                    .font(.system(size: 64, weight: .bold, design: .rounded))
                    .foregroundStyle(.pink)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                Text("BPM")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            controls
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
        .digitalCrownRotation($targetHR, from: 90, through: 200, by: 1, sensitivity: .low, isContinuous: false)
        .onChange(of: targetHR) { _, new in
            // Debounce a settled gesture into one synced edit. setTarget no-ops if the value
            // already matches the register, so a phone-synced value reflected back here (which
            // moves targetHR and re-triggers this) can't echo to the phone.
            let bpm = Int(new.rounded())
            crownWork?.cancel()
            let work = DispatchWorkItem { model.setTarget(bpm) }
            crownWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        }
        .onChange(of: model.target) { _, synced in
            if let synced, Int(targetHR.rounded()) != synced { targetHR = Double(synced) }
        }
        .onAppear {
            crownFocused = true
            if let t = model.target { targetHR = Double(t) }
        }
    }

    private var targetRow: some View {
        VStack(spacing: 0) {
            Text("\(Int(targetHR.rounded()))")
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .foregroundStyle(Color.heartRateZone(bpm: model.currentBPM, target: Int(targetHR.rounded())))
            Text("TARGET")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var controls: some View {
        if model.isRunning {
            Button { model.stop() } label: {
                Text("Stop").frame(maxWidth: .infinity)
            }
            .tint(.red)
        } else {
            Button { model.start() } label: {
                Text("Start").frame(maxWidth: .infinity)
            }
            .tint(.green)
        }
    }
}
