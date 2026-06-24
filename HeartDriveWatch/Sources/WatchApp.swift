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

/// Lets the phone launch or wake the watch app to begin a ride: the phone's
/// `HKHealthStore.startWatchApp(with:)` delivers the workout configuration here.
final class WatchAppDelegate: NSObject, WKApplicationDelegate {
    func handle(_ workoutConfiguration: HKWorkoutConfiguration) {
        WatchModel.shared.startFromPhone()
    }
}
