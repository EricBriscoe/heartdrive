import SwiftUI

struct RideDashboardView: View {
    var model: AppModel
    @Binding var showConnect: Bool
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                conflictBanner
                HStack {
                    trainerBadge
                    Spacer()
                    heartRateBadge
                }
                heartRateHero
                targetAdjuster
                powerRow
                minorRow
                if model.settings.showCadenceGuide {
                    CadenceMetronomeView(model: model)
                }
                stateBanner
                controlButton
                broadcastRow
                cadenceGuideToggle
            }
            .padding()
            .animation(.default, value: model.trainer.controlConflict)
        }
    }

    @ViewBuilder private var conflictBanner: some View {
        if model.trainer.controlConflict {
            Label(
                "Another app is controlling the trainer. In Zwift, pair the KICKR as Power + Cadence only and leave Controllable empty.",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.red, in: RoundedRectangle(cornerRadius: 12))
            .phaseAnimator([1.0, 0.5]) { view, opacity in
                view.opacity(opacity)
            } animation: { _ in
                .easeInOut(duration: 0.7)
            }
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private var heartRateHero: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let link = model.watchLink
            let bpm = model.heart.currentBPM
            let target = model.settings.targetHeartRate
            let inBand = bpm.map { abs($0 - Double(target)) <= 3 } ?? false
            VStack(spacing: 4) {
                Text(Display.int(link == .idle ? nil : bpm))
                    .font(.system(size: 86, weight: .bold, design: .rounded))
                    .foregroundStyle(link.heroColor(inBand: inBand))
                    .contentTransition(.numericText())
                Text("BPM · target \(target)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
    }

    private var targetAdjuster: some View {
        HStack(spacing: 20) {
            adjustButton(systemImage: "minus", delta: -1)
            VStack(spacing: 0) {
                Text("\(model.settings.targetHeartRate)")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("target bpm").font(.caption2).foregroundStyle(.secondary)
            }
            .frame(minWidth: 88)
            adjustButton(systemImage: "plus", delta: 1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private func adjustButton(systemImage: String, delta: Int) -> some View {
        Button {
            model.adjustTargetHeartRate(by: delta)
        } label: {
            Image(systemName: systemImage)
                .font(.title2.weight(.bold))
                .frame(width: 54, height: 54)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .tint(.pink)
    }

    private var powerRow: some View {
        HStack(spacing: 12) {
            MetricCard(title: "Trainer power", systemImage: "bolt.fill") {
                valueUnit(Display.int(model.trainer.powerWatts), "W")
            }
            MetricCard(title: "Target power", systemImage: "target") {
                valueUnit(Display.int(model.targetPower), "W")
            }
        }
    }

    private var minorRow: some View {
        HStack(spacing: 12) {
            MetricCard(title: "Cadence", systemImage: "arrow.clockwise") {
                valueUnit(Display.int(model.trainer.cadenceRPM), "rpm")
            }
            MetricCard(title: "Speed", systemImage: "speedometer") {
                valueUnit(Display.decimal(model.trainer.speedKPH, 1), "km/h")
            }
        }
    }

    private func valueUnit(_ value: String, _ unit: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(value).font(.title2.bold())
            Text(unit).font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var stateBanner: some View {
        if model.isControlling {
            let state = model.controllerState
            Label(state.label, systemImage: state.systemImage)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(state.color)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(state.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        } else if let message = model.trainer.statusMessage {
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private var controlButton: some View {
        if model.isControlling {
            Button {
                model.stopControl()
            } label: {
                Text("Stop")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
        } else if model.trainer.isReady {
            Button {
                model.startControl()
            } label: {
                Text("Start heart-rate control")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(.accentColor)
        } else {
            Button {
                showConnect = true
            } label: {
                Label("Connect trainer", systemImage: "antenna.radiowaves.left.and.right")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var broadcastRow: some View {
        Toggle(isOn: Binding(get: { model.settings.broadcastToZwift }, set: { model.setBroadcasting($0) })) {
            HStack(spacing: 10) {
                Image(systemName: "dot.radiowaves.up.forward")
                    .foregroundStyle(model.broadcaster.state == .connected ? .green : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Broadcast HR to Zwift").font(.subheadline.weight(.medium))
                    Text(broadcastStatusText).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private var broadcastStatusText: String {
        switch model.broadcaster.state {
        case .off: return "Pair “HeartDrive” as a Heart Rate sensor in Zwift"
        case .advertising: return "Advertising: waiting for Zwift to connect"
        case .connected: return "Connected to Zwift"
        }
    }

    private var cadenceGuideToggle: some View {
        Toggle(isOn: Binding(get: { model.settings.showCadenceGuide }, set: { model.setCadenceGuide($0) })) {
            Label("Cadence guide", systemImage: "metronome")
                .font(.subheadline.weight(.medium))
        }
        .padding(12)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private var trainerBadge: StatusBadge {
        let trainer = model.trainer
        if trainer.isReady {
            return StatusBadge(
                text: trainer.controlModeName.map { "Trainer · \($0)" } ?? "Trainer ready",
                systemImage: "bolt.horizontal.circle.fill", color: .green)
        }
        switch trainer.connectionState {
        case .connected:
            return StatusBadge(text: "Preparing control…", systemImage: "bolt.horizontal.circle", color: .orange)
        case .connecting: return StatusBadge(text: "Connecting…", systemImage: "bolt.horizontal", color: .orange)
        case .scanning: return StatusBadge(text: "Scanning…", systemImage: "dot.radiowaves.right", color: .orange)
        case .poweredOff: return StatusBadge(text: "Bluetooth off", systemImage: "bolt.slash", color: .red)
        case .unauthorized: return StatusBadge(text: "Bluetooth blocked", systemImage: "bolt.slash", color: .red)
        case .idle: return StatusBadge(text: "No trainer", systemImage: "bolt.horizontal", color: .secondary)
        }
    }

    private var heartRateBadge: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let link = model.watchLink
            Label {
                Text(link.label(source: model.heart.source))
            } icon: {
                Image(systemName: link.icon)
                    .symbolEffect(.pulse, options: .repeating, isActive: link.pulses && scenePhase == .active)
            }
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(link.color.opacity(0.18), in: Capsule())
            .foregroundStyle(link.color)
        }
    }
}
