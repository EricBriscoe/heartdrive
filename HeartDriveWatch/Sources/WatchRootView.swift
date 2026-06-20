import SwiftUI

struct WatchRootView: View {
    @State private var model = WatchModel.shared

    var body: some View {
        // ScrollView whose content fills the frame: it looks fixed and won't
        // scroll while everything fits, but can't clip content (3-digit HR, an
        // error line, smaller watches) the way a bare VStack would.
        ScrollView {
            VStack(spacing: 8) {
                Spacer(minLength: 0)
                heartRate
                if let status = model.connectivity.rideStatus {
                    targets(status)
                }
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
            .frame(maxWidth: .infinity)
            .containerRelativeFrame(.vertical)
        }
        .padding(.horizontal, 4)
    }

    private var heartRate: some View {
        VStack(spacing: 0) {
            Text(Display.int(model.workout.currentBPM))
                .font(.system(size: 70, weight: .bold, design: .rounded))
                .foregroundStyle(.red)
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

    private func targets(_ status: RideStatus) -> some View {
        HStack(spacing: 0) {
            metric(title: "Target", value: "\(status.targetHeartRate)", unit: "bpm")
            if let watts = status.targetPowerWatts {
                metric(title: "Power", value: "\(watts)", unit: "W")
            }
        }
    }

    private func metric(title: String, value: String, unit: String) -> some View {
        VStack(spacing: 0) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold))
            Text(unit).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var controlButton: some View {
        Button {
            if model.isRunning { model.stop() } else { model.start() }
        } label: {
            Text(model.isRunning ? "Stop" : "Start")
                .frame(maxWidth: .infinity)
        }
        .tint(model.isRunning ? .red : .green)
    }
}
