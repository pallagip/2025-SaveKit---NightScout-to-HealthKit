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

        // Filter entries to only include those with valid glucose readings
        let validEntries = entries.filter { entry in
            let validRange = 40.0...400.0
            return validRange.contains(entry.sgv)
        }
        
        print("🏥 Found \(validEntries.count) valid glucose readings (filtered out \(entries.count - validEntries.count) invalid readings)")
        
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
            print("📊 Creating sample: \(entry.sgv) mg/dL at \(dateFormatter.string(from: entry.date))")
            
            // Using the original timestamp from Nightscout for both start and end
            return HKQuantitySample(type: glucoseType,
                                    quantity: quantity,
                                    start: entry.date,
                                    end: entry.date)
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
        let endDate = latestDate.addingTimeInterval(1)     // 1 second after
        
        print("🔍 Checking for existing entries between \(startDate) and \(endDate)")
        
        // Fetch existing glucose samples in the date range
        let existingSamples = try await fetchGlucoseSamples(startDate: startDate, endDate: endDate)
        
        if existingSamples.isEmpty {
            print("ℹ️ No existing samples found in this time range")
            return entries
        }
        
        print("🔍 Found \(existingSamples.count) existing samples in HealthKit for this time range")
        
        // Extract timestamps of existing samples
        let existingTimestamps = Set(existingSamples.map { $0.startDate.timeIntervalSince1970 })
        
        // Filter out entries that already exist (match by timestamp)
        let uniqueEntries = entries.filter { entry in
            let timestamp = entry.date.timeIntervalSince1970
            return !existingTimestamps.contains(timestamp)
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
}
