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
                    // Request notification permissions
                    appDelegate.requestNotificationPermissions()
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
        do {
            // Approach 1: Initialize with public key only
            let suprSendClient = SuprSendClient(publicKey: "SS.PUBK.C6RFiNwCjPNSIoDiAdR5XnIdXMXESAnL-H5sDfXq3QM")
            
            // Store workspace credentials for later use if needed
            UserDefaults.standard.set("oXLT425KxJdjEsMAnnt7", forKey: "suprsend_workspace_key")
            UserDefaults.standard.set("SS.WSS.zci-CGoHs4qXAUSYV972XsxZj4TQ6Mgb1iyGbubs",
                                     forKey: "suprsend_workspace_secret")
        } catch {
            print("❌ SuprSend initialization error: \(error)")
        }
        
        print("📱 SuprSend Swift SDK initialized successfully!")
        
        // Track initialization event
        Task {
            await SuprSend.shared.track(event: "app_initialized",
                                      properties: ["channels": ["iospush"]])
        }
        
        // Set notification center delegate for SuprSend
        UNUserNotificationCenter.current().delegate = self
        
        // Register for push notifications
        let options: UNAuthorizationOptions = [.alert, .sound, .badge]
        UNUserNotificationCenter.current().requestAuthorization(options: options) { granted, error in
            if let error = error {
                print("Notification permission error: \(error)")
                return
            }
            
            if granted {
                DispatchQueue.main.async {
                    UIApplication.shared.registerForRemoteNotifications()
                }
            }
        }
        
        return true
    }
    
    // MARK: - Background Task Registration (Disabled)
    // Background prediction tasks have been disabled - predictions are now manual-only
    private func getModelContainer() -> ModelContainer {
        do {
            return try ModelContainer(for: Prediction.self, MultiModelPrediction.self, HealthKitBGCache.self, WorkoutTimeData.self)
        } catch {
            fatalError("Failed to create ModelContainer for background task: \(error)")
        }
    }
    
    // MARK: - Background App Refresh
    func applicationDidEnterBackground(_ application: UIApplication) {
        print("📱 App entered background")
    }
    
    func applicationWillEnterForeground(_ application: UIApplication) {
        print("📱 App entering foreground")
    }
    
    func applicationDidBecomeActive(_ application: UIApplication) {
        print("📱 App became active")
    }
    
    // MARK: - APNs Token Handling
    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task {
            let token = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
            print("📬 APNs Token: \(token)")
            
            // Store token locally for backup
            UserDefaults.standard.set(token, forKey: "apns_device_token")
            
            // Track notification registration event
            await SuprSend.shared.track(event: "notification_registered",
                                      properties: ["deviceToken": token])
        }
    }
    
    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Task {
            print("❌ Failed to register for remote notifications: \(error)")
            await SuprSend.shared.track(event: "notification_registration_failed",
                                      properties: ["error": error.localizedDescription])
        }
    }
    
    // MARK: - Background Notification Handling
    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        Task {
            print("📥 Received remote notification: \(userInfo)")
            
            // Track notification delivery
            await SuprSend.shared.track(event: "notification_delivered",
                                      properties: ["userInfo": userInfo])
            
            completionHandler(.noData)
        }
    }
    
    // MARK: - UNUserNotificationCenterDelegate
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                               willPresent notification: UNNotification,
                               withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        Task {
            print("📱 Foreground notification: \(notification.request.content.title)")
            
            // Track notification presentation
            await SuprSend.shared.track(event: "notification_presented",
                                      properties: ["title": notification.request.content.title])
            
            completionHandler([.alert, .badge, .sound])
        }
    }
    
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                               didReceive response: UNNotificationResponse,
                               withCompletionHandler completionHandler: @escaping () -> Void) {
        Task {
            print("👆 Notification tapped: \(response.notification.request.content.title)")
            
            // Track notification interaction
            await SuprSend.shared.track(event: "notification_tapped",
                                      properties: ["title": response.notification.request.content.title])
            
            completionHandler()
        }
    }
}
