import SwiftUI

struct HeartRateMonitorConnectView: View {
    var monitor: HeartRateMonitorManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if monitor.discovered.isEmpty {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Scanning…").foregroundStyle(.secondary)
                        }
                    } else {
                        ForEach(monitor.discovered) { found in
                            Button {
                                monitor.connect(found)
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
                    Text("Heart-rate monitors")
                } footer: {
                    Text(
                        "Put your strap or armband on (moisten a chest strap's contacts to wake it). It must not be connected to another app at the same time."
                    )
                }
            }
            .navigationTitle("Connect monitor")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .onAppear { monitor.scan() }
            .onDisappear { monitor.stopScan() }
        }
    }
}
