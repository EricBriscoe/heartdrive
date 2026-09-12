import SwiftUI

struct SettingsView: View {
    @Bindable var settings: SettingsStore
    var monitor: HeartRateMonitorManager
    @State private var showHRConnect = false
    @Environment(\.dismiss) private var dismiss

    /// Strap row text: name plus the live reading, so "connected but silent" is visible at a glance.
    private func monitorStatusText(now: Date) -> String {
        switch monitor.connectionState {
        case .connected:
            let name = monitor.connectedName ?? "Connected"
            guard let bpm = monitor.lastBPM, let at = monitor.lastBPMAt else { return "\(name) · no reading yet" }
            let age = Int(now.timeIntervalSince(at))
            return age > 12 ? "\(name) · no reading for \(age) s" : "\(name) · \(bpm) bpm"
        case .connecting: return "\(monitor.connectedName ?? "Monitor") · connecting…"
        case .scanning: return "Scanning…"
        case .poweredOff: return "Bluetooth off"
        case .unauthorized: return "No Bluetooth permission"
        case .idle: return "Not connected"
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper(value: $settings.targetHeartRate, in: 90...200) {
                        LabeledContent("Target", value: "\(settings.targetHeartRate) bpm")
                    }
                } header: {
                    Text("Target heart rate")
                } footer: {
                    Text(
                        "The app adjusts resistance to hold this heart rate. A ±2–3 bpm deadband prevents constant hunting."
                    )
                }

                Section {
                    Stepper(value: $settings.ftp, in: 50...500, step: 5) {
                        LabeledContent("FTP", value: "\(settings.ftp) W")
                    }
                } header: {
                    Text("FTP")
                } footer: {
                    Text(
                        "Your functional threshold power. The resistance floor (\(settings.powerFloor) W), starting power (\(settings.startingPower) W), and safety ceiling (\(settings.powerCeiling) W) are all set from it; the loop never demands more than the ceiling, even if your heart rate stays below target."
                    )
                }

                Section {
                    Picker("Responsiveness", selection: $settings.aggressiveness) {
                        ForEach(ControlAggressiveness.allCases) { level in
                            Text(level.label).tag(level)
                        }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Responsiveness")
                } footer: {
                    Text(
                        "How fast resistance chases your heart rate. The app jumps to the predicted power on start and when you change the target, then fine-tunes. Gentle is smoothest; Responsive is quickest but may briefly overshoot."
                    )
                }

                Section {
                    Picker("Heart rate source", selection: $settings.hrSource) {
                        ForEach(HRSource.allCases) { source in
                            Text(source.label).tag(source)
                        }
                    }
                    .pickerStyle(.segmented)

                    if settings.hrSource == .bluetooth {
                        Button {
                            showHRConnect = true
                        } label: {
                            HStack {
                                Text("Heart-rate monitor")
                                Spacer()
                                TimelineView(.periodic(from: .now, by: 1)) { context in
                                    Text(monitorStatusText(now: context.date)).foregroundStyle(.secondary)
                                }
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                            }
                        }
                        .tint(.primary)
                    }
                } header: {
                    Text("Heart rate source")
                } footer: {
                    Text(
                        "Apple Watch streams heart rate from your wrist. Bluetooth reads a chest strap or armband directly. Pick it here and the watch stays out of the ride."
                    )
                }

            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onChange(of: settings.snapshot) { settings.save() }
            .sheet(isPresented: $showHRConnect) {
                HeartRateMonitorConnectView(monitor: monitor)
            }
        }
    }
}
