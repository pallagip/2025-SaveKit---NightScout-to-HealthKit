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
    func saveEntriesToHealthKit(_ entries: [Entry]) async throws {
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
            return
        }

        let samples = validEntries.map { entry -> HKQuantitySample in
            let quantity = HKQuantity(unit: unit, doubleValue: entry.sgv)
            
            // For debugging
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            print("📊 Creating sample: \(entry.sgv) mg/dL at \(dateFormatter.string(from: entry.date))")
            
            // start and end at the same timestamp
            return HKQuantitySample(type: glucoseType,
                                    quantity: quantity,
                                    start: entry.date,
                                    end: entry.date)
        }

        print("🏥 Saving \(samples.count) samples to HealthKit...")
        
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
    }
    
    /// Fetch recent glucose readings from HealthKit for comparison (helpful for debugging)
    func fetchRecentGlucose() async throws -> [HKQuantitySample] {
        let glucoseType = HKQuantityType.quantityType(forIdentifier: .bloodGlucose)!
        
        // Create a predicate for the last hour
        let now = Date()
        let startDate = now.addingTimeInterval(-3600) // 1 hour ago
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: now, options: .strictStartDate)
        
        // Create the query
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
        
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[HKQuantitySample], Error>) in
            let query = HKSampleQuery(
                sampleType: glucoseType,
                predicate: predicate,
                limit: 20, // Limit to last 20 readings
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
}
