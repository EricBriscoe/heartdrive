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
                        "Gentle is the smoothest and most stable. Heart rate reacts slowly (10–30s), so even Responsive stays deliberately damped."
                    )
                }

                Section {
                    Toggle("Save rides to Apple Health", isOn: $settings.saveWorkoutToHealth)
                } header: {
                    Text("Workout history")
                } footer: {
                    Text(
                        "When on, rides longer than 2 minutes are saved to Apple Health and count toward your activity rings. Short start/stops are always discarded so they don't clutter your history."
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
