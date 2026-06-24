import SwiftUI

struct SettingsView: View {
    @Bindable var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss

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

            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onChange(of: settings.snapshot) { settings.save() }
        }
    }
}
