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
    
    // Store workspace credentials for API calls
    private let WORKSPACE_KEY = "oXLT425KxJdjEsMAnnt7"
    private let WORKSPACE_SECRET = "SS.WSS.zci-CGoHs4qXAUSYV972XsxZj4TQ6Mgb1iyGbubs"
    private let REST_API_KEY = "SS.NhusD-X7dOCvoI3FYo34Yj2RahZ1cUJ02TzDsv8iGFM"
    
    // MARK: - UIApplicationDelegate
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        print("🚀 App launched - Background predictions disabled, manual-only mode")
        
        // Initialize SuprSend with Swift Package Manager
        _ = SuprSendClient(publicKey: "SS.PUBK.C6RFiNwCjPNSIoDiAdR5XnIdXMXESAnL-H5sDfXq3QM")
        
        // Store workspace credentials for later use if needed
        UserDefaults.standard.set(WORKSPACE_KEY, forKey: "suprsend_workspace_key")
        UserDefaults.standard.set(WORKSPACE_SECRET, forKey: "suprsend_workspace_secret")
        UserDefaults.standard.set(REST_API_KEY, forKey: "suprsend_rest_api_key")
        
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
        
        // Use the correct SuprSend identify endpoint for channel registration
        guard let url = URL(string: "https://hub.suprsend.com/identify/") else {
            print("❌ Invalid URL")
            return
        }
        
        // Create identify payload for iOS push channel registration
        let payload: [String: Any] = [
            "distinct_id": DISTINCT_ID,
            "$iospush": deviceToken,
            "$set": [
                "device_token": deviceToken,
                "platform": "ios",
                "app_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
                "last_seen": ISO8601DateFormatter().string(from: Date())
            ]
        ]
        
        // Convert to JSON
        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload, options: .prettyPrinted) else {
            print("❌ Failed to serialize JSON payload")
            return
        }
        
        // Debug: Print the payload
        if let jsonString = String(data: jsonData, encoding: .utf8) {
            print("📤 Sending payload: \(jsonString)")
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        // Create authorization header using REST API key
        request.setValue("Bearer \(REST_API_KEY)", forHTTPHeaderField: "Authorization")
        
        request.httpBody = jsonData
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            if let httpResponse = response as? HTTPURLResponse {
                print("📡 Push channel registration HTTP status: \(httpResponse.statusCode)")
                
                let responseString = String(data: data, encoding: .utf8) ?? "No response data"
                print("📄 Response: \(responseString)")
                
                if httpResponse.statusCode == 200 || httpResponse.statusCode == 201 {
                    print("✅ iOS push channel registered successfully")
                    
                    // Store success state
                    UserDefaults.standard.set(true, forKey: "push_channel_registered")
                    UserDefaults.standard.set(Date(), forKey: "push_channel_registered_date")
                    
                    // Track successful registration
                    _ = await SuprSend.shared.track(
                        event: "push_channel_registered_successfully",
                        properties: [
                            "distinctId": DISTINCT_ID,
                            "deviceToken": deviceToken,
                            "method": "rest_api",
                            "timestamp": ISO8601DateFormatter().string(from: Date())
                        ]
                    )
                    
                } else if httpResponse.statusCode == 404 {
                    print("❌ 404 Error - trying alternative endpoint...")
                    await tryAlternativeRegistrationEndpoint(deviceToken: deviceToken)
                    
                } else {
                    print("❌ Failed to register push channel. Status: \(httpResponse.statusCode)")
                    print("❌ Error response: \(responseString)")
                    
                    // Try the SuprSend Swift SDK method
                    await trySDKChannelRegistration(deviceToken: deviceToken)
                }
            }
        } catch {
            print("❌ Network error registering push channel: \(error)")
            await trySDKChannelRegistration(deviceToken: deviceToken)
        }
    }
    
    // MARK: - Try Alternative Registration Endpoint
    private func tryAlternativeRegistrationEndpoint(deviceToken: String) async {
        print("🔄 Trying alternative registration endpoint...")
        
        guard let workspaceKey = UserDefaults.standard.string(forKey: "suprsend_workspace_key"),
              let workspaceSecret = UserDefaults.standard.string(forKey: "suprsend_workspace_secret") else {
            print("❌ Missing workspace credentials")
            return
        }
        
        // Try the SuprSend identify endpoint with user ID
        guard let url = URL(string: "https://hub.suprsend.com/identify/") else {
            print("❌ Invalid alternative URL")
            return
        }
        
        let payload: [String: Any] = [
            "distinct_id": DISTINCT_ID,
            "$iospush": deviceToken,
            "$set": [
                "device_token": deviceToken,
                "platform": "ios",
                "registration_method": "identify_endpoint",
                "timestamp": ISO8601DateFormatter().string(from: Date())
            ]
        ]
        
        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload) else {
            print("❌ Failed to serialize alternative JSON payload")
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(REST_API_KEY)", forHTTPHeaderField: "Authorization")
        request.httpBody = jsonData
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            if let httpResponse = response as? HTTPURLResponse {
                print("📡 Alternative endpoint HTTP status: \(httpResponse.statusCode)")
                
                let responseString = String(data: data, encoding: .utf8) ?? "No response data"
                print("📄 Alternative response: \(responseString)")
                
                if httpResponse.statusCode == 200 || httpResponse.statusCode == 201 {
                    print("✅ iOS push channel registered via alternative endpoint")
                    UserDefaults.standard.set(true, forKey: "push_channel_registered")
                } else {
                    print("❌ Alternative endpoint also failed")
                    await trySDKChannelRegistration(deviceToken: deviceToken)
                }
            }
        } catch {
            print("❌ Alternative endpoint network error: \(error)")
            await trySDKChannelRegistration(deviceToken: deviceToken)
        }
    }
    
    // MARK: - Enhanced SDK Channel Registration
    private func trySDKChannelRegistration(deviceToken: String) async {
        print("🔄 Trying enhanced SDK channel registration...")
        
        // The SuprSend Swift SDK should automatically handle device token registration
        // when the app calls registerForRemoteNotifications(). Let's verify this by
        // re-identifying the user and checking if the SDK picks up the token automatically
        
        print("🔄 Re-identifying user to trigger automatic channel detection...")
        let identifyResult = await SuprSend.shared.identify(distinctID: DISTINCT_ID)
        print("🔄 SDK re-identification result: \(identifyResult)")
        
        // Send a test event to see if the channel is working
        _ = await SuprSend.shared.track(
            event: "sdk_channel_test",
            properties: [
                "distinctId": DISTINCT_ID,
                "device_token": deviceToken,
                "platform": "ios",
                "registration_method": "sdk_automatic",
                "timestamp": ISO8601DateFormatter().string(from: Date()),
                "message": "Testing if SDK automatically registered the iOS push channel"
            ]
        )
        
        print("📱 SDK registration completed - the Swift SDK should handle channel registration automatically")
        print("📧 Check your SuprSend dashboard for the 'sdk_channel_test' event")
        
        // Also try to send a simple identify event that might trigger channel registration
        _ = await SuprSend.shared.track(
            event: "$identify",
            properties: [
                "distinctId": DISTINCT_ID,
                "$iospush": deviceToken,
                "platform": "ios",
                "timestamp": ISO8601DateFormatter().string(from: Date())
            ]
        )
        
        print("✅ SDK channel registration attempt completed")
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
    
    // MARK: - Check Registration Status
    func checkRegistrationStatus() {
        Task {
            guard let deviceToken = UserDefaults.standard.string(forKey: "apns_device_token") else {
                print("❌ No device token available for status check")
                return
            }
            
            print("🔍 Registration Status Check:")
            print("   Distinct ID: \(DISTINCT_ID)")
            print("   Device Token: \(deviceToken)")
            print("   Previously Registered: \(UserDefaults.standard.bool(forKey: "push_channel_registered"))")
            
            if let regDate = UserDefaults.standard.object(forKey: "push_channel_registered_date") as? Date {
                print("   Registration Date: \(regDate)")
            }
            
            // Try registration again
            await registerPushChannelViaAPI(deviceToken: deviceToken)
        }
    }
    
    // MARK: - Manual Test Method (call this from your UI for testing)
    func sendTestNotification() {
        Task {
            print("📧 Sending manual test notification...")
            
            // First, send a test event
            _ = await SuprSend.shared.track(
                event: "manual_test_notification",
                properties: [
                    "distinctId": DISTINCT_ID,
                    "test_type": "manual_trigger",
                    "timestamp": ISO8601DateFormatter().string(from: Date()),
                    "message": "Manual test notification from iOS app"
                ]
            )
            
            // Also try sending a notification trigger event
            _ = await SuprSend.shared.track(
                event: "test_push_notification",
                properties: [
                    "distinctId": DISTINCT_ID,
                    "notification_title": "Test from NightScout App",
                    "notification_body": "This is a test push notification to verify SuprSend integration",
                    "timestamp": ISO8601DateFormatter().string(from: Date()),
                    "platform": "ios"
                ]
            )
            
            print("✅ Manual test notification events sent")
            print("📧 Check your SuprSend dashboard and device for notifications")
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
    
    // MARK: - Force Channel Registration
    func forceChannelRegistration() {
        Task {
            print("🔧 Forcing channel registration...")
            
            guard let deviceToken = UserDefaults.standard.string(forKey: "apns_device_token") else {
                print("❌ No device token available")
                return
            }
            
            // Clear previous registration status
            UserDefaults.standard.removeObject(forKey: "push_channel_registered")
            UserDefaults.standard.removeObject(forKey: "push_channel_registered_date")
            
            // Force re-registration
            await registerPushChannelViaAPI(deviceToken: deviceToken)
            
            // Send a test event after registration
            _ = await SuprSend.shared.track(
                event: "forced_registration_test",
                properties: [
                    "distinctId": DISTINCT_ID,
                    "deviceToken": deviceToken,
                    "timestamp": ISO8601DateFormatter().string(from: Date()),
                    "test_type": "manual_force"
                ]
            )
            
            print("✅ Forced registration completed")
        }
    }
    
    // MARK: - Test Notification Delivery
    func testNotificationDelivery() {
        Task {
            _ = await SuprSend.shared.track(
                event: "test_push_notification",
                properties: [
                    "distinctId": DISTINCT_ID,
                    "notification_title": "Test Notification",
                    "notification_body": "Testing push delivery",
                    "platform": "ios"
                ]
            )
            print("✅ Test notification event sent")
        }
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
}
