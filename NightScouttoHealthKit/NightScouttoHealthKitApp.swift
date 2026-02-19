import SwiftUI
import SwiftData
import UIKit
import BackgroundTasks
import UserNotifications

// MARK: - BGTask Identifiers
fileprivate let refreshTaskID = "com.ProDiabeticsTeam.NightScouttoHealthKitv1"
fileprivate let processingTaskID = "com.ProDiabeticsTeam.NightScouttoHealthKit.processing"
fileprivate let gpuWaveNetTaskID = "com.ProDiabeticsTeam.NightScouttoHealthKit.gpu-wavenet"

@main
struct NightScouttoHealthKitApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    // Create the model container that will be shared across the app with App Group support
    let modelContainer: ModelContainer = {
        do {
            // Get App Group container URL
            guard let appGroupURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.ProDiabeticsTeam.NightScouttoHealthKitv1.onesignal") else {
                print("⚠️ App Group container not available, using default container")
                return try ModelContainer(for: Prediction.self, MultiModelPrediction.self, HealthKitBGCache.self, WorkoutTimeData.self, NightScoutInsulinCache.self, NightScoutCarbCache.self, RandomForestPrediction.self)
            }
            
            // Ensure Application Support directory exists
            let applicationSupportURL = appGroupURL.appendingPathComponent("Library/Application Support")
            try FileManager.default.createDirectory(at: applicationSupportURL, withIntermediateDirectories: true, attributes: nil)
            
            // Configure SwiftData store URL in App Group
            let storeURL = applicationSupportURL.appendingPathComponent("SaveKitData.store")
            print("📁 Using SwiftData store at: \(storeURL.path)")
            
            // Create ModelContainer with custom configuration
            let configuration = ModelConfiguration(
                url: storeURL,
                cloudKitDatabase: .none // Disable CloudKit for App Group container
            )
            
            return try ModelContainer(
                for: Prediction.self, MultiModelPrediction.self, HealthKitBGCache.self, WorkoutTimeData.self, NightScoutInsulinCache.self, NightScoutCarbCache.self, RandomForestPrediction.self,
                configurations: configuration
            )
            
        } catch {
            print("❌ ModelContainer creation failed: \(error)")
            print("🔄 Attempting fallback to default container...")
            
            // Fallback to default container if App Group fails
            do {
                return try ModelContainer(for: Prediction.self, MultiModelPrediction.self, HealthKitBGCache.self, WorkoutTimeData.self, NightScoutInsulinCache.self, NightScoutCarbCache.self, RandomForestPrediction.self)
            } catch {
                fatalError("Failed to create fallback ModelContainer: \(error)")
            }
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
        
        // Register background tasks for GPU WaveNet processing
        registerBackgroundTasks()
        
        return true
    }
    
    // MARK: - Background Task Registration
    private func registerBackgroundTasks() {
        // Register the existing background tasks
        BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshTaskID, using: nil) { task in
            print("🔄 Background refresh task started")
            self.handleBackgroundRefresh(task as! BGAppRefreshTask)
        }
        
        BGTaskScheduler.shared.register(forTaskWithIdentifier: processingTaskID, using: nil) { task in
            print("🔄 Background processing task started")
            self.handleBackgroundProcessing(task as! BGProcessingTask)
        }
        
        print("✅ Background tasks registered successfully")
    }
    
    // MARK: - Background Task Handlers
    private func handleBackgroundRefresh(_ task: BGAppRefreshTask) {
        task.expirationHandler = {
            task.setTaskCompleted(success: false)
        }
        
        Task {
            // Perform background refresh operations
            let success = await performBackgroundRefresh()
            task.setTaskCompleted(success: success)
        }
    }
    
    private func handleBackgroundProcessing(_ task: BGProcessingTask) {
        task.expirationHandler = {
            task.setTaskCompleted(success: false)
        }
        
        Task {
            // Perform background processing operations
            let success = await performBackgroundProcessing()
            task.setTaskCompleted(success: success)
        }
    }
    
    @MainActor
    private func performBackgroundRefresh() async -> Bool {
        print("🔄 Performing background refresh...")
        // Add your background refresh logic here
        return true
    }
    
    @MainActor
    private func performBackgroundProcessing() async -> Bool {
        print("🔄 Performing background processing...")
        // Add your background processing logic here
        return true
    }
    
    // MARK: - Device Token Handling
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        print("📱 Device registered for remote notifications")
        
        let tokenString = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
        print("📬 Device Token: \(tokenString)")
    }
    
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("❌ Failed to register for remote notifications: \(error)")
    }
    
    // MARK: - App Lifecycle - Automatic HealthKit Sync
    func applicationDidBecomeActive(_ application: UIApplication) {
        print("🔄 === APP BECAME ACTIVE - TRIGGERING HEALTHKIT SYNC ===")
        
        // Automatically sync HealthKit insulin and carb data to SwiftData
        // This ensures SwiftData pairs are always fresh for background predictions
        Task {
            let syncResults = await WatchConnectivityManager.shared.performHealthKitToSwiftDataSync()
            print("✅ Automatic HealthKit sync completed - Insulin: \(syncResults.insulin), Carbs: \(syncResults.carbs)")
        }
    }
    
    // Handle background remote notifications
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable : Any], fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        print("🔔 === REMOTE NOTIFICATION RECEIVED (no auto actions) ===")
        print("📦 UserInfo: \(userInfo)")
        completionHandler(.noData)
    }
}

