//
//  NightScoutToHealthKitApp.swift
//  NightScoutToHealthKit Watch App
//
//  Created by Patrick Pallagi on 2025-07-29.
//

import SwiftUI
import UserNotifications

@main
struct NightScoutToHealthKit_Watch_AppApp: App {
    
    init() {
        // Initialize WatchConnectivityManager and request permissions
        _ = WatchConnectivityManager.shared
        
        // Request notification permissions for the watch
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if granted {
                print("✅ Watch notification permissions granted")
            } else {
                print("❌ Watch notification permissions denied: \(error?.localizedDescription ?? "Unknown error")")
            }
        }
        
        print("🔗 Watch app initialized")
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
