//
//  SyncCoordinator.swift
//  NightScouttoHealthKit
//
//  Created by Patrick Pallagi on 2025-05-09.

import Foundation

// Define a custom error type for sync operations
enum SyncError: Error {
    case healthKitAuthorizationFailed(Error)
    case dataFetchFailed(Error)
    case healthKitSaveFailed(Error)
    case noDataAvailable
    
    var localizedDescription: String {
        switch self {
        case .healthKitAuthorizationFailed(let error):
            return "HealthKit authorization failed: \(error.localizedDescription)"
        case .dataFetchFailed(let error):
            return "Nightscout data fetch failed: \(error.localizedDescription)"
        case .healthKitSaveFailed(let error):
            return "Saving to HealthKit failed: \(error.localizedDescription)"
        case .noDataAvailable:
            return "No recent glucose data available from Nightscout"
        }
    }
}

class SyncCoordinator {
    private let nightscoutService: NightscoutService
    private let healthKitManager: HealthKitManager
    
    init(nightscoutService: NightscoutService,
         healthKitManager: HealthKitManager) {
        self.nightscoutService = nightscoutService
        self.healthKitManager = healthKitManager
    }
    
    /// Performs the full sync process with detailed logging
    /// - Parameter minutes: Number of minutes of data to fetch (default: 25)
    /// - Returns: Number of new entries that were saved to HealthKit
    func performSync(minutes: Int = 25) async throws -> Int {
        let syncStartTime = Date()
        print("🔄 Starting sync at: \(formatTime(syncStartTime)) (\(syncStartTime))")
        
        do {
            // Request HealthKit authorization
            print("🔐 Requesting HealthKit authorization...")
            try await healthKitManager.requestAuthorization()
            print("✅ HealthKit authorization granted")
            
            // Fetch glucose data from Nightscout with specified time window
            print("📥 Fetching \(minutes) minutes of glucose data from Nightscout...")
            let entries = try await nightscoutService.fetchGlucoseData(minutes: minutes)
            
            // Check if we have data
            guard !entries.isEmpty else {
                print("⚠️ No glucose data available in the specified time range")
                throw SyncError.noDataAvailable
            }
            
            // Log what we found
            print("📊 Fetched \(entries.count) entries")
            
            if let firstEntry = entries.first, let lastEntry = entries.last {
                print("🕒 Earliest entry: \(formatTime(firstEntry.date)) - \(Int(firstEntry.sgv)) mg/dL")
                print("🕒 Latest entry: \(formatTime(lastEntry.date)) - \(Int(lastEntry.sgv)) mg/dL")
            }
            
            // Save to HealthKit and get count of newly saved entries
            print("💾 Saving entries to HealthKit...")
            let savedCount = try await healthKitManager.saveEntriesToHealthKit(entries)
            
            // Success!
            let syncDuration = Date().timeIntervalSince(syncStartTime)
            print("✅ Sync completed in \(String(format: "%.2f", syncDuration)) seconds")
            print("⏱️ Time: \(formatTime(Date()))")
            print("📊 Saved \(savedCount) new entries to HealthKit")
            
            // Return count of saved entries
            return savedCount
            
        } catch {
            // Enhanced error logging
            let syncDuration = Date().timeIntervalSince(syncStartTime)
            print("❌ Sync failed after \(String(format: "%.2f", syncDuration)) seconds")
            print("⚠️ Error details: \(error)")
            
            // Forward the error with our custom wrapper
            if let syncError = error as? SyncError {
                throw syncError
            } else if let urlError = error as? URLError {
                throw SyncError.dataFetchFailed(urlError)
            } else {
                throw SyncError.dataFetchFailed(error)
            }
            
            // If we get here, no entries were saved
            return 0
        }
    }
    
    /// Formats a date nicely for logs
    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: date)
    }
    
    /// If you still want a non-async "kickoff" (e.g. from UI),
    /// you can leave this around or remove it:
    func startBackgroundSync() {
        Task.detached(priority: .background) {
            do {
                _ = try await self.performSync()
            } catch {
                print("⚠️ Background sync failed: \(error)")
            }
        }
    }
}
