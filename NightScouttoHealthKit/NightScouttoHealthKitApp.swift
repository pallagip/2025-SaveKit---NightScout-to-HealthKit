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
    
    // Your SuprSend public key (keep this as is)
    private let SUPRSEND_PUBLIC_KEY = "SS.PUBK.61Q4tamBoI9nsScOlZPqNyHPzrIUTGn18cctxwqXAdE"
    
    // SuprSend REST API credentials for explicit channel registration
    private let REST_API_KEY = "SS.9yalT5kZe5R7L3ltb_gz-YGdyEMisMcqqAUEJHzMYA0"
    private let CHANNEL_ID = "oMaufwD5u3DD5M83WhmOaAbz1bYc22AJKX5Z-fQuC2k"
    
    // MARK: - UIApplicationDelegate
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        print("🚀 App launched - Background predictions disabled, manual-only mode")
        
        // Initialize SuprSend with Swift Package Manager
        _ = SuprSendClient(publicKey: SUPRSEND_PUBLIC_KEY)
        
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
            
            // Step 2: Explicitly register the iOS push channel via REST API
            // The SDK's automatic registration isn't reliable, so we'll do it manually
            await registerPushChannelExplicitly(deviceToken: deviceToken)
            
            // Step 3: Track the setup event
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
            
            // Step 4: Test the setup immediately
            await testNotificationSetup()
        }
    }
    
    // MARK: - Explicit Push Channel Registration
    private func registerPushChannelExplicitly(deviceToken: String) async {
        print("📡 Explicitly registering iOS push channel via REST API...")
        
        // Corrected URL format for SuprSend API
        guard let url = URL(string: "https://api.suprsend.com/v1/users/\(DISTINCT_ID)") else {
            print("❌ Invalid URL for channel registration")
            return
        }
        
        // Create the payload with both push channel and app inbox using the same channel ID
        let payload: [String: Any] = [
            "$set": [
                "$iospush": CHANNEL_ID,
                "$app_inbox": CHANNEL_ID,
                "device_token": deviceToken,
                "platform": "ios",
                "app_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
                "last_seen": ISO8601DateFormatter().string(from: Date())
            ]
        ]
        
        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload, options: .prettyPrinted) else {
            print("❌ Failed to serialize channel registration JSON payload")
            return
        }
        
        if let jsonString = String(data: jsonData, encoding: .utf8) {
            print("📤 Sending channel registration payload: \(jsonString)")
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"  // Changed from POST to PUT
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(REST_API_KEY)", forHTTPHeaderField: "Authorization")
        request.httpBody = jsonData
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            if let httpResponse = response as? HTTPURLResponse {
                print("📡 Channel registration HTTP status: \(httpResponse.statusCode)")
                
                let responseString = String(data: data, encoding: .utf8) ?? "No response data"
                print("📄 Channel registration response: \(responseString)")
                
                if httpResponse.statusCode == 200 || httpResponse.statusCode == 201 {
                    print("✅ iOS push channel and App Inbox registered successfully")
                    
                    // Store success state
                    UserDefaults.standard.set(true, forKey: "push_channel_registered")
                    UserDefaults.standard.set(Date(), forKey: "push_channel_registered_date")
                    
                    // Track successful registration
                    _ = await SuprSend.shared.track(
                        event: "push_channel_registered_successfully",
                        properties: [
                            "distinctId": DISTINCT_ID,
                            "deviceToken": deviceToken,
                            "channelId": CHANNEL_ID,
                            "method": "explicit_rest_api",
                            "timestamp": ISO8601DateFormatter().string(from: Date())
                        ]
                    )
                } else {
                    print("❌ Failed to register push channel. Status: \(httpResponse.statusCode)")
                    print("❌ Error response: \(responseString)")
                    
                    // Try alternative endpoint
                    print("🔄 Trying alternative event endpoint...")
                    await tryEventEndpointRegistration(deviceToken: deviceToken)
                }
            }
        } catch {
            print("❌ Network error registering push channel: \(error)")
        }
    }
    
    // MARK: - Alternative Event Endpoint Registration
    private func tryEventEndpointRegistration(deviceToken: String) async {
        print("🔄 Trying event endpoint for channel registration...")
        
        guard let url = URL(string: "https://hub.suprsend.com/event/") else {
            print("❌ Invalid event endpoint URL")
            return
        }
        
        // Create an $identify event payload
        let payload: [String: Any] = [
            "event": "$identify",
            "distinct_id": DISTINCT_ID,
            "properties": [
                "$set": [
                    "$iospush": CHANNEL_ID,
                    "$app_inbox": CHANNEL_ID,
                    "device_token": deviceToken,
                    "platform": "ios",
                    "app_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
                    "timestamp": ISO8601DateFormatter().string(from: Date())
                ]
            ]
        ]
        
        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload, options: .prettyPrinted) else {
            print("❌ Failed to serialize event endpoint JSON payload")
            return
        }
        
        if let jsonString = String(data: jsonData, encoding: .utf8) {
            print("📤 Sending event endpoint payload: \(jsonString)")
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(REST_API_KEY)", forHTTPHeaderField: "Authorization")
        request.httpBody = jsonData
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            if let httpResponse = response as? HTTPURLResponse {
                print("📡 Event endpoint HTTP status: \(httpResponse.statusCode)")
                
                let responseString = String(data: data, encoding: .utf8) ?? "No response data"
                print("📄 Event endpoint response: \(responseString)")
                
                if httpResponse.statusCode == 200 || httpResponse.statusCode == 201 {
                    print("✅ Channel registered successfully via event endpoint")
                    
                    // Store success state
                    UserDefaults.standard.set(true, forKey: "push_channel_registered")
                    UserDefaults.standard.set(Date(), forKey: "push_channel_registered_date")
                    
                    // Track successful registration
                    _ = await SuprSend.shared.track(
                        event: "push_channel_registered_via_event_endpoint",
                        properties: [
                            "distinctId": DISTINCT_ID,
                            "deviceToken": deviceToken,
                            "channelId": CHANNEL_ID,
                            "method": "event_endpoint",
                            "timestamp": ISO8601DateFormatter().string(from: Date())
                        ]
                    )
                } else {
                    print("❌ Event endpoint also failed. Status: \(httpResponse.statusCode)")
                    print("❌ Event endpoint error: \(responseString)")
                    
                    // As a last resort, rely on the Swift SDK's built-in registration
                    print("📱 Falling back to Swift SDK automatic registration...")
                }
            }
        } catch {
            print("❌ Network error with event endpoint: \(error)")
            print("📱 Falling back to Swift SDK automatic registration...")
        }
    }
    
    // MARK: - Test Notification Setup
    private func testNotificationSetup() async {
        print("🧪 Testing notification setup...")
        
        // Send a test event specifically for iOS push notifications
        _ = await SuprSend.shared.track(
            event: "notification_setup_test",
            properties: [
                "distinctId": DISTINCT_ID,
                "channels": ["iospush"],  // Use iospush channel specifically
                "setup_time": ISO8601DateFormatter().string(from: Date()),
                "test_message": "This is a test to verify iOS push notification channel setup"
            ]
        )
        
        print("📧 Test event sent for iOS push notifications - check SuprSend dashboard for delivery")
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
    
    // MARK: - Manual Test Method (call this from your UI for testing)
    func sendTestNotification() {
        Task {
            print("📧 Sending manual test notification...")
            
            // Send a test event that should trigger a push notification
            _ = await SuprSend.shared.track(
                event: "manual_test_notification",
                properties: [
                    "distinctId": DISTINCT_ID,
                    "test_type": "manual_trigger",
                    "timestamp": ISO8601DateFormatter().string(from: Date()),
                    "message": "Manual test notification from iOS app"
                ]
            )
            
            print("✅ Manual test notification events sent")
            print("📧 Check your SuprSend dashboard and device for notifications")
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
            
            // Re-identify user to ensure channel registration
            let identifyResult = await SuprSend.shared.identify(distinctID: DISTINCT_ID)
            print("🔄 Re-identification result: \(identifyResult)")
            
            // Send test event
            _ = await SuprSend.shared.track(
                event: "registration_status_check",
                properties: [
                    "distinctId": DISTINCT_ID,
                    "deviceToken": deviceToken,
                    "timestamp": ISO8601DateFormatter().string(from: Date())
                ]
            )
            
            print("✅ Registration status check completed")
        }
    }
    
    // MARK: - Force User Channel Registration
    func forceUserChannelRegistration() {
        Task {
            guard let deviceToken = UserDefaults.standard.string(forKey: "apns_device_token") else {
                print("❌ No device token available")
                return
            }
            
            print("🔧 Forcing user channel registration...")
            
            // Step 1: Re-identify the user
            let identifyResult = await SuprSend.shared.identify(distinctID: DISTINCT_ID)
            print("🆔 Forced identification result: \(identifyResult)")
            
            // Step 2: Explicitly register the push channel
            await registerPushChannelExplicitly(deviceToken: deviceToken)
            
            // Wait a moment then send test event
            try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
            
            _ = await SuprSend.shared.track(
                event: "forced_channel_registration_test",
                properties: [
                    "distinctId": DISTINCT_ID,
                    "deviceToken": deviceToken,
                    "timestamp": ISO8601DateFormatter().string(from: Date()),
                    "test_type": "manual_force_registration"
                ]
            )
            
            print("✅ Forced registration completed")
        }
    }
}
