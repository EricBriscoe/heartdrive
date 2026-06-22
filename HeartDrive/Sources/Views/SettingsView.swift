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
                    Stepper(value: $settings.powerFloor, in: 30...300, step: 5) {
                        LabeledContent("Floor", value: "\(settings.powerFloor) W")
                    }
                    Stepper(value: $settings.powerCeiling, in: settings.powerFloor...600, step: 5) {
                        LabeledContent("Ceiling", value: "\(settings.powerCeiling) W")
                    }
                    Stepper(
                        value: $settings.startingPower,
                        in: settings.powerFloor...max(settings.powerFloor, settings.powerCeiling), step: 5
                    ) {
                        LabeledContent("Start at", value: "\(settings.startingPower) W")
                    }
                } header: {
                    Text("Power limits")
                } footer: {
                    Text(
                        "The ceiling is your main safety limit; the loop will never demand more than this, even if your heart rate stays below target."
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
                        "How fast resistance chases your heart rate. The app jumps to the predicted power on start and when you change the target, then fine-tunes, so it reaches the target far faster than before. Gentle is smoothest; Responsive is quickest but may briefly overshoot."
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
