import SwiftUI
import SwiftData
import UIKit
import BackgroundTasks
import UserNotifications
import OneSignalFramework

// MARK: - BGTask Identifiers
fileprivate let refreshTaskID = "com.ProDiabeticsTeam.NightScouttoHealthKitv1"
fileprivate let processingTaskID = "com.ProDiabeticsTeam.NightScouttoHealthKit.processing"
fileprivate let gpuWaveNetTaskID = "com.ProDiabeticsTeam.NightScouttoHealthKit.gpu-wavenet"

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
                    
                    // Initialize and configure BackgroundGPUWaveNetService
                    BackgroundGPUWaveNetService.shared.setModelContainer(modelContainer)
                    print("✅ BackgroundGPUWaveNetService initialized with model container")
                    
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
        
        // Set OneSignal notification listeners for comprehensive notification handling
        setupOneSignalNotificationListeners()
        
        // Request notification permissions with fallback to settings
        OneSignal.Notifications.requestPermission({ accepted in
            print("📱 OneSignal notification permission: \(accepted ? "GRANTED" : "DENIED")")
            if accepted {
                print("🔔 OneSignal notifications enabled - GPU WaveNet will trigger on all notifications")
            }
        }, fallbackToSettings: true)
        
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
    
    // MARK: - OneSignal Notification Handlers Setup
    private func setupOneSignalNotificationListeners() {
        // Create a class conforming to OSNotificationLifecycleListener
        class ForegroundLifecycleListener: NSObject, OSNotificationLifecycleListener {
            weak var appDelegate: AppDelegate?
            
            init(appDelegate: AppDelegate) {
                self.appDelegate = appDelegate
                super.init()
            }
            
            func onWillDisplay(event: OSNotificationWillDisplayEvent) {
                let notification = event.notification
                
                print("🔔 === ONESIGNAL FOREGROUND NOTIFICATION ===")
                print("📱 Notification ID: \(notification.notificationId ?? "unknown")")
                print("📝 Title: \(notification.title ?? "No title")")
                print("📄 Body: \(notification.body ?? "No body")")
                print("🔥 TRIGGERING BACKGROUND GPU WAVENET PROCESSING")
                
                // Send OneSignal notification to Apple Watch
                WatchConnectivityManager.shared.sendOneSignalNotificationToWatch(
                    title: notification.title ?? "NightScout Notification",
                    body: notification.body ?? "New notification received"
                )
                
                // Trigger GPU WaveNet processing immediately
                Task { @MainActor in
                    await BackgroundGPUWaveNetService.shared.triggerManualGPUPrediction()
                }
                
                // Show custom alert for GPU processing
                DispatchQueue.main.async {
                    self.appDelegate?.showGPUProcessingAlert(notification: notification)
                }
                
                // Allow the notification to display normally
                // Don't call event.preventDefault() so notification shows
            }
        }
        
        // Create a class conforming to OSNotificationClickListener
        class ClickListener: NSObject, OSNotificationClickListener {
            weak var appDelegate: AppDelegate?
            
            init(appDelegate: AppDelegate) {
                self.appDelegate = appDelegate
                super.init()
            }
            
            func onClick(event: OSNotificationClickEvent) {
                let notification = event.notification
                
                print("🔔 === ONESIGNAL NOTIFICATION CLICKED ===")
                print("📱 Clicked Notification ID: \(notification.notificationId ?? "unknown")")
                print("🔥 TRIGGERING IMMEDIATE GPU WAVENET PROCESSING")
                
                // Send OneSignal notification to Apple Watch (for click events too)
                WatchConnectivityManager.shared.sendOneSignalNotificationToWatch(
                    title: notification.title ?? "NightScout Notification",
                    body: notification.body ?? "Notification was tapped"
                )
                
                // Trigger GPU WaveNet processing immediately
                Task { @MainActor in
                    await BackgroundGPUWaveNetService.shared.triggerManualGPUPrediction()
                }
                
                // Show custom alert for GPU processing
                DispatchQueue.main.async {
                    self.appDelegate?.showGPUProcessingAlert(notification: notification)
                }
            }
        }
        
        // Add the listeners
        OneSignal.Notifications.addForegroundLifecycleListener(ForegroundLifecycleListener(appDelegate: self))
        OneSignal.Notifications.addClickListener(ClickListener(appDelegate: self))
        
        print("✅ OneSignal notification handlers configured")
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
    

    
    // MARK: - GPU Processing Alert
    private func showGPUProcessingAlert(notification: OSNotification) {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = windowScene.windows.first else {
            print("❌ Could not find window to show alert")
            return
        }
        
        let alert = UIAlertController(
            title: "🔥 GPU WaveNet Activated",
            message: "OneSignal notification received!\n\nRunning all 5 WaveNet models on iPhone GPU for blood glucose prediction.\n\nNotification: \(notification.title ?? "Unknown")",
            preferredStyle: .alert
        )
        
        alert.addAction(UIAlertAction(title: "View Results", style: .default) { _ in
            // Switch to the prediction tab to view results
            if let tabBarController = window.rootViewController as? UITabBarController {
                tabBarController.selectedIndex = 0 // Switch to prediction tab
            }
        })
        
        alert.addAction(UIAlertAction(title: "OK", style: .cancel))
        
        window.rootViewController?.present(alert, animated: true)
    }
    
    // MARK: - Device Token Handling
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        print("📱 Device registered for remote notifications")
        
        // Send device token to OneSignal (handled automatically by OneSignal SDK)
        
        let tokenString = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
        print("📬 Device Token: \(tokenString)")
        
        // Debug OneSignal user info
        if let userId = OneSignal.User.onesignalId {
            print("👤 OneSignal User ID: \(userId)")
        }
        
        print("🔔 OneSignal Subscription Status: \(OneSignal.User.pushSubscription.optedIn)")
    }
    
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("❌ Failed to register for remote notifications: \(error)")
    }
    
    // Handle background remote notifications
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable : Any], fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        print("🔔 === BACKGROUND REMOTE NOTIFICATION ===")
        print("📦 UserInfo: \(userInfo)")
        print("🔥 TRIGGERING BACKGROUND GPU WAVENET PROCESSING")
        
        // Trigger GPU WaveNet processing in background
        Task { @MainActor in
            await BackgroundGPUWaveNetService.shared.triggerManualGPUPrediction()
            completionHandler(.newData)
        }
    }
}
