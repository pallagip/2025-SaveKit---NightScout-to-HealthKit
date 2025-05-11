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

// The task identifier must match your Info.plist BGTaskSchedulerPermittedIdentifiers entry:
fileprivate let refreshTaskID = "com.ProDiabeticsTeam.NightScouttoHealthKit.refresh"

@main
struct NightScouttoHealthKitApp: App {
    // Hook our AppDelegate in for BackgroundTasks callbacks
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .modelContainer(for: [Item.self])
        }
    }
}

class AppDelegate: UIResponder, UIApplicationDelegate {
    /// 1) Register our BGAppRefreshTask when the app launches:
    func application(_ application: UIApplication,
                    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
        // Register your launch handler for BGAppRefreshTask
        BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshTaskID, using: nil) { task in
            self.handleAppRefresh(task: task as! BGAppRefreshTask)
        }
        // Kick off our first schedule
        scheduleAppRefresh()
        return true
    }
    
    /// 2) Schedule a refresh no earlier than 6 minutes from now
    func scheduleAppRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 6 * 60) // 6 minutes
        #if !targetEnvironment(simulator)
        do {
            try BGTaskScheduler.shared.submit(request)
            // Persist next sync date for UI countdown
            UserDefaults.standard.set(request.earliestBeginDate, forKey: "nextSyncDate")
        } catch {
            print("❌ BGTaskScheduler failed to submit: \(error)")
        }
        #else
        print("Skipping BGTaskScheduler on Simulator")
        #endif
    }
    
    /// 3) Handle the refresh when the system wakes us up
    func handleAppRefresh(task: BGAppRefreshTask) {
        // Always schedule the next one
        scheduleAppRefresh()
        
        // Pull the saved URL & token out of UserDefaults (same keys as your ContentView)
        let defaults = UserDefaults.standard
        guard
            let urlString = defaults.string(forKey: "nightscoutBaseURL"),
            let baseURL = URL(string: urlString),
            let apiSecret = defaults.string(forKey: "apiSecret"),
            let apiToken = defaults.string(forKey: "apiToken"),
            !apiSecret.isEmpty,
            !apiToken.isEmpty
        else {
            print("⚠️ Nightscout URL or API secret/token missing – skipping sync")
            task.setTaskCompleted(success: false)
            return
        }
        
        // Create your coordinator with the live config
        let coordinator = SyncCoordinator(
            nightscoutService: NightscoutService(
                baseURL: baseURL,
                apiSecret: apiSecret,
                apiToken: apiToken
            ),
            healthKitManager: HealthKitManager()
        )
        
        // Wrap your async work in a Task so you can cancel if the OS needs the time back
        let work = Task {
            do {
                try await coordinator.performSync()
                task.setTaskCompleted(success: true)
            } catch {
                print("⚠️ Background sync failed: \(error)")
                task.setTaskCompleted(success: false)
            }
        }
        
        // If iOS needs to terminate your work early, cancel the Task
        task.expirationHandler = {
            work.cancel()
        }
    }
}

// Simple SwiftData model for storing items in the UI
@Model
final class Item: Identifiable {
    @Attribute(.unique) var id: UUID = UUID()
    var title: String
    init(title: String) {
        self.title = title
    }
}
