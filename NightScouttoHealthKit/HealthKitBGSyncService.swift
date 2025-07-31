import Foundation
import SwiftData
import HealthKit

@MainActor
class HealthKitBGSyncService {
    static let shared = HealthKitBGSyncService()
    
    private let healthStore = HKHealthStore()
    
    private init() {}
    
    /// Syncs HealthKit blood glucose readings to SwiftData cache
    /// - Parameters:
    ///   - modelContext: SwiftData model context
    ///   - hoursBack: Number of hours to look back for new data (default: 24)
    /// - Returns: Number of new readings added to cache
    func syncHealthKitBGToCache(modelContext: ModelContext, hoursBack: Double = 24.0) async throws -> Int {
        print("🔄 Starting HealthKit BG sync for last \(hoursBack) hours...")
        
        // Check HealthKit authorization
        guard HKHealthStore.isHealthDataAvailable() else {
            throw HealthKitBGSyncError.healthKitNotAvailable
        }
        
        let bgType = HKQuantityType.quantityType(forIdentifier: .bloodGlucose)!
        let authStatus = healthStore.authorizationStatus(for: bgType)
        
        guard authStatus == .sharingAuthorized else {
            throw HealthKitBGSyncError.notAuthorized
        }
        
        // Get existing cached UUIDs to avoid duplicates
        let existingUUIDs = try await getExistingHealthKitUUIDs(modelContext: modelContext)
        print("📊 Found \(existingUUIDs.count) existing cached BG readings")
        
        // Fetch new HealthKit data
        let startDate = Date().addingTimeInterval(-hoursBack * 3600) // hoursBack hours ago
        let endDate = Date()
        
        let newSamples = try await fetchHealthKitBGSamples(from: startDate, to: endDate, excludingUUIDs: existingUUIDs)
        print("📥 Fetched \(newSamples.count) new BG samples from HealthKit")
        
        // Save new samples to SwiftData cache
        var savedCount = 0
        for sample in newSamples {
            let cacheEntry = HealthKitBGCache(from: sample)
            modelContext.insert(cacheEntry)
            savedCount += 1
        }
        
        // Save the context
        try modelContext.save()
        
        print("✅ Successfully cached \(savedCount) new BG readings")
        return savedCount
    }
    
    /// Fetches blood glucose samples from HealthKit
    private func fetchHealthKitBGSamples(from startDate: Date, to endDate: Date, excludingUUIDs: Set<String>) async throws -> [HKQuantitySample] {
        let bgType = HKQuantityType.quantityType(forIdentifier: .bloodGlucose)!
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: .strictStartDate)
        
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: bgType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)]
            ) { _, samples, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                
                guard let samples = samples as? [HKQuantitySample] else {
                    continuation.resume(returning: [])
                    return
                }
                
                // Filter out samples that are already cached
                let newSamples = samples.filter { sample in
                    !excludingUUIDs.contains(sample.uuid.uuidString)
                }
                
                continuation.resume(returning: newSamples)
            }
            
            healthStore.execute(query)
        }
    }
    
    /// Gets existing HealthKit UUIDs from SwiftData cache
    private func getExistingHealthKitUUIDs(modelContext: ModelContext) async throws -> Set<String> {
        let descriptor = FetchDescriptor<HealthKitBGCache>(
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        
        let cachedEntries = try modelContext.fetch(descriptor)
        return Set(cachedEntries.map { $0.healthKitUUID })
    }
    
    /// Finds cached BG reading closest to a target timestamp
    /// - Parameters:
    ///   - targetTimestamp: The timestamp to find closest reading for
    ///   - modelContext: SwiftData model context
    ///   - toleranceMinutes: Maximum time difference allowed (default: 5 minutes)
    /// - Returns: Closest cached BG reading within tolerance, or nil
    func findClosestCachedBG(to targetTimestamp: Date, modelContext: ModelContext, toleranceMinutes: Double = 5.0) throws -> HealthKitBGCache? {
        let toleranceSeconds = toleranceMinutes * 60.0
        let startDate = targetTimestamp.addingTimeInterval(-toleranceSeconds)
        let endDate = targetTimestamp.addingTimeInterval(toleranceSeconds)
        
        let predicate = #Predicate<HealthKitBGCache> { cache in
            cache.timestamp >= startDate && cache.timestamp <= endDate
        }
        
        let descriptor = FetchDescriptor<HealthKitBGCache>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        
        let matchingEntries = try modelContext.fetch(descriptor)
        
        // Find the closest one by time difference
        return matchingEntries.min { entry1, entry2 in
            let diff1 = abs(entry1.timestamp.timeIntervalSince(targetTimestamp))
            let diff2 = abs(entry2.timestamp.timeIntervalSince(targetTimestamp))
            return diff1 < diff2
        }
    }
    
    /// Gets count of cached BG readings
    func getCachedBGCount(modelContext: ModelContext) throws -> Int {
        let descriptor = FetchDescriptor<HealthKitBGCache>()
        return try modelContext.fetchCount(descriptor)
    }
    
    /// Cleans up old cached entries (older than specified days)
    func cleanupOldCachedEntries(modelContext: ModelContext, olderThanDays: Int = 30) throws -> Int {
        let cutoffDate = Date().addingTimeInterval(-Double(olderThanDays) * 24 * 3600)
        
        let predicate = #Predicate<HealthKitBGCache> { cache in
            cache.timestamp < cutoffDate
        }
        
        let descriptor = FetchDescriptor<HealthKitBGCache>(predicate: predicate)
        let oldEntries = try modelContext.fetch(descriptor)
        
        for entry in oldEntries {
            modelContext.delete(entry)
        }
        
        try modelContext.save()
        return oldEntries.count
    }
}

// MARK: - Error Types

enum HealthKitBGSyncError: LocalizedError {
    case healthKitNotAvailable
    case notAuthorized
    case fetchFailed(Error)
    
    var errorDescription: String? {
        switch self {
        case .healthKitNotAvailable:
            return "HealthKit is not available on this device"
        case .notAuthorized:
            return "HealthKit access not authorized for blood glucose data"
        case .fetchFailed(let error):
            return "Failed to fetch HealthKit data: \(error.localizedDescription)"
        }
    }
}
