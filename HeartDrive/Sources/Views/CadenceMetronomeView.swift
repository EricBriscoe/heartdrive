import SwiftUI

/// A silent, visual cadence metronome: a dot sweeps left↔right along a bar at the
/// target RPM (each edge is a pedal stroke). Compact, no sound. Turns green when
/// your actual cadence is within a few rpm of the target.
struct CadenceMetronomeView: View {
    var model: AppModel

    private let dotSize: CGFloat = 26

    var body: some View {
        let target = model.settings.cadenceTarget
        let current = model.trainer.cadenceRPM
        let inSync = current.map { abs($0 - Double(target)) <= 3 } ?? false
        let accent: Color = inSync ? .green : .pink

        return VStack(spacing: 10) {
            HStack {
                Label("Cadence", systemImage: "metronome")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(current.map { "\(Int($0.rounded())) rpm" } ?? "— rpm")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(inSync ? .green : .secondary)
            }

            TimelineView(.animation) { timeline in
                GeometryReader { geo in
                    let period = 60.0 / Double(max(1, target))
                    let t = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period)
                    let phase = sin(2 * .pi * t / period)
                    let travel = (geo.size.width - dotSize) / 2
                    ZStack {
                        Capsule().fill(Color(uiColor: .tertiarySystemFill))
                        Circle()
                            .fill(accent)
                            .frame(width: dotSize, height: dotSize)
                            .offset(x: phase * travel)
                    }
                }
                .frame(height: dotSize)
            }

            HStack {
                stepButton(delta: -1)
                Spacer()
                VStack(spacing: 0) {
                    Text("\(target)")
                        .font(.title3.weight(.bold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text("target rpm").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                stepButton(delta: 1)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private func stepButton(delta: Int) -> some View {
        Button {
            model.adjustCadenceTarget(by: delta)
        } label: {
            Image(systemName: delta < 0 ? "minus" : "plus")
                .font(.headline)
                .frame(width: 40, height: 40)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .tint(.pink)
    }
}
