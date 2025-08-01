// NightScouttoHealthKitApp.swift
// NightScouttoHealthKit

// Created by Patrick Pallagi on 2025-05-09.

import SwiftUI
import SwiftData
import UIKit
import BackgroundTasks
import UserNotifications
import SuprSend

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
    
    // Use the same distinct ID that appears in your SuprSend dashboard
    private let DISTINCT_ID = "T3L8DD7W3T"
    
    // MARK: - UIApplicationDelegate
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        print("🚀 App launched - Background predictions disabled, manual-only mode")
        
        // Initialize SuprSend with Swift Package Manager
        _ = SuprSendClient(publicKey: "SS.PUBK.C6RFiNwCjPNSIoDiAdR5XnIdXMXESAnL-H5sDfXq3QM")
        
        // Store workspace credentials for later use if needed
        UserDefaults.standard.set("oXLT425KxJdjEsMAnnt7", forKey: "suprsend_workspace_key")
        UserDefaults.standard.set("SS.WSS.zci-CGoHs4qXAUSYV972XsxZj4TQ6Mgb1iyGbubs",
                                 forKey: "suprsend_workspace_secret")
        
        print("📱 SuprSend Swift SDK initialized successfully!")
        
        // Set notification center delegate for SuprSend
        UNUserNotificationCenter.current().delegate = self
        
        // Request notification permissions first
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
                // Track permission denial
                Task {
                    _ = await SuprSend.shared.track(
                        event: "notification_permission_denied",
                        properties: ["timestamp": ISO8601DateFormatter().string(from: Date())]
                    )
                }
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
        
        // Now that we have the device token, set up SuprSend
        setupSuprSendWithToken(deviceToken: token)
    }
    
    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("❌ Failed to register for remote notifications: \(error)")
        
        Task {
            _ = await SuprSend.shared.track(
                event: "notification_registration_failed",
                properties: [
                    "error": error.localizedDescription,
                    "timestamp": ISO8601DateFormatter().string(from: Date())
                ]
            )
        }
    }
    
    // MARK: - SuprSend Setup with Device Token
    private func setupSuprSendWithToken(deviceToken: String) {
        Task {
            print("🔗 Setting up SuprSend for user: \(DISTINCT_ID)")
            print("📱 Device token: \(deviceToken)")
            
            // Step 1: Identify the user first
            let identifyResult = await SuprSend.shared.identify(distinctID: DISTINCT_ID)
            print("🆔 User identification result: \(identifyResult)")
            
            // Step 2: The SuprSend Swift SDK should automatically handle device token registration
            // when the app registers for remote notifications. Let's verify this by sending test data
            
            // Step 3: Try manual registration via API as backup
            await registerPushChannelViaAPI(deviceToken: deviceToken)
            
            // Step 4: Track the setup event with device token info
            _ = await SuprSend.shared.track(
                event: "device_setup_complete",
                properties: [
                    "distinctId": DISTINCT_ID,
                    "deviceToken": deviceToken,
                    "platform": "ios",
                    "sdk_version": "swift",
                    "timestamp": ISO8601DateFormatter().string(from: Date())
                ]
            )
            
            print("✅ SuprSend setup completed for user: \(DISTINCT_ID)")
            
            // Step 5: Test the setup immediately
            await testNotificationSetup()
        }
    }
    
    // MARK: - Register Push Channel via REST API
    private func registerPushChannelViaAPI(deviceToken: String) async {
        print("📡 Registering iOS push channel via REST API...")
        
        guard let workspaceKey = UserDefaults.standard.string(forKey: "suprsend_workspace_key"),
              let workspaceSecret = UserDefaults.standard.string(forKey: "suprsend_workspace_secret") else {
            print("❌ Missing workspace credentials")
            return
        }
        
        // Create the request payload for user profile update
        let payload: [String: Any] = [
            "distinct_id": DISTINCT_ID,
            "$iospush": [deviceToken]  // Use the correct channel format
        ]
        
        // Convert to JSON
        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload) else {
            print("❌ Failed to serialize JSON payload")
            return
        }
        
        // Create the correct URL - try the user profile endpoint
        guard let url = URL(string: "https://hub.suprsend.com/user/") else {
            print("❌ Invalid URL")
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        // Create basic auth header
        let credentials = "\(workspaceKey):\(workspaceSecret)"
        let credentialsData = credentials.data(using: .utf8)!
        let base64Credentials = credentialsData.base64EncodedString()
        request.setValue("Basic \(base64Credentials)", forHTTPHeaderField: "Authorization")
        
        request.httpBody = jsonData
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            if let httpResponse = response as? HTTPURLResponse {
                print("📡 Push channel registration HTTP status: \(httpResponse.statusCode)")
                
                if httpResponse.statusCode == 200 || httpResponse.statusCode == 201 {
                    print("✅ iOS push channel registered successfully")
                    
                    let responseString = String(data: data, encoding: .utf8) ?? "No response data"
                    print("📄 Response: \(responseString)")
                } else {
                    print("❌ Failed to register push channel. Status: \(httpResponse.statusCode)")
                    
                    let responseString = String(data: data, encoding: .utf8) ?? "No response data"
                    print("❌ Error response: \(responseString)")
                    
                    // Try alternative approach using SuprSend Swift SDK if available
                    await trySDKChannelRegistration(deviceToken: deviceToken)
                }
            }
        } catch {
            print("❌ Network error registering push channel: \(error)")
            
            // Try alternative approach using SuprSend Swift SDK if available
            await trySDKChannelRegistration(deviceToken: deviceToken)
        }
    }
    
    // MARK: - Alternative SDK Channel Registration
    private func trySDKChannelRegistration(deviceToken: String) async {
        print("🔄 Trying alternative SDK channel registration...")
        
        // The SuprSend Swift SDK might handle channel registration differently
        // Let's try setting user properties with the device token
        
        // Re-identify user (this might trigger automatic channel detection)
        let identifyResult = await SuprSend.shared.identify(distinctID: DISTINCT_ID)
        print("🔄 Alternative identification result: \(identifyResult)")
        
        // Track the device token in properties
        _ = await SuprSend.shared.track(
            event: "device_token_fallback_registration",
            properties: [
                "distinctId": DISTINCT_ID,
                "deviceToken": deviceToken,
                "platform": "ios",
                "registration_method": "fallback",
                "timestamp": ISO8601DateFormatter().string(from: Date())
            ]
        )
        
        print("📱 Alternative registration attempt completed")
    }
    
    // MARK: - Test Notification Setup
    private func testNotificationSetup() async {
        print("🧪 Testing notification setup...")
        
        // Send a test event to verify everything is working
        _ = await SuprSend.shared.track(
            event: "notification_setup_test",
            properties: [
                "distinctId": DISTINCT_ID,
                "setup_time": ISO8601DateFormatter().string(from: Date()),
                "test_message": "This is a test to verify notification channel setup"
            ]
        )
        
        print("📧 Test event sent - check SuprSend dashboard for delivery")
    }
    
    // MARK: - Background Notification Handling
    func application(_ application: UIApplication,
                    didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                    fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        
        print("📮 Background notification received")
        print("📄 Notification content: \(userInfo)")
        
        Task {
            let convertedInfo = Dictionary(uniqueKeysWithValues:
                userInfo.compactMap { key, value -> (String, String)? in
                    guard let stringKey = key as? String else { return nil }
                    return (stringKey, "\(value)")
                })
            
            _ = await SuprSend.shared.track(
                event: "notification_delivered_background",
                properties: [
                    "userInfo": convertedInfo,
                    "timestamp": ISO8601DateFormatter().string(from: Date())
                ]
            )
            
            completionHandler(.newData)
        }
    }
    
    // MARK: - Background Task Registration (Disabled)
    private func getModelContainer() -> ModelContainer {
        do {
            return try ModelContainer(for: Prediction.self, MultiModelPrediction.self, HealthKitBGCache.self, WorkoutTimeData.self)
        } catch {
            fatalError("Failed to create ModelContainer for background task: \(error)")
        }
    }
    
    // MARK: - App Lifecycle
    func applicationDidEnterBackground(_ application: UIApplication) {
        print("📱 App entered background")
    }
    
    func applicationWillEnterForeground(_ application: UIApplication) {
        print("📱 App entering foreground")
        
        // Optional: Refresh setup when app comes to foreground
        refreshSetupIfNeeded()
    }
    
    func applicationDidBecomeActive(_ application: UIApplication) {
        print("📱 App became active")
    }
    
    // MARK: - Setup Refresh
    private func refreshSetupIfNeeded() {
        guard let deviceToken = UserDefaults.standard.string(forKey: "apns_device_token") else {
            print("⚠️ No stored device token found")
            return
        }
        
        let lastRefresh = UserDefaults.standard.double(forKey: "last_setup_refresh")
        let now = Date().timeIntervalSince1970
        
        // Refresh setup every 24 hours
        if now - lastRefresh > 86400 {
            print("🔄 Refreshing SuprSend setup...")
            setupSuprSendWithToken(deviceToken: deviceToken)
            UserDefaults.standard.set(now, forKey: "last_setup_refresh")
        }
    }
    
    // MARK: - UNUserNotificationCenterDelegate
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                               willPresent notification: UNNotification,
                               withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        
        let content = notification.request.content
        print("📱 Foreground notification: \(content.title)")
        print("📄 Body: \(content.body)")
        
        Task {
            _ = await SuprSend.shared.track(
                event: "notification_presented_foreground",
                properties: [
                    "title": content.title,
                    "body": content.body,
                    "timestamp": ISO8601DateFormatter().string(from: Date())
                ]
            )
        }
        
        // Show notification even when app is in foreground
        completionHandler([.banner, .badge, .sound])
    }
    
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                               didReceive response: UNNotificationResponse,
                               withCompletionHandler completionHandler: @escaping () -> Void) {
        
        let content = response.notification.request.content
        print("👆 Notification tapped: \(content.title)")
        
        Task {
            _ = await SuprSend.shared.track(
                event: "notification_tapped",
                properties: [
                    "title": content.title,
                    "body": content.body,
                    "actionIdentifier": response.actionIdentifier,
                    "timestamp": ISO8601DateFormatter().string(from: Date())
                ]
            )
        }
        
        completionHandler()
    }
    
    // MARK: - Debug Helper Methods
    func debugSuprSendSetup() {
        Task {
            let deviceToken = UserDefaults.standard.string(forKey: "apns_device_token")
            
            print("🔍 SuprSend Debug Info:")
            print("   Distinct ID: \(DISTINCT_ID)")
            print("   Device Token: \(deviceToken ?? "Not available")")
            print("   Token Length: \(deviceToken?.count ?? 0) characters")
            
            if let token = deviceToken {
                print("🔄 Re-setting up SuprSend...")
                setupSuprSendWithToken(deviceToken: token)
            } else {
                print("❌ No device token available - requesting notifications again")
                requestNotificationPermissions()
            }
        }
    }
    
    // MARK: - Manual Test Method (call this from your UI for testing)
    func sendTestNotification() {
        Task {
            print("📧 Sending manual test notification...")
            
            _ = await SuprSend.shared.track(
                event: "manual_test_notification",
                properties: [
                    "distinctId": DISTINCT_ID,
                    "test_type": "manual_trigger",
                    "timestamp": ISO8601DateFormatter().string(from: Date()),
                    "message": "Manual test notification from iOS app"
                ]
            )
            
            print("✅ Manual test notification event sent")
        }
    }
    
    // MARK: - Verify Channel Registration
    func verifyChannelRegistration() {
        Task {
            guard let deviceToken = UserDefaults.standard.string(forKey: "apns_device_token") else {
                print("❌ No device token available")
                return
            }
            
            print("🔍 Verifying channel registration...")
            print("   Distinct ID: \(DISTINCT_ID)")
            print("   Device Token: \(deviceToken)")
            
            // Re-register the channel
            await registerPushChannelViaAPI(deviceToken: deviceToken)
            
            // Send a test event
            _ = await SuprSend.shared.track(
                event: "channel_verification_test",
                properties: [
                    "distinctId": DISTINCT_ID,
                    "deviceToken": deviceToken,
                    "timestamp": ISO8601DateFormatter().string(from: Date())
                ]
            )
            
            print("✅ Channel verification completed")
        }
    }
}
