//
// NightScouttoHealthKitApp.swift
// NightScouttoHealthKit
//
// Created by Patrick Pallagi on 2025-05-09.
//

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

final class AppDelegate: UIResponder, UIApplicationDelegate {
    // MARK: - UIApplicationDelegate

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Initialize medical device background execution (multiple strategies)
        MedicalBackgroundManager.shared.initializeMedicalBackgroundExecution()
        
        // Register background task handlers
        registerBackgroundTasks()
        
        // Schedule initial background tasks
        NotificationManager.shared.scheduleBackgroundTasks()
        
        print("🚀 App launched - Notification and background task system initialized")
        
        return true
    }
    
    // MARK: - Background Task Registration
    
    private func registerBackgroundTasks() {
        // Register background app refresh task
        BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshTaskID, using: nil) { task in
            print("🔄 Background app refresh task fired")
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            
            // Get the shared model container from the app
            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
               let window = windowScene.windows.first,
               let contentView = window.rootViewController?.view.subviews.first {
                // Access model container through the app's scene
                let modelContainer = self.getModelContainer()
                NotificationManager.shared.handleBackgroundAppRefresh(task: refreshTask, modelContainer: modelContainer)
            } else {
                print("❌ Failed to get model container for background refresh")
                task.setTaskCompleted(success: false)
            }
        }
        
        // Register background processing task
        BGTaskScheduler.shared.register(forTaskWithIdentifier: processingTaskID, using: nil) { task in
            print("⚙️ Background processing task fired")
            guard let processingTask = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            
            // Get the shared model container from the app
            let modelContainer = self.getModelContainer()
            NotificationManager.shared.handleBackgroundProcessing(task: processingTask, modelContainer: modelContainer)
        }
        
        print("✅ Background tasks registered for identifiers: \(refreshTaskID), \(processingTaskID)")
    }
    
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
        
        // Check if we missed any scheduled prediction times while inactive
        if NotificationHandler.shared.isScheduledPredictionTime() {
            print("⏰ App became active during scheduled prediction time - checking for missed predictions")
        }
    }

}

// Background tasks are configured in AppDelegate per the memory about continuous sync
