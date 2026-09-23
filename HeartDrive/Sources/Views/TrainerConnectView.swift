import SwiftUI

struct TrainerConnectView: View {
    var trainer: TrainerManager

    var body: some View {
        DevicePicker(
            title: "Connect trainer", section: "Trainers",
            guidance: "Pedal a turn to wake the trainer. It must not be paired as the **Controllable** trainer in any other app. Pair it in Zwift as Power + Cadence only.",
            devices: trainer.discovered, scan: trainer.scan, stopScan: trainer.stopScan,
            connect: trainer.connect)
    }
}
