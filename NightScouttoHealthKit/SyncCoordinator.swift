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
    func performSync() async throws {
        let syncStartTime = Date()
        print("🔄 Starting sync at: \(formatTime(syncStartTime)) (\(syncStartTime))")
        
        do {
            // Request HealthKit authorization
            print("🔐 Requesting HealthKit authorization...")
            try await healthKitManager.requestAuthorization()
            print("✅ HealthKit authorization granted")
            
            // Fetch the last 10 minutes of data from Nightscout
            print("📥 Fetching glucose data from Nightscout...")
            let entries = try await nightscoutService.fetchGlucoseData(minutes: 10)
            
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
            
            // Save to HealthKit
            print("💾 Saving entries to HealthKit...")
            try await healthKitManager.saveEntriesToHealthKit(entries)
            
            // Success!
            let syncDuration = Date().timeIntervalSince(syncStartTime)
            print("✅ Sync completed in \(String(format: "%.2f", syncDuration)) seconds")
            print("⏱️ Time: \(formatTime(Date()))")
            
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
                try await self.performSync()
            } catch {
                print("⚠️ Background sync failed: \(error)")
            }
        }
    }
}
