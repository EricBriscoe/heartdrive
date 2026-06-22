import SwiftUI

struct WatchRootView: View {
    @State private var model = WatchModel.shared

    var body: some View {
        VStack(spacing: 12) {
            Spacer(minLength: 0)
            VStack(spacing: 0) {
                Text(Display.int(model.currentBPM))
                    .font(.system(size: 76, weight: .bold, design: .rounded))
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
            Button {
                if model.isRunning { model.stop() } else { model.start() }
            } label: {
                Text(model.isRunning ? "Stop" : "Start")
                    .frame(maxWidth: .infinity)
            }
            .tint(model.isRunning ? .red : .green)
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
    }
}
