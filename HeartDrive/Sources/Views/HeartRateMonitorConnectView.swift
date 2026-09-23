import SwiftUI

struct HeartRateMonitorConnectView: View {
    var monitor: HeartRateMonitorManager

    var body: some View {
        DevicePicker(
            title: "Connect monitor", section: "Heart-rate monitors",
            guidance: "Put your strap or armband on (moisten a chest strap's contacts to wake it). It must not be connected to another app at the same time.",
            devices: monitor.discovered, scan: monitor.scan, stopScan: monitor.stopScan,
            connect: monitor.connect)
    }
}
