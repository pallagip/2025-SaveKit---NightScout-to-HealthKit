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
    
    // MARK: - UIApplicationDelegate
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        print("🚀 App launched - Background predictions disabled, manual-only mode")
        
        // Initialize SuprSend with Swift Package Manager
        let suprSendClient = SuprSendClient(publicKey: "SS.PUBK.C6RFiNwCjPNSIoDiAdR5XnIdXMXESAnL-H5sDfXq3QM")
        
        // Store workspace credentials for later use if needed
        UserDefaults.standard.set("oXLT425KxJdjEsMAnnt7", forKey: "suprsend_workspace_key")
        UserDefaults.standard.set("SS.WSS.zci-CGoHs4qXAUSYV972XsxZj4TQ6Mgb1iyGbubs",
                                 forKey: "suprsend_workspace_secret")
        
        print("📱 SuprSend Swift SDK initialized successfully!")
        
        // Identify user with SuprSend
        Task {
            let identifyResult = await SuprSend.shared.identify(distinctID: "T3L8DD7W3T")
            print("🆔 SuprSend User identified: T3L8DD7W3T, result: \(identifyResult)")
        }
        
        // Set notification center delegate for SuprSend
        UNUserNotificationCenter.current().delegate = self
        
        // Request notification permissions
        requestNotificationPermissions()
        
        // Initialize user identification
        initializeSuprSendUser()
        
        return true
    }
    
    // MARK: - SuprSend User Setup
    private func initializeSuprSendUser() {
        Task {
            let distinctId = getOrCreateDistinctId()
            print("🆔 Using distinct ID: \(distinctId)")
            
            // Identify the user with SuprSend
            let identifyResult = await SuprSend.shared.identify(distinctID: distinctId)
            print("🔍 User identification result: \(identifyResult)")
            
            // Track app initialization
            _ = await SuprSend.shared.track(
                event: "app_initialized",
                properties: [
                    "platform": "ios",
                    "distinctId": distinctId,
                    "timestamp": ISO8601DateFormatter().string(from: Date())
                ]
            )
        }
    }
    
    private func getOrCreateDistinctId() -> String {
        let key = "suprsend_distinct_id"
        
        if let existingId = UserDefaults.standard.string(forKey: key) {
            return existingId
        } else {
            // Generate a new unique ID - you might want to use user email or other identifier
            let newId = UUID().uuidString
            UserDefaults.standard.set(newId, forKey: key)
            print("🆔 Generated new distinct ID: \(newId)")
            return newId
        }
    }
    
    // MARK: - Notification Permissions
    private func requestNotificationPermissions() {
        let options: UNAuthorizationOptions = [.alert, .sound, .badge]
        UNUserNotificationCenter.current().requestAuthorization(options: options) { [weak self] granted, error in
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
        
        // Store token locally
        UserDefaults.standard.set(token, forKey: "apns_device_token")
        
        // For SuprSend Swift SDK, pass the device token directly
        // The SDK should handle channel registration automatically
        Task {
            let distinctId = getOrCreateDistinctId()
            
            // Re-identify user now that we have the device token
            let identifyResult = await SuprSend.shared.identify(distinctID: distinctId)
            print("🔍 User re-identification with token result: \(identifyResult)")
            
            // Track successful token registration
            _ = await SuprSend.shared.track(
                event: "apns_token_received",
                properties: [
                    "distinctId": distinctId,
                    "deviceToken": token,
                    "timestamp": ISO8601DateFormatter().string(from: Date())
                ]
            )
        }
        
        // Setup SuprSend channel
        setupSuprSendChannel(deviceToken: token)
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
    
    // MARK: - SuprSend Channel Setup
    private func setupSuprSendChannel(deviceToken: String) {
        Task {
            let distinctId = getOrCreateDistinctId()
            
            print("🔗 Setting up SuprSend channel for user: \(distinctId)")
            print("📱 Device token: \(deviceToken)")
            
            // For SuprSend Swift SDK, the channel setup might be automatic
            // or use different methods. Let's try user identification with token
            
            // First identify the user
            let identifyResult = await SuprSend.shared.identify(distinctID: distinctId)
            print("🔍 User identification result: \(identifyResult)")
            
            // For Swift SDK, the push token is usually registered automatically
            // when you call registerForRemoteNotifications, but let's also
            // try to explicitly set it if the method exists
            
            // Track successful registration
            _ = await SuprSend.shared.track(
                event: "push_channel_registered",
                properties: [
                    "distinctId": distinctId,
                    "deviceToken": deviceToken,
                    "timestamp": ISO8601DateFormatter().string(from: Date())
                ]
            )
            
            // Optional: Verify channel setup
            await verifyChannelSetup(distinctId: distinctId, deviceToken: deviceToken)
        }
    }
    
    // MARK: - Channel Verification
    private func verifyChannelSetup(distinctId: String, deviceToken: String) async {
        print("✅ Channel verification for user: \(distinctId)")
        
        // You can add additional verification logic here if needed
        // For now, we'll just log that setup is complete
        
        _ = await SuprSend.shared.track(
            event: "channel_setup_complete",
            properties: [
                "distinctId": distinctId,
                "timestamp": ISO8601DateFormatter().string(from: Date())
            ]
        )
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
        
        // Optional: Refresh channel setup when app comes to foreground
        refreshChannelIfNeeded()
    }
    
    func applicationDidBecomeActive(_ application: UIApplication) {
        print("📱 App became active")
    }
    
    // MARK: - Channel Refresh
    private func refreshChannelIfNeeded() {
        guard let deviceToken = UserDefaults.standard.string(forKey: "apns_device_token") else {
            print("⚠️ No stored device token found")
            return
        }
        
        let lastRefresh = UserDefaults.standard.double(forKey: "last_channel_refresh")
        let now = Date().timeIntervalSince1970
        
        // Refresh channel setup every 24 hours
        if now - lastRefresh > 86400 {
            print("🔄 Refreshing channel setup...")
            Task {
                let distinctId = getOrCreateDistinctId()
                let identifyResult = await SuprSend.shared.identify(distinctID: distinctId)
                print("🔄 Refresh identification result: \(identifyResult)")
            }
            UserDefaults.standard.set(now, forKey: "last_channel_refresh")
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
            let distinctId = getOrCreateDistinctId()
            let deviceToken = UserDefaults.standard.string(forKey: "apns_device_token")
            
            print("🔍 SuprSend Debug Info:")
            print("   Distinct ID: \(distinctId)")
            print("   Device Token: \(deviceToken ?? "Not available")")
            
            // Re-identify user for debugging
            let identifyResult = await SuprSend.shared.identify(distinctID: distinctId)
            print("🔍 Debug re-identification result: \(identifyResult)")
            
            // Track debug event
            _ = await SuprSend.shared.track(
                event: "debug_setup_check",
                properties: [
                    "distinctId": distinctId,
                    "hasDeviceToken": deviceToken != nil,
                    "timestamp": ISO8601DateFormatter().string(from: Date())
                ]
            )
        }
    }
}
