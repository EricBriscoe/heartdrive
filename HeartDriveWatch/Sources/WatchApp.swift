import HealthKit
import SwiftUI
import WatchKit

@main
struct HeartDriveWatchApp: App {
    @WKApplicationDelegateAdaptor(WatchAppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            WatchRootView()
        }
    }
}

/// Handles the workout configuration delivered when the phone launches us via
/// `HKHealthStore.startWatchApp`, meaning the rider tapped Start on the phone while
/// this app was closed. Starting from the watch itself goes through the UI.
final class WatchAppDelegate: NSObject, WKApplicationDelegate {
    func handle(_ workoutConfiguration: HKWorkoutConfiguration) {
        WatchModel.shared.workout.ensureActive()
    }
}
