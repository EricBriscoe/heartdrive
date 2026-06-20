import SwiftUI

struct TrainerConnectView: View {
    var trainer: TrainerManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if trainer.discovered.isEmpty {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Scanning…").foregroundStyle(.secondary)
                        }
                    } else {
                        ForEach(trainer.discovered) { found in
                            Button {
                                trainer.connect(found)
                                dismiss()
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(found.name).foregroundStyle(.primary)
                                        Text("Signal \(found.rssi) dBm")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Trainers")
                } footer: {
                    Text(
                        "Pedal a turn to wake the trainer. It must not be paired as the **Controllable** trainer in any other app. Pair it in Zwift as Power + Cadence only."
                    )
                }
            }
            .navigationTitle("Connect trainer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .onAppear { trainer.scan() }
            .onDisappear { trainer.stopScan() }
        }
    }
}
