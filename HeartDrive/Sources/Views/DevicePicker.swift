import SwiftUI

/// Shared picker presentation. Scanning and connection lifecycles stay with the
/// owning manager; selecting a device connects before dismissing the sheet.
struct DevicePicker: View {
    var title: String
    var section: String
    var guidance: LocalizedStringKey
    var devices: [DiscoveredDevice]
    var scan: () -> Void
    var stopScan: () -> Void
    var connect: (DiscoveredDevice) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if devices.isEmpty {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Scanning…").foregroundStyle(.secondary)
                        }
                    } else {
                        ForEach(devices) { found in
                            Button {
                                connect(found)
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
                    Text(section)
                } footer: {
                    Text(guidance)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .onAppear(perform: scan)
            .onDisappear(perform: stopScan)
        }
    }
}
