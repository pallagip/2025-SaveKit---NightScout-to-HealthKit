//
//  SyncManager.swift
//  NightScouttoHealthKit
//
//  Created by Patrick Pallagi on 2025-05-13.
//  Rewritten by ChatGPT on 2025-05-16.
//

import Foundation
import BackgroundTasks
import UIKit

/// Central manager that keeps Nightscout → HealthKit in sync
final class SyncManager {
    // MARK: - Singleton

    static let shared = SyncManager()
    private init() {
        // No background observers needed for manual sync only
    }



    // MARK: - Configuration

    /// How often (at minimum) we want to sync
    private let syncInterval: TimeInterval = 60 * 60 // 60 minutes

    /// Identifiers must match those you register in AppDelegate
    private let refreshTaskId = "com.ProDiabeticsTeam.NightScouttoHealthKitv1"
    private let processingTaskId = "com.ProDiabeticsTeam.NightScouttoHealthKitv1.processing"

    // MARK: - State Tracking

    /// Last successful sync timestamp persisted so it survives relaunch
    private var lastSyncDate: Date? {
        get { UserDefaults.standard.object(forKey: "lastSyncDate") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "lastSyncDate") }
    }
    
    /// Time interval since the last successful sync
    var timeSinceLastSync: TimeInterval {
        guard let last = lastSyncDate else { return .infinity }
        return Date().timeIntervalSince(last)
    }



    // MARK: - Public API

    /// Call once at app startup (e.g. in AppDelegate) to kick everything off

    
    /// Start the foreground timer if it's not already running




    // MARK: - Core Sync Logic

    /// Trigger a sync. Returns number of new entries (if you care).
    /// - Parameters:
    ///   - isBackground: Whether this sync is being performed in background mode
    ///   - extended: Whether to perform an extended sync
    ///   - minutes: Custom time window in minutes to fetch data for (overrides default behavior)
    /// - Returns: Number of new entries saved to HealthKit
    @discardableResult
    func performSync(isBackground: Bool, extended: Bool = false, minutes: Int? = nil) async -> Int {
        do {
            let coordinator = makeCoordinator()
            
            // Use custom minutes if provided, otherwise use default logic
            let lookbackMinutes: Int
            if let minutes = minutes {
                lookbackMinutes = minutes
            } else {
                lookbackMinutes = isBackground ? 120 : 60
            }
            
            let result = try await coordinator.performSync(minutes: lookbackMinutes)
            return result.newEntries
        } catch {
            print("Sync failed: \(error)")
            return 0
        }
    }

    private func makeCoordinator() -> SyncCoordinator {
        let defs   = UserDefaults.standard
        let base   = defs.string(forKey: "nightscoutBaseURL") ?? ""
        let url    = URL(string: base) ?? URL(string: "https://example.com")!
        let secret = defs.string(forKey: "apiSecret") ?? ""
        let token  = defs.string(forKey: "apiToken") ?? ""

        let service = NightscoutService(baseURL: url, apiSecret: secret, apiToken: token)
        return SyncCoordinator(nightscoutService: service,
                               healthKitManager: HealthKitManager())
    }
}

// MARK: - Sync Timer Notification

extension Notification.Name {
    /// Fired whenever the next‐sync countdown or lastSyncDate has changed
    static let syncTimerUpdated = Notification.Name("syncTimerUpdated")
}
