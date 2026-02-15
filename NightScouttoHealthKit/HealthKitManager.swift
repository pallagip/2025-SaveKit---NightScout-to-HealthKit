//
//  HealthKitManager
//  ContentView.swift
//  NightScouttoHealthKit
//
//  Created by Patrick Pallagi on 2025-05-09.

import HealthKit

class HealthKitManager {
    private let healthStore = HKHealthStore()

    /// Call this early (e.g. on first app launch) to prompt the user for HealthKit permissions.
    func requestAuthorization() async throws {
        print("🏥 Checking HealthKit availability...")
        guard HKHealthStore.isHealthDataAvailable() else {
            print("❌ HealthKit not available on this device")
            throw NSError(domain: "HealthKit", code: 1, userInfo: [NSLocalizedDescriptionKey: "HealthKit not available"])
        }

        print("🏥 HealthKit is available, requesting authorization...")
        let glucoseType = HKObjectType.quantityType(forIdentifier: .bloodGlucose)!
        let typesToRead: Set = [glucoseType]
        let typesToWrite: Set = [glucoseType]

        try await healthStore.requestAuthorization(toShare: typesToWrite, read: typesToRead)
        print("✅ HealthKit authorization successful")
    }

    /// Save an array of Nightscout entries into HealthKit in mg/dL
    /// Returns the number of new entries that were saved to HealthKit
    func saveEntriesToHealthKit(_ entries: [Entry]) async throws -> Int {
        print("🏥 Preparing to save \(entries.count) glucose readings to HealthKit")
        
        let glucoseType = HKQuantityType.quantityType(forIdentifier: .bloodGlucose)!
        let unit = HKUnit(from: "mg/dL")

        // Filter entries to only include those with valid glucose readings and NOT in the future
        let now = Date()
        let filterCutoff = now.addingTimeInterval(60) // 1 minute buffer for clock drift
        
        var validEntries = entries.filter { entry in
            let validRange = 40.0...400.0
            let isReadingValid = validRange.contains(entry.sgv)
            let isDateValid = entry.date <= filterCutoff
            return isReadingValid && isDateValid
        }
        
        let futureFilteredCount = entries.filter { $0.date > filterCutoff }.count
        if futureFilteredCount > 0 {
            print("✂️ Filtered out \(futureFilteredCount) future-dated readings before saving to HealthKit")
        }
        
        // --- NEW: Intra-batch Deduplication (2.5-minute window) ---
        // Sort entries by date to perform Sequential Deduplication
        let sortedEntries = validEntries.sorted { $0.date < $1.date }
        var deduplicatedBatch = [Entry]()
        
        for entry in sortedEntries {
            if let lastKept = deduplicatedBatch.last {
                let timeDiff = entry.date.timeIntervalSince(lastKept.date)
                // If less than 150 seconds apart (2.5 mins), it's a duplicate
                if timeDiff < 150 {
                    // Keep the one with an ID if the previous one didn't have one
                    if lastKept._id == nil && entry._id != nil {
                        deduplicatedBatch[deduplicatedBatch.count - 1] = entry
                    }
                    continue
                }
            }
            deduplicatedBatch.append(entry)
        }
        
        let batchDuplicateCount = validEntries.count - deduplicatedBatch.count
        if batchDuplicateCount > 0 {
            print("✂️ Removed \(batchDuplicateCount) intra-batch duplicates within 150s window")
        }
        validEntries = deduplicatedBatch
        // ---------------------------------------------------------
        
        print("🏥 Found \(validEntries.count) valid glucose readings (filtered out \(entries.count - validEntries.count) invalid, future, or batch-duplicate readings)")
        
        if validEntries.isEmpty {
            print("⚠️ No valid glucose readings to save")
            return 0
        }
        
        // Check which entries already exist in HealthKit to avoid duplicates
        let uniqueEntries = try await filterOutExistingEntries(validEntries)
        
        print("🏥 Found \(uniqueEntries.count) unique entries that don't already exist in HealthKit")
        
        if uniqueEntries.isEmpty {
            print("ℹ️ All entries already exist in HealthKit, nothing new to save")
            return 0
        }

        let samples = uniqueEntries.map { entry -> HKQuantitySample in
            let quantity = HKQuantity(unit: unit, doubleValue: entry.sgv)
            
            // For debugging
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            print("📊 Creating sample: \(entry.sgv) mg/dL at \(dateFormatter.string(from: entry.date)) (ID: \(entry._id ?? "none"))")
            
            // Add metadata including the original Nightscout ID
            var metadata: [String: Any] = [
                HKMetadataKeyWasUserEntered: false
            ]
            if let nsId = entry._id {
                metadata[HKMetadataKeyExternalUUID] = nsId
            }
            
            // Using the original timestamp from Nightscout for both start and end
            return HKQuantitySample(type: glucoseType,
                                    quantity: quantity,
                                    start: entry.date,
                                    end: entry.date,
                                    metadata: metadata)
        }

        print("🏥 Saving \(samples.count) unique samples to HealthKit...")
        
        // Save the samples and return the count of saved samples
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            healthStore.save(samples) { success, error in
                if let error = error {
                    print("❌ HealthKit save failed: \(error.localizedDescription)")
                    continuation.resume(throwing: error)
                } else {
                    print("✅ Successfully saved \(samples.count) glucose samples to HealthKit")
                    continuation.resume()
                }
            }
        }
        
        // Return the count of newly saved entries
        return samples.count
    }
    
    /// Filter out entries that already exist in HealthKit to avoid duplicates
    private func filterOutExistingEntries(_ entries: [Entry]) async throws -> [Entry] {
        // Get the earliest and latest dates from the entries
        guard let earliestDate = entries.map({ $0.date }).min(),
              let latestDate = entries.map({ $0.date }).max() else {
            return entries
        }
        
        // Add a small buffer to ensure we capture all potential matches
        let startDate = earliestDate.addingTimeInterval(-1) // 1 second before
        
        // Don't check beyond current time, as we just filtered out future entries
        let latestDateInBatch = latestDate
        let endDate = min(latestDateInBatch, Date()).addingTimeInterval(1)     // max current time + 1s
        
        print("🔍 Checking for existing entries between \(startDate) and \(endDate)")
        
        // Fetch existing glucose samples in the date range
        let existingSamples = try await fetchGlucoseSamples(startDate: startDate, endDate: endDate)
        
        if existingSamples.isEmpty {
            print("ℹ️ No existing samples found in this time range")
            return entries
        }
        
        print("🔍 Found \(existingSamples.count) existing samples in HealthKit for this time range")
        
        // Extract timestamps of existing samples
        let existingSamplesSorted = existingSamples.sorted { $0.startDate < $1.startDate }
        
        // Filter out entries that already exist (check for any existing sample within 150s)
        let uniqueEntries = entries.filter { entry in
            // Use binary search or simple find for efficiency if batch is large
            // But since batches are usually < 1000, we can use a simple check
            let existsInRange = existingSamplesSorted.contains { existing in
                abs(existing.startDate.timeIntervalSince(entry.date)) < 150
            }
            return !existsInRange
        }
        
        print("🔍 After filtering: \(uniqueEntries.count) entries are new and \(entries.count - uniqueEntries.count) already exist")
        
        return uniqueEntries
    }
    
    /// Helper method to fetch glucose samples in a date range
    private func fetchGlucoseSamples(startDate: Date, endDate: Date) async throws -> [HKQuantitySample] {
        let glucoseType = HKQuantityType.quantityType(forIdentifier: .bloodGlucose)!
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: .strictStartDate)
        
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[HKQuantitySample], Error>) in
            let query = HKSampleQuery(
                sampleType: glucoseType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { (query, samples, error) in
                if let error = error {
                    print("❌ Error fetching HealthKit data: \(error.localizedDescription)")
                    continuation.resume(throwing: error)
                    return
                }
                
                guard let samples = samples as? [HKQuantitySample] else {
                    print("ℹ️ No glucose samples found in the specified date range")
                    continuation.resume(returning: [])
                    return
                }
                
                continuation.resume(returning: samples)
            }
            
            healthStore.execute(query)
        }
    }
    
    /// Fetches the date of the most recent glucose sample in HealthKit (ignoring future dates)
    func fetchLatestGlucoseDate() async -> Date? {
        let glucoseType = HKQuantityType.quantityType(forIdentifier: .bloodGlucose)!
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
        
        // Critical: Only look at samples up to 'now + 1 minute' to ignore future-dated samples
        let predicate = HKQuery.predicateForSamples(withStart: nil, end: Date().addingTimeInterval(60), options: .strictEndDate)
        
        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: glucoseType,
                predicate: predicate,
                limit: 1,
                sortDescriptors: [sortDescriptor]
            ) { _, samples, error in
                if let error = error {
                    print("⚠️ Error fetching latest glucose date: \(error.localizedDescription)")
                    continuation.resume(returning: nil)
                    return
                }
                
                let latestDate = (samples as? [HKQuantitySample])?.first?.startDate
                continuation.resume(returning: latestDate)
            }
            
            healthStore.execute(query)
        }
    }
    
    /// Finds and deletes glucose samples with future dates (e.g. from the '2081' bug)
    func deleteFutureGlucoseSamples() async throws -> Int {
        let glucoseType = HKQuantityType.quantityType(forIdentifier: .bloodGlucose)!
        
        // Find everything more than 1 hour in the future
        let oneHourFromNow = Date().addingTimeInterval(3600)
        let predicate = HKQuery.predicateForSamples(withStart: oneHourFromNow, end: nil, options: .strictStartDate)
        
        let samplesToDelete = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[HKSample], Error>) in
            let query = HKSampleQuery(
                sampleType: glucoseType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, samples, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: samples ?? [])
                }
            }
            healthStore.execute(query)
        }
        
        if !samplesToDelete.isEmpty {
            print("✂️ Found \(samplesToDelete.count) future-dated samples to delete")
            try await healthStore.delete(samplesToDelete)
            print("✅ Successfully deleted \(samplesToDelete.count) future-dated samples")
        }
        
        return samplesToDelete.count
    }
    
    /// Fetch recent glucose readings from HealthKit for comparison (helpful for debugging)
    func fetchRecentGlucose() async throws -> [HKQuantitySample] {
        let glucoseType = HKQuantityType.quantityType(forIdentifier: .bloodGlucose)!
        
        // Create a predicate for the last hour
        let now = Date()
        let startDate = now.addingTimeInterval(-3600) // 60 minutes ago
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: now, options: .strictStartDate)
        
        // Create the query
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
        
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[HKQuantitySample], Error>) in
            let query = HKSampleQuery(
                sampleType: glucoseType,
                predicate: predicate,
                limit: 10, // Limit to last 10 readings
                sortDescriptors: [sortDescriptor]
            ) { (query, samples, error) in
                if let error = error {
                    print("❌ Error fetching HealthKit data: \(error.localizedDescription)")
                    continuation.resume(throwing: error)
                    return
                }
                
                guard let samples = samples as? [HKQuantitySample] else {
                    print("❌ No glucose samples found or couldn't cast to HKQuantitySample")
                    continuation.resume(returning: [])
                    return
                }
                
                print("✅ Found \(samples.count) recent glucose samples in HealthKit")
                continuation.resume(returning: samples)
            }
            
            healthStore.execute(query)
        }
    }
    
    /// Fetch blood glucose readings from HealthKit for a specific time range
    func fetchGlucoseForTimeRange(startDate: Date, endDate: Date) async throws -> [HKQuantitySample] {
        print("🔍 Fetching glucose data from \(startDate) to \(endDate)")
        let glucoseType = HKQuantityType.quantityType(forIdentifier: .bloodGlucose)!
        
        // Create a predicate for the specified time range
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: .strictStartDate)
        
        // Create the query with chronological sorting (important for matching)
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
        
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[HKQuantitySample], Error>) in
            let query = HKSampleQuery(
                sampleType: glucoseType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit, // Get all readings in the time range
                sortDescriptors: [sortDescriptor]
            ) { (query, samples, error) in
                if let error = error {
                    print("❌ Error fetching HealthKit data: \(error.localizedDescription)")
                    continuation.resume(throwing: error)
                    return
                }
                
                guard let samples = samples as? [HKQuantitySample] else {
                    print("ℹ️ No glucose samples found in the specified date range")
                    continuation.resume(returning: [])
                    return
                }
                
                print("✅ Found \(samples.count) glucose samples in HealthKit for the specified time range")
                continuation.resume(returning: samples)
            }
            
            healthStore.execute(query)
        }
    }
    
    /// Finds a glucose reading exactly at the specified target time within a tolerance window
    /// - Parameters:
    ///   - targetTime: The exact target timestamp to match
    ///   - samples: Array of HKQuantitySamples to search within
    ///   - toleranceMinutes: Maximum time difference in minutes (default 5 minutes)
    /// - Returns: The closest matching sample and its value in mmol/L, or nil if none found within tolerance
    func findExactGlucoseReading(targetTime: Date, in samples: [HKQuantitySample], toleranceMinutes: Double = 5.0) -> (sample: HKQuantitySample, value: Double)? {
        // Convert tolerance to seconds
        let toleranceSeconds = toleranceMinutes * 60
        
        // Find the closest sample by time difference
        var closestSample: HKQuantitySample? = nil
        var minTimeDifference = Double.infinity
        
        for sample in samples {
            let timeDifference = abs(sample.startDate.timeIntervalSince(targetTime))
            
            // Only consider samples within the tolerance window
            if timeDifference <= toleranceSeconds && timeDifference < minTimeDifference {
                minTimeDifference = timeDifference
                closestSample = sample
            }
        }
        
        // If we found a matching sample, return it along with its value in mmol/L
        if let sample = closestSample {
            let unit = HKUnit(from: "mg/dL")
            let valueInMgdl = sample.quantity.doubleValue(for: unit)
            let valueInMmol = valueInMgdl / 18.0 // Convert to mmol/L
            
            return (sample, valueInMmol)
        }
        
        return nil
    }
    
    /// Finds the closest glucose reading to a specific timestamp within a given tolerance
    /// - Parameters:
    ///   - timestamp: The target timestamp to match
    ///   - samples: Array of HKQuantitySamples to search within
    ///   - timeframeMinutes: The expected timeframe in minutes after the prediction when actual BG should occur (default 20 minutes)
    ///   - tolerance: Maximum time difference in seconds (default 30 minutes)
    /// - Returns: The closest matching sample and its value in mmol/L, or nil if none found within tolerance
    func findClosestGlucoseReading(to timestamp: Date, in samples: [HKQuantitySample], timeframeMinutes: Double = 20.0, tolerance: TimeInterval = 1800) -> (sample: HKQuantitySample, value: Double)? {
        // The target time is EXACTLY 20 minutes after the prediction timestamp
        // This is when we expect to have the actual blood glucose value to compare against the prediction
        let targetTime = timestamp.addingTimeInterval(20 * 60) // Exactly 20 minutes later
        
        // Find the closest sample by time difference
        var closestSample: HKQuantitySample? = nil
        var minTimeDifference = Double.infinity
        
        for sample in samples {
            let timeDifference = abs(sample.startDate.timeIntervalSince(targetTime))
            
            // Only consider samples within the tolerance window
            if timeDifference <= tolerance && timeDifference < minTimeDifference {
                minTimeDifference = timeDifference
                closestSample = sample
            }
        }
        
        // If we found a matching sample, return it along with its value in mmol/L
        if let sample = closestSample {
            let unit = HKUnit(from: "mg/dL")
            let valueInMgdl = sample.quantity.doubleValue(for: unit)
            let valueInMmol = valueInMgdl / 18.0 // Convert to mmol/L
            
            return (sample, valueInMmol)
        }
        
        return nil
    }
    
    /// Deletes all glucose samples from HealthKit that were created by this app
    func deleteAllGlucoseSamples() async throws -> Int {
        let glucoseType = HKQuantityType.quantityType(forIdentifier: .bloodGlucose)!
        
        // Predicate to ONLY target data created by this app
        let sourcePredicate = HKQuery.predicateForObjects(from: .default())
        // Combine with a time predicate just to be safe (entire history)
        let timePredicate = HKQuery.predicateForSamples(withStart: .distantPast, end: .distantFuture, options: .strictEndDate)
        let finalPredicate = NSCompoundPredicate(andPredicateWithSubpredicates: [sourcePredicate, timePredicate])
        
        return try await withCheckedThrowingContinuation { continuation in
            healthStore.deleteObjects(of: glucoseType, predicate: finalPredicate) { success, deletedCount, error in
                if let error = error {
                    print("❌ HealthKit deletion failed: \(error)")
                    continuation.resume(throwing: error)
                } else {
                    print("✅ Successfully deleted \(deletedCount) glucose samples created by SaveKit")
                    continuation.resume(returning: deletedCount)
                }
            }
        }
    }
}
