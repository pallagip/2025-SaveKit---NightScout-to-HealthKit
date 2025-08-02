import SwiftUI
import SwiftData
import UIKit
import BackgroundTasks
import UserNotifications

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

final class AppDelegate: UIResponder, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    
    // MARK: - UIApplicationDelegate
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        print("🚀 App launched - Background predictions disabled, manual-only mode")
        
        // Set notification center delegate
        UNUserNotificationCenter.current().delegate = self
        
        // Request notification permissions
        requestNotificationPermissions()
        
        return true
    }
    
    // MARK: - Notification Permissions
    private func requestNotificationPermissions() {
        let options: UNAuthorizationOptions = [.alert, .sound, .badge]
        UNUserNotificationCenter.current().requestAuthorization(options: options) { granted, error in
            if let error = error {
                print("❌ Notification permission error: \(error)")
                return
            }
            
            print("📱 Notification permission granted: \(granted)")
            
            if granted {
                DispatchQueue.main.async {
                    UIApplication.shared.registerForRemoteNotifications()
                }
            } else {
                print("⚠️ Notification permissions denied by user")
            }
        }
    }
    
    // MARK: - APNs Token Handling
    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
        print("📬 APNs Token received: \(token)")
        print("📬 Token length: \(token.count) characters")
        
        // Store token locally
        UserDefaults.standard.set(token, forKey: "apns_device_token")
        
        print("✅ Device token stored successfully")
    }
    
    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("❌ Failed to register for remote notifications: \(error)")
    }
    
    // MARK: - Background Notification Handling
    func application(_ application: UIApplication,
                    didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                    fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        
        print("📮 Background notification received with userInfo: \(userInfo)")
        print("📄 Notification content keys: \(userInfo.keys)")
        
        // Display notification if app is in background
        if application.applicationState == .background {
            if let aps = userInfo["aps"] as? [AnyHashable: Any],
               let alert = aps["alert"] as? [AnyHashable: Any],
               let body = alert["body"] as? String {
                print("📢 Displaying background notification: \(alert["title"] ?? "No Title") - \(body)")
                displayNotificationAlert(title: alert["title"] as? String ?? "Background Notification", body: body)
            } else if let aps = userInfo["aps"] as? [AnyHashable: Any],
                     let alert = aps["alert"] as? String {
                print("📢 Displaying background notification: \(alert)")
                displayNotificationAlert(title: "Background Notification", body: alert)
            } else {
                print("⚠️ No valid alert data in aps")
                displayNotificationAlert(title: "Background Notification", body: "No message available")
            }
        }
        
        completionHandler(.newData)
    }
    
    // MARK: - App Lifecycle
    func applicationDidEnterBackground(_ application: UIApplication) {
        print("📱 App entered background")
    }
    
    func applicationWillEnterForeground(_ application: UIApplication) {
        print("📱 App entering foreground")
    }
    
    func applicationDidBecomeActive(_ application: UIApplication) {
        print("📱 App became active")
    }
    
    // MARK: - UNUserNotificationCenterDelegate
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                               willPresent notification: UNNotification,
                               withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        
        let content = notification.request.content
        print("📱 Foreground notification received: \(content.title) - \(content.body)")
        
        // Display notification as an alert in the foreground
        displayNotificationAlert(title: content.title, body: content.body)
        
        // Show notification even when app is in foreground
        completionHandler([.banner, .badge, .sound])
    }
    
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                               didReceive response: UNNotificationResponse,
                               withCompletionHandler completionHandler: @escaping () -> Void) {
        
        let content = response.notification.request.content
        print("👆 Notification tapped: \(content.title) - \(content.body)")
        
        // Display notification alert when tapped
        displayNotificationAlert(title: content.title, body: content.body)
        
        completionHandler()
    }
    
    // MARK: - Display Notification Alert
    private func displayNotificationAlert(title: String, body: String?) {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = windowScene.windows.first,
              let topViewController = window.rootViewController?.presentedViewController ?? window.rootViewController else {
            print("❌ Could not find top view controller to present alert")
            return
        }
        
        let alertController = UIAlertController(
            title: title,
            message: body ?? "No message available",
            preferredStyle: .alert
        )
        alertController.addAction(UIAlertAction(title: "OK", style: .default, handler: nil))
        
        DispatchQueue.main.async {
            topViewController.present(alertController, animated: true, completion: nil)
        }
    }
    
    // MARK: - Debug Helper Methods
    func debugNotificationSetup() {
        let deviceToken = UserDefaults.standard.string(forKey: "apns_device_token")
        
        print("🔍 Notification Debug Info:")
        print("   Device Token: \(deviceToken ?? "Not available")")
        print("   Token Length: \(deviceToken?.count ?? 0) characters")
        
        if deviceToken == nil {
            print("❌ No device token available - requesting notifications again")
            requestNotificationPermissions()
        } else {
            print("✅ Device token is available")
        }
    }
}
