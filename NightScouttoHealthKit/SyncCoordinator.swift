//
//  SyncCoordinator.swift
//  NightScouttoHealthKit
//
//  Created by Patrick Pallagi on 2025-05-09.

import Foundation
import SwiftData

// Result structure for sync operations
struct SyncResult {
    let newEntries: Int
    let totalFetched: Int
    let message: String
}

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
    
    // Default constructor for background usage
    init() {
        let defs = UserDefaults.standard
        let base = defs.string(forKey: "nightscoutBaseURL") ?? "https://example.com"
        let url = URL(string: base) ?? URL(string: "https://example.com")!
        let secret = defs.string(forKey: "apiSecret") ?? ""
        let token = defs.string(forKey: "apiToken") ?? ""
        self.nightscoutService = NightscoutService(baseURL: url, apiSecret: secret, apiToken: token)
        self.healthKitManager = HealthKitManager()
    }
    
    init(nightscoutService: NightscoutService,
         healthKitManager: HealthKitManager) {
        self.nightscoutService = nightscoutService
        self.healthKitManager = healthKitManager
    }
    
    /// Performs the full sync process with detailed logging
    /// - Parameter minutes: Number of minutes of data to fetch (default: 25)
    /// - Returns: SyncResult with details about the sync operation
    func performSync(minutes: Int = 25) async throws -> SyncResult {
        let syncStartTime = Date()
        let utcFormatter = ISO8601DateFormatter()
        utcFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        print("🔄 Starting sync at: \(formatTime(syncStartTime)) (Local) | \(utcFormatter.string(from: syncStartTime)) (UTC)")
        
        do {
            // Request HealthKit authorization
            print("🔐 Requesting HealthKit authorization...")
            try await healthKitManager.requestAuthorization()
            print("✅ HealthKit authorization granted")
            
            // Clean up any remaining future-dated samples from previous bugs
            _ = try? await healthKitManager.deleteFutureGlucoseSamples()
            
            // Determine the sync window (catch-up if needed)
            var fetchMinutes = minutes
            if let latestDate = await healthKitManager.fetchLatestGlucoseDate() {
                let minutesSinceLastSync = Int(Date().timeIntervalSince(latestDate) / 60)
                if minutesSinceLastSync > minutes {
                    fetchMinutes = min(minutesSinceLastSync + 5, 2880) // Fetch up to 48 hours catch-up
                    print("🔄 Catch-up sync: Fetching \(fetchMinutes) minutes to cover gap since \(latestDate)")
                }
            } else {
                // If HealthKit is empty, fetch a larger window (24 hours) to get started
                fetchMinutes = max(minutes, 1440)
                print("🔄 Fresh sync: Fetching \(fetchMinutes) minutes as HealthKit is empty or has no glucose data")
            }
            
            // Fetch glucose data from Nightscout
            print("📥 Fetching \(fetchMinutes) minutes of glucose data from Nightscout...")
            let entries = try await nightscoutService.fetchGlucoseData(minutes: fetchMinutes)
            
            // Check if we have data
            guard !entries.isEmpty else {
                print("⚠️ No glucose data available in the specified time range")
                throw SyncError.noDataAvailable
            }
            
            // Log what we found
            print("📊 Fetched \(entries.count) entries")
            
            if let firstEntry = entries.first, let lastEntry = entries.last {
                print("🕒 Latest entry: \(formatTime(firstEntry.date)) - \(Int(firstEntry.sgv)) mg/dL")
                print("🕒 Earliest entry: \(formatTime(lastEntry.date)) - \(Int(lastEntry.sgv)) mg/dL")
            }
            
            // Save to HealthKit and get count of newly saved entries
            print("💾 Saving entries to HealthKit...")
            let savedCount = try await healthKitManager.saveEntriesToHealthKit(entries)
            
            // Success!
            let syncDuration = Date().timeIntervalSince(syncStartTime)
            print("✅ Sync completed in \(String(format: "%.2f", syncDuration)) seconds")
            print("⏱️ Time: \(formatTime(Date()))")
            print("📊 Saved \(savedCount) new entries to HealthKit")
            
            // Return result with saved entries
            return SyncResult(
                newEntries: savedCount,
                totalFetched: entries.count,
                message: "Successfully saved \(savedCount) new entries to HealthKit"
            )
            
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
    
    /// Performs sync from Nightscout server directly to SwiftData cache (bypasses HealthKit)
    /// - Parameters:
    ///   - minutes: Number of minutes of data to fetch (default: 1440 for 24 hours)
    ///   - modelContext: SwiftData model context for saving cached data
    /// - Returns: SyncResult with details about the sync operation
    func syncWithoutHealthKit(minutes: Int = 1440, modelContext: ModelContext) async throws -> SyncResult {
        let syncStartTime = Date()
        print("🌐 Starting server-to-cache sync at: \(formatTime(syncStartTime))")
        print("🚫 Bypassing HealthKit - saving directly to SwiftData cache")
        
        do {
            // Fetch glucose data from Nightscout with specified time window
            print("📥 Fetching \(minutes) minutes of glucose data from Nightscout server...")
            let entries = try await nightscoutService.fetchGlucoseData(minutes: minutes)
            
            // --- NEW: Intra-batch Deduplication (2.5-minute window) ---
            let sortedEntries = entries.sorted { $0.date < $1.date }
            var deduplicatedBatch = [Entry]()
            for entry in sortedEntries {
                if let lastKept = deduplicatedBatch.last {
                    if entry.date.timeIntervalSince(lastKept.date) < 150 {
                        if lastKept._id == nil && entry._id != nil {
                            deduplicatedBatch[deduplicatedBatch.count - 1] = entry
                        }
                        continue
                    }
                }
                deduplicatedBatch.append(entry)
            }
            let entriesToProcess = deduplicatedBatch
            // ---------------------------------------------------------
            
            // Check if we have data after deduplication
            guard !entriesToProcess.isEmpty else {
                print("⚠️ No glucose data available after intra-batch deduplication")
                return SyncResult(
                    newEntries: 0,
                    totalFetched: entries.count,
                    message: "No new data after deduplication"
                )
            }
            
            // Log what we found
            print("📊 Fetched \(entries.count) entries from server (\(entriesToProcess.count) after intra-batch deduplication)")
            
            if let firstEntry = entries.first, let lastEntry = entries.last {
                print("🕒 Latest entry: \(formatTime(firstEntry.date)) - \(Int(firstEntry.sgv)) mg/dL")
                print("🕒 Earliest entry: \(formatTime(lastEntry.date)) - \(Int(lastEntry.sgv)) mg/dL")
            }
            
            // Save entries directly to SwiftData cache
            print("💾 Saving entries to SwiftData cache...")
            
            var savedCount = 0
            var skippedCount = 0
            
            for entry in entriesToProcess {
                // Check if entry already exists in cache using a 2.5-minute window
                let entryTimestamp = entry.date.timeIntervalSince1970
                let startDate = Date(timeIntervalSince1970: entryTimestamp - 150)
                let endDate = Date(timeIntervalSince1970: entryTimestamp + 150)
                
                let fetchDescriptor = FetchDescriptor<HealthKitBGCache>(
                    predicate: #Predicate<HealthKitBGCache> { cache in
                        cache.timestamp >= startDate && cache.timestamp <= endDate
                    }
                )
                
                do {
                    let existingEntries = try modelContext.fetch(fetchDescriptor)
                    
                    if existingEntries.isEmpty {
                        // Create new cache entry
                        let cacheEntry = HealthKitBGCache(
                            timestamp: entry.date,
                            bloodGlucose_mmol: entry.sgv / 18.0, // Convert mg/dL to mmol/L
                            healthKitUUID: "NS-\(UUID().uuidString)", // Use random UUID for each entry
                            sourceInfo: "Nightscout Direct Sync"
                        )
                        
                        modelContext.insert(cacheEntry)
                        savedCount += 1
                    } else {
                        skippedCount += 1
                    }
                } catch {
                    print("⚠️ Error checking/saving entry: \(error)")
                }
            }
            
            // Save all changes
            if savedCount > 0 {
                try modelContext.save()
                print("✅ Saved \(savedCount) new entries to SwiftData cache")
                print("⏩ Skipped \(skippedCount) duplicate entries")
            } else {
                print("ℹ️ No new entries to save (all \(skippedCount) already cached)")
            }
            
            // Success!
            let syncDuration = Date().timeIntervalSince(syncStartTime)
            print("✅ Server sync completed in \(String(format: "%.2f", syncDuration)) seconds")
            print("⏱️ Time: \(formatTime(Date()))")
            print("📊 Processed \(entriesToProcess.count) entries from server")
            
            // Return result with saved entries
            return SyncResult(
                newEntries: savedCount,
                totalFetched: entries.count,
                message: "Fetched \(entries.count) entries, saved \(savedCount) new entries to SwiftData cache"
            )
            
        } catch {
            // Enhanced error logging
            let syncDuration = Date().timeIntervalSince(syncStartTime)
            print("❌ Server sync failed after \(String(format: "%.2f", syncDuration)) seconds")
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
                _ = try await self.performSync()
            } catch {
                print("⚠️ Background sync failed: \(error)")
            }
        }
    }
}

