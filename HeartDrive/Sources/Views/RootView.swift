import SwiftUI
import UIKit

struct RootView: View {
    @State private var model = AppModel.shared
    @State private var showSettings = false
    @State private var showConnect = false
    @Environment(\.scenePhase) private var scenePhase

    // Keep the phone awake while a ride is active so locking can't drop the
    // watch link or the Zwift heart-rate broadcast.
    private var keepAwake: Bool { model.isControlling || model.settings.broadcastToZwift }

    var body: some View {
        NavigationStack {
            RideDashboardView(model: model, showConnect: $showConnect)
                .navigationTitle("HeartDrive")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            showConnect = true
                        } label: {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showSettings = true
                        } label: {
                            Image(systemName: "gearshape")
                        }
                    }
                }
                .sheet(isPresented: $showSettings) {
                    SettingsView(settings: model.settings)
                }
                .sheet(isPresented: $showConnect) {
                    TrainerConnectView(trainer: model.trainer)
                }
        }
        .onChange(of: keepAwake, initial: true) { _, awake in
            UIApplication.shared.isIdleTimerDisabled = awake
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { UIApplication.shared.isIdleTimerDisabled = keepAwake }
        }
        .onChange(of: model.settings.targetHeartRate) { _, _ in model.reconcileTargetEdit() }
    }
}
