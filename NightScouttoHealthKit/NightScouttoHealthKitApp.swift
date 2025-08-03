import SwiftUI
import SwiftData
import UIKit
import BackgroundTasks
import UserNotifications
import OneSignalFramework

// MARK: - BGTask Identifiers
fileprivate let refreshTaskID = "com.ProDiabeticsTeam.NightScouttoHealthKitv1"
fileprivate let processingTaskID = "com.ProDiabeticsTeam.NightScouttoHealthKit.processing"

@main
struct NightScouttoHealthKitApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    // Create the model container that will be shared across the app
    let modelContainer: ModelContainer = {
        do {
            return try ModelContainer(for: Prediction.self, MultiModelPrediction.self, HealthKitBGCache.self, WorkoutTimeData.self)
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
    }()
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .modelContainer(modelContainer)
                .onAppear {
                    // Set the model container for the notification handler
                    NotificationHandler.shared.setModelContainer(modelContainer)
                    // Initialize WatchConnectivity for Apple Watch communication
                    _ = WatchConnectivityManager.shared
                    print("✅ WatchConnectivityManager initialized")
                }
        }
    }
}

final class AppDelegate: UIResponder, UIApplicationDelegate {
    
    // MARK: - UIApplicationDelegate
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        
        // Enable verbose logging for debugging (remove in production)
        OneSignal.Debug.setLogLevel(.LL_VERBOSE)
        // Initialize with your OneSignal App ID
        OneSignal.initialize("060af08a-0787-4eca-8d1c-cc8279f3e525", withLaunchOptions: launchOptions)
        
        // Use this method to prompt for push notifications.
        // We recommend removing this method after testing and instead use In-App Messages to prompt for notification permission.
        OneSignal.Notifications.requestPermission({ accepted in
            print("User accepted notifications: \(accepted)")
        }, fallbackToSettings: false)
        
        return true
    }
    
    // Remaining contents of your AppDelegate Class...
}
