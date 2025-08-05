//
//  HealthKitFeatureProvider.swift
//  NightScouttoHealthKit
//
//  Created by Patrick Pallagi on 2025-05-20.
//

import HealthKit
import CoreML
import Combine
import SwiftData

/// Pulls the last 8 timesteps (5-minute bins) of the four features
/// and returns a ready-to-scale MLMultiArray [1, 8, 4]
final class HealthKitFeatureProvider: ObservableObject {

    private let store = HKHealthStore()
    private let glucose      = HKQuantityType.quantityType(forIdentifier: .bloodGlucose)!
    private let heartRate    = HKQuantityType.quantityType(forIdentifier: .heartRate)!
    private let carbSamples = HKQuantityType.quantityType(forIdentifier: .dietaryCarbohydrates)!
    private let bolusSamples = HKQuantityType.quantityType(forIdentifier: .insulinDelivery)!
    
    @Published var latestGlucoseValue: Double = 0.0

    /// Fetch the latest quantity sample of a given type that ends on or before `date`
    private func latestValue(of type: HKQuantityType,
                             upTo date: Date,
                             unit: HKUnit,
                             deliveryReason: HKInsulinDeliveryReason? = nil) async throws -> Double {

        let predicate = HKQuery.predicateForSamples(withStart: .distantPast,
                                                    end: date,
                                                    options: .strictEndDate)
        var finalPredicate = predicate
        if type == bolusSamples, let reason = deliveryReason {
            let reasonPred = HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeyInsulinDeliveryReason,
                                                         operatorType: .equalTo,
                                                         value: reason.rawValue)
            finalPredicate = NSCompoundPredicate(andPredicateWithSubpredicates: [predicate, reasonPred])
        }

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(sampleType: type,
                                      predicate: finalPredicate,
                                      limit: 1,
                                      sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierEndDate,
                                                                         ascending: false)]) {
                                                (_, samples, error) in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let sample = samples?.first as? HKQuantitySample else {
                    continuation.resume(returning: .nan)
                    return
                }
                continuation.resume(returning: sample.quantity.doubleValue(for: unit))
            }
            store.execute(query)
        }
    }

    /// (1) ask permission once, early in app life-cycle
    func requestAuth() async throws {
        // Define workout types for authorization
        let workoutType = HKObjectType.workoutType()
        let activeEnergyType = HKQuantityType(.activeEnergyBurned)
        
        try await store.requestAuthorization(toShare: [], read: [
            glucose, heartRate, carbSamples, bolusSamples, workoutType, activeEnergyType
        ])
    }

    /// (2) call right before Predict.  Throws on failure.
    /// Fetch the most recent glucose value (in mg/dL) for personalization
    func fetchLatestGlucoseValue() async throws -> Double {
        let now = Date()
        
        // Call the local latestValue function
        let glucoseValue = try await latestValue(of: glucose, upTo: now, unit: HKUnit(from: "mg/dL"))
        
        if glucoseValue.isNaN {
            throw NSError(domain: "HealthKit", code: 2, userInfo: [NSLocalizedDescriptionKey: "No recent glucose readings available"])
        }
        
        // Update the published value
        await MainActor.run {
            self.latestGlucoseValue = glucoseValue
        }
        
        return glucoseValue
    }
    
    func buildWindow() async throws -> MLMultiArray {
        let now = Date()
        let step = 5.0 * 60  // 5 min in seconds
        
        // Create regular 5-minute bins for recent data (last 35 minutes)
        let recentBins = stride(from: 7, through: 0, by: -1).map { now.addingTimeInterval(-Double($0) * step) }
        
        // Create extended bins for insulin (4 hours) and carbs (3 hours)
        let fourHoursInSeconds = 4 * 60 * 60.0
        let threeHoursInSeconds = 3 * 60 * 60.0
        
        // Calculate start times for extended lookback periods
        let insulinStartTime = now.addingTimeInterval(-fourHoursInSeconds)
        let carbsStartTime = now.addingTimeInterval(-threeHoursInSeconds)
        
        // Arrays for regular 5-min bins
        var hr = [Double]()
        var bg = [Double]()
        var recentCarbsDose = [Double]()
        var recentBolusDose = [Double]()
        
        // Extended arrays for insulin and carbs history
        var extendedBolusDose = [Double]()
        var extendedCarbsDose = [Double]()
        
        // Fetch insulin doses from the last 4 hours at 15-minute intervals
        // We use 15-minute intervals for extended lookback to balance detail and efficiency
        let insulinBins = stride(from: insulinStartTime.timeIntervalSince1970, 
                                 to: now.timeIntervalSince1970, 
                                 by: 15 * 60).map { Date(timeIntervalSince1970: $0) }
        
        for anchor in insulinBins {
            let bolus = try await Self.calculateActiveInsulinFromHealthKit(store: store, now: now, upTo: anchor)
            extendedBolusDose.append(bolus)
        }
        
        // Fetch carb intake from the last 3 hours at 15-minute intervals
        let carbsBins = stride(from: carbsStartTime.timeIntervalSince1970, 
                               to: now.timeIntervalSince1970, 
                               by: 15 * 60).map { Date(timeIntervalSince1970: $0) }
        
        for anchor in carbsBins {
            let carbs = try await Self.calculateActiveCarbsFromHealthKit(store: store, now: now, upTo: anchor)
            extendedCarbsDose.append(carbs)
        }
        
        // Fetch each 5-min bin for regular data
        for anchor in recentBins {
            hr.append(try await latestValue(of: heartRate,
                                          upTo: anchor,
                                          unit: HKUnit(from: "count/min")))
            bg.append(try await latestValue(of: glucose,
                                          upTo: anchor,
                                          unit: HKUnit(from: "mg/dL")))
            
            // Still collect recent carbs and insulin for the regular bins
            recentCarbsDose.append(try await latestValue(of: carbSamples,
                                                       upTo: anchor,
                                                       unit: HKUnit.gram()))
            recentBolusDose.append(try await latestValue(of: bolusSamples,
                                                       upTo: anchor,
                                                       unit: HKUnit.internationalUnit(),
                                                       deliveryReason: .bolus))
        }
        
        // Calculate total active insulin and carbs using new HealthKit-based methods
        let totalActiveInsulin = try await Self.calculateActiveInsulinFromHealthKit(store: store, now: now)
        let totalActiveCarbs = try await Self.calculateActiveCarbsFromHealthKit(store: store, now: now)
        
        // Combine recent data with extended history calculations
        // Convert bolus + carbs to active / operative via e-decay for recent data
        func expDecay(_ doses: [Double], λ: Double = 0.028) -> [Double] {
            var out = [Double](repeating: 0, count: doses.count)
            out[0] = doses[0]
            for i in 1..<doses.count {
                out[i] = out[i - 1] * exp(-λ * 5 / 60) + doses[i]   // 5-min step
            }
            return out
        }
        
        // Process recent data
        var actIns = expDecay(recentBolusDose)
        var opCarbs = expDecay(recentCarbsDose)
        
        // Add the contribution from extended history to the recent data
        // Add the extended insulin/carb activity to the first position
        if !actIns.isEmpty {
            actIns[0] += totalActiveInsulin
        }
        
        if !opCarbs.isEmpty {
            opCarbs[0] += totalActiveCarbs
        }
        
        // Re-apply decay to propagate the extended history through the recent time bins
        actIns = expDecay(actIns)
        opCarbs = expDecay(opCarbs)
        
        // ---- to MLMultiArray with correct shape [1, 24, 8] -------------------------------------------------
        print("🔍 HealthKitFeatureProvider: Creating tensor with shape [1, 24, 8]")
        let x = try MLMultiArray(shape: [1, 24, 8], dataType: .float32)
        
        // Apply reasonable bounds to prevent unrealistic values
        let boundedIOB = max(0.0, min(10.0, totalActiveInsulin))
        let boundedCOB = max(0.0, min(100.0, totalActiveCarbs))
        
        // Extend arrays to 24 time steps by padding with last values
        let extendedHR = hr + Array(repeating: hr.last ?? 70.0, count: max(0, 24 - hr.count))
        let extendedBG = bg + Array(repeating: bg.last ?? 100.0, count: max(0, 24 - bg.count))
        // Use bounded values for IOB/COB instead of original arrays
        let extendedActIns = Array(repeating: boundedIOB / 24.0, count: 24) // Distribute bounded IOB across time steps
        let extendedOpCarbs = Array(repeating: boundedCOB / 24.0, count: 24) // Distribute bounded COB across time steps
        
        // Fill tensor with 24 time steps and 8 features each
        // Feature order matches training: blood_glucose, insulin_dose, dietary_carbohydrates, heart_rate, bg_trend, hr_trend, hour_sin, hour_cos
        var idx = 0
        for t in 0..<24 {
            // Feature 0: blood_glucose (convert to mmol/L)
            let bgMmol = extendedBG[min(t, extendedBG.count-1)] / 18.0
            x[idx] = NSNumber(value: bgMmol); idx += 1
            
            // Feature 1: insulin_dose (active insulin)
            x[idx] = NSNumber(value: extendedActIns[min(t, extendedActIns.count-1)]); idx += 1
            
            // Feature 2: dietary_carbohydrates (operative carbs)
            x[idx] = NSNumber(value: extendedOpCarbs[min(t, extendedOpCarbs.count-1)]); idx += 1
            
            // Feature 3: heart_rate (normalized)
            let normalizedHR = (extendedHR[min(t, extendedHR.count-1)] - 70.0) / 30.0
            x[idx] = NSNumber(value: normalizedHR); idx += 1
            
            // Feature 4: bg_trend (simplified)
            let bgTrend = t > 0 ? (extendedBG[min(t, extendedBG.count-1)] - extendedBG[min(t-1, extendedBG.count-1)]) / 18.0 / 5.0 : 0.0
            x[idx] = NSNumber(value: bgTrend); idx += 1
            
            // Feature 5: hr_trend (simplified)
            let hrTrend = t > 0 ? (extendedHR[min(t, extendedHR.count-1)] - extendedHR[min(t-1, extendedHR.count-1)]) / 5.0 : 0.0
            x[idx] = NSNumber(value: hrTrend); idx += 1
            
            // Feature 6: hour_sin (circadian)
            let hour = Double(Calendar.current.component(.hour, from: Date()))
            let hourFraction = hour + Double(Calendar.current.component(.minute, from: Date())) / 60.0
            let hourSin = sin(2.0 * .pi * hourFraction / 24.0)
            x[idx] = NSNumber(value: hourSin); idx += 1
            
            // Feature 7: hour_cos (circadian)
            let hourCos = cos(2.0 * .pi * hourFraction / 24.0)
            x[idx] = NSNumber(value: hourCos); idx += 1
        }
        
        // Verify final tensor shape
        let finalShape = x.shape.map { $0.intValue }
        print("🔍 HealthKitFeatureProvider: Final tensor shape: \(finalShape)")
        print("🔍 HealthKitFeatureProvider: Tensor element count: \(x.count)")
        
        print("🔄 Insulin considered from the last 4 hours, carbs from the last 3 hours")
        print("💉 Total active insulin: \(String(format: "%.2f", totalActiveInsulin)) IU (bounded: \(String(format: "%.2f", boundedIOB)) IU)")
        print("🍞 Total active carbs: \(String(format: "%.2f", totalActiveCarbs)) g (bounded: \(String(format: "%.1f", boundedCOB)) g)")
        
        return x
    }
    
    /// Calculate active insulin from actual HealthKit insulin doses in 4-hour window
    private static func calculateActiveInsulinFromHealthKit(store: HKHealthStore, now: Date, upTo: Date? = nil) async throws -> Double {
        let insulinType = HKQuantityType.quantityType(forIdentifier: .insulinDelivery)!
        let fourHoursAgo = Calendar.current.date(byAdding: .hour, value: -4, to: now)!
        let endDate = upTo ?? now
        let predicate = HKQuery.predicateForSamples(withStart: fourHoursAgo, end: endDate, options: .strictEndDate)
        
        let insulinSamples: [HKQuantitySample] = try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(sampleType: insulinType, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: samples as? [HKQuantitySample] ?? [])
                }
            }
            store.execute(query)
        }
        
        var totalActiveInsulin = 0.0
        for sample in insulinSamples {
            let doseUnits = sample.quantity.doubleValue(for: HKUnit.internationalUnit())
            let hoursAgo = now.timeIntervalSince(sample.startDate) / 3600.0
            
            // Insulin activity factor using exponential decay (4-hour duration)
            let activityFactor = max(0.0, exp(-hoursAgo / 1.5)) // 1.5h time constant
            totalActiveInsulin += doseUnits * activityFactor
            
            print("    → Insulin: \(String(format: "%.2f", doseUnits))U at \(String(format: "%.1f", hoursAgo))h ago, activity: \(String(format: "%.3f", activityFactor))")
        }
        
        return totalActiveInsulin
    }
    
    /// Calculate active carbs from actual HealthKit carb entries in 3-hour window
    private static func calculateActiveCarbsFromHealthKit(store: HKHealthStore, now: Date, upTo: Date? = nil) async throws -> Double {
        let carbType = HKQuantityType.quantityType(forIdentifier: .dietaryCarbohydrates)!
        let threeHoursAgo = Calendar.current.date(byAdding: .hour, value: -3, to: now)!
        let endDate = upTo ?? now
        let predicate = HKQuery.predicateForSamples(withStart: threeHoursAgo, end: endDate, options: .strictEndDate)
        
        let carbSamples: [HKQuantitySample] = try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(sampleType: carbType, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: samples as? [HKQuantitySample] ?? [])
                }
            }
            store.execute(query)
        }
        
        var totalActiveCarbs = 0.0
        for sample in carbSamples {
            let carbGrams = sample.quantity.doubleValue(for: HKUnit.gram())
            let hoursAgo = now.timeIntervalSince(sample.startDate) / 3600.0
            
            // Carb absorption factor using exponential decay (3-hour duration)
            let absorptionFactor = max(0.0, exp(-hoursAgo / 1.0)) // 1.0h time constant
            totalActiveCarbs += carbGrams * absorptionFactor
            
            print("    → Carbs: \(String(format: "%.1f", carbGrams))g at \(String(format: "%.1f", hoursAgo))h ago, absorption: \(String(format: "%.3f", absorptionFactor))")
        }
        
        return totalActiveCarbs
    }
    
    /// Fetch recent glucose values, ordered from most recent to oldest
    /// - Parameter limit: The maximum number of readings to fetch
    /// - Returns: Array of glucose values in mg/dL
    func fetchRecentGlucoseValues(limit: Int) async throws -> [Double] {
        let now = Date()
        let startDate = Calendar.current.date(byAdding: .hour, value: -12, to: now) ?? now.addingTimeInterval(-12 * 3600)
        
        let predicate = HKQuery.predicateForSamples(withStart: startDate,
                                                    end: now,
                                                    options: .strictEndDate)
        
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(sampleType: glucose,
                                      predicate: predicate,
                                      limit: limit,
                                      sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierEndDate,
                                                                         ascending: false)]) { (_, samples, error) in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                
                guard let samples = samples as? [HKQuantitySample], !samples.isEmpty else {
                    continuation.resume(returning: [])
                    return
                }
                
                let values = samples.map { $0.quantity.doubleValue(for: HKUnit(from: "mg/dL")) }
                continuation.resume(returning: values)
            }
            store.execute(query)
        }
    }
    
    /// Represents an insulin dose with timestamp and units
    struct InsulinDose {
        let timestamp: Date
        let units: Double
    }
    
    /// Fetch recent insulin doses
    /// - Parameter hoursBack: Number of hours to look back
    /// - Returns: Array of insulin doses with timestamps
    func fetchRecentInsulinDoses(hoursBack: Double) async throws -> [InsulinDose] {
        let now = Date()
        let startDate = now.addingTimeInterval(-hoursBack * 3600)
        
        let predicate = HKQuery.predicateForSamples(withStart: startDate,
                                                   end: now,
                                                   options: .strictEndDate)
        
        // Add predicate for bolus insulin only
        let reasonPred = HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeyInsulinDeliveryReason,
                                                    operatorType: .equalTo,
                                                    value: HKInsulinDeliveryReason.bolus.rawValue)
        
        let finalPredicate = NSCompoundPredicate(andPredicateWithSubpredicates: [predicate, reasonPred])
        
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(sampleType: bolusSamples,
                                      predicate: finalPredicate,
                                      limit: Int(hoursBack * 4), // Average 1 dose per 15 minutes max
                                      sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierEndDate,
                                                                         ascending: false)]) { (_, samples, error) in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                
                guard let samples = samples as? [HKQuantitySample], !samples.isEmpty else {
                    continuation.resume(returning: [])
                    return
                }
                
                let doses = samples.map { sample in
                    InsulinDose(
                        timestamp: sample.endDate,
                        units: sample.quantity.doubleValue(for: HKUnit.internationalUnit())
                    )
                }
                
                continuation.resume(returning: doses)
            }
            store.execute(query)
        }
    }
    
    /// Represents a carb intake with timestamp and grams
    struct CarbIntake {
        let timestamp: Date
        let grams: Double
    }
    
    /// Fetch recent carbohydrate intake
    /// - Parameter hoursBack: Number of hours to look back
    /// - Returns: Array of carb intake with timestamps
    func fetchRecentCarbIntake(hoursBack: Double) async throws -> [CarbIntake] {
        let now = Date()
        let startDate = now.addingTimeInterval(-hoursBack * 3600)
        
        let predicate = HKQuery.predicateForSamples(withStart: startDate,
                                                   end: now,
                                                   options: .strictEndDate)
        
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(sampleType: carbSamples,
                                      predicate: predicate,
                                      limit: Int(hoursBack * 4), // Average 1 entry per 15 minutes max
                                      sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierEndDate,
                                                                         ascending: false)]) { (_, samples, error) in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                
                guard let samples = samples as? [HKQuantitySample], !samples.isEmpty else {
                    continuation.resume(returning: [])
                    return
                }
                
                let intakes = samples.map { sample in
                    CarbIntake(
                        timestamp: sample.endDate,
                        grams: sample.quantity.doubleValue(for: HKUnit.gram())
                    )
                }
                
                continuation.resume(returning: intakes)
            }
            store.execute(query)
        }
    }
    
    /// Check if there are recent insulin or carbohydrate entries within the specified time window
    /// - Parameter minutesBack: Number of minutes to look back (default 30 minutes)
    /// - Returns: True if recent entries found, false otherwise
    func hasRecentInsulinOrCarbEntries(minutesBack: Double = 30.0) async throws -> Bool {
        let now = Date()
        let startDate = now.addingTimeInterval(-minutesBack * 60) // Convert minutes to seconds
        
        let predicate = HKQuery.predicateForSamples(withStart: startDate,
                                                   end: now,
                                                   options: .strictEndDate)
        
        // Check for recent insulin entries
        let hasRecentInsulin = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
            let query = HKSampleQuery(sampleType: bolusSamples,
                                      predicate: predicate,
                                      limit: 1,
                                      sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierEndDate,
                                                                         ascending: false)]) { (_, samples, error) in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                
                let hasEntries = !(samples?.isEmpty ?? true)
                if hasEntries {
                    if let sample = samples?.first as? HKQuantitySample {
                        let doseUnits = sample.quantity.doubleValue(for: HKUnit.internationalUnit())
                        let minutesAgo = now.timeIntervalSince(sample.endDate) / 60.0
                        print("🚫 Recent insulin entry found: \(String(format: "%.2f", doseUnits))U at \(String(format: "%.1f", minutesAgo)) minutes ago")
                    }
                }
                continuation.resume(returning: hasEntries)
            }
            store.execute(query)
        }
        
        if hasRecentInsulin {
            return true
        }
        
        // Check for recent carbohydrate entries
        let hasRecentCarbs = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
            let query = HKSampleQuery(sampleType: carbSamples,
                                      predicate: predicate,
                                      limit: 1,
                                      sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierEndDate,
                                                                         ascending: false)]) { (_, samples, error) in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                
                let hasEntries = !(samples?.isEmpty ?? true)
                if hasEntries {
                    if let sample = samples?.first as? HKQuantitySample {
                        let carbGrams = sample.quantity.doubleValue(for: HKUnit.gram())
                        let minutesAgo = now.timeIntervalSince(sample.endDate) / 60.0
                        print("🚫 Recent carbohydrate entry found: \(String(format: "%.1f", carbGrams))g at \(String(format: "%.1f", minutesAgo)) minutes ago")
                    }
                }
                continuation.resume(returning: hasEntries)
            }
            store.execute(query)
        }
        
        return hasRecentCarbs
    }
    
    /// Fetch the timestamp of the most recent dietary carbohydrate entry
    /// - Parameter hoursBack: Number of hours to look back (default 5 hours)
    /// - Returns: The timestamp of the last carb entry, or nil if no entries found
    func fetchLastCarbEntryTimestamp(hoursBack: Double = 5.0) async throws -> Date? {
        let now = Date()
        let startDate = now.addingTimeInterval(-hoursBack * 3600) // Convert hours to seconds
        
        let predicate = HKQuery.predicateForSamples(withStart: startDate,
                                                   end: now,
                                                   options: .strictEndDate)
        
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(sampleType: carbSamples,
                                      predicate: predicate,
                                      limit: 1,
                                      sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierEndDate,
                                                                         ascending: false)]) { (_, samples, error) in
                if let error = error {
                    print("⚠️ Last carb entry fetch error: \(error.localizedDescription)")
                    continuation.resume(returning: nil)
                    return
                }
                
                guard let sample = samples?.first as? HKQuantitySample else {
                    print("ℹ️ No carbohydrate entries found in HealthKit")
                    continuation.resume(returning: nil)
                    return
                }
                
                let carbGrams = sample.quantity.doubleValue(for: HKUnit.gram())
                print("🍞 Last carb entry: \(String(format: "%.1f", carbGrams))g at \(sample.endDate)")
                continuation.resume(returning: sample.endDate)
            }
            store.execute(query)
        }
    }
    
    /// Fetch the timestamp of the most recent insulin delivery entry
    /// - Parameter hoursBack: Number of hours to look back (default 4 hours)
    /// - Returns: The timestamp of the last insulin entry, or nil if no entries found
    func fetchLastInsulinEntryTimestamp(hoursBack: Double = 4.0) async throws -> Date? {
        let now = Date()
        let startDate = now.addingTimeInterval(-hoursBack * 3600) // Convert hours to seconds
        
        let predicate = HKQuery.predicateForSamples(withStart: startDate,
                                                   end: now,
                                                   options: .strictEndDate)
        
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(sampleType: bolusSamples,
                                      predicate: predicate,
                                      limit: 1,
                                      sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierEndDate,
                                                                         ascending: false)]) { (_, samples, error) in
                if let error = error {
                    print("⚠️ Last insulin entry fetch error: \(error.localizedDescription)")
                    continuation.resume(returning: nil)
                    return
                }
                
                guard let sample = samples?.first as? HKQuantitySample else {
                    print("ℹ️ No insulin entries found in HealthKit")
                    continuation.resume(returning: nil)
                    return
                }
                
                let insulinUnits = sample.quantity.doubleValue(for: HKUnit.internationalUnit())
                print("💉 Last insulin entry: \(String(format: "%.2f", insulinUnits))U at \(sample.endDate)")
                continuation.resume(returning: sample.endDate)
            }
            store.execute(query)
        }
    }
    
    /// Fetch the most recent heart rate value (in beats per minute)
    /// - Parameter minutesBack: Number of minutes to look back (default 30 minutes)
    /// - Returns: Heart rate in beats per minute, or 70.0 as default if no recent data
    func fetchLatestHeartRate(minutesBack: Double = 30.0) async throws -> Double {
        let now = Date()
        let startDate = now.addingTimeInterval(-minutesBack * 60) // Convert minutes to seconds
        
        let predicate = HKQuery.predicateForSamples(withStart: startDate,
                                                   end: now,
                                                   options: .strictEndDate)
        
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(sampleType: heartRate,
                                      predicate: predicate,
                                      limit: 1,
                                      sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierEndDate,
                                                                         ascending: false)]) { (_, samples, error) in
                if let error = error {
                    print("⚠️ Heart rate fetch error: \(error.localizedDescription)")
                    // Return default heart rate on error
                    continuation.resume(returning: 70.0)
                    return
                }
                
                guard let sample = samples?.first as? HKQuantitySample else {
                    print("⚠️ No recent heart rate data found, using default value")
                    // Return default heart rate if no data available
                    continuation.resume(returning: 70.0)
                    return
                }
                
                let hrValue = sample.quantity.doubleValue(for: HKUnit(from: "count/min"))
                print("❤️ Latest heart rate: \(hrValue) bpm at \(sample.endDate)")
                continuation.resume(returning: hrValue)
            }
            store.execute(query)
        }
    }
    
    /// Fetch glucose data from SwiftData cache when HealthKit is unavailable
    /// - Parameters:
    ///   - modelContext: SwiftData model context
    ///   - limit: Number of recent glucose readings to fetch
    /// - Returns: Array of glucose readings with timestamps and values in mg/dL
    func fetchGlucoseFromSwiftDataCache(modelContext: ModelContext, limit: Int = 288) async throws -> [(date: Date, value: Double)] {
        print("📊 Fetching glucose data from SwiftData cache...")
        
        let now = Date()
        let startDate = now.addingTimeInterval(-2 * 3600) // Last 2 hours
        
        let fetchDescriptor = FetchDescriptor<HealthKitBGCache>(
            predicate: #Predicate<HealthKitBGCache> { cache in
                cache.timestamp >= startDate && cache.timestamp <= now
            },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        
        do {
            var descriptor = fetchDescriptor
            descriptor.fetchLimit = limit
            
            let cachedEntries = try modelContext.fetch(descriptor)
            
            if cachedEntries.isEmpty {
                print("⚠️ No cached glucose data found in SwiftData")
                throw NSError(domain: "SwiftData", code: 1, userInfo: [NSLocalizedDescriptionKey: "No cached glucose data available"])
            }
            
            // Convert to array of tuples with date and value in mg/dL
            // Keep reverse chronological order (newest first) so .first = latest reading
            let glucoseData = cachedEntries.map { cache in
                (date: cache.timestamp, value: Double(cache.bloodGlucose_mgdl))
            }
            
            print("✅ Found \(glucoseData.count) cached glucose readings")
            if let latest = glucoseData.first {
                print("📈 Latest: \(Int(latest.value)) mg/dL at \(latest.date)")
            }
            if let oldest = glucoseData.last {
                print("📉 Oldest: \(Int(oldest.value)) mg/dL at \(oldest.date)")
            }
            
            return Array(glucoseData)
        } catch {
            print("❌ Error fetching from SwiftData cache: \(error)")
            throw error
        }
    }
    
    /// Build input window from SwiftData cached glucose data
    /// - Parameter modelContext: SwiftData model context
    /// - Returns: MLMultiArray for model input
    func buildWindowFromSwiftDataCache(modelContext: ModelContext) async throws -> MLMultiArray {
        print("🔨 Building input window from SwiftData cache...")
        
        // Fetch glucose data from cache
        let glucoseData = try await fetchGlucoseFromSwiftDataCache(modelContext: modelContext, limit: 24)
        
        guard !glucoseData.isEmpty else {
            throw NSError(domain: "SwiftData", code: 2, userInfo: [NSLocalizedDescriptionKey: "No glucose data in cache"])
        }
        
        let now = Date()
        let step = 5.0 * 60  // 5 min in seconds
        
        // Create 5-minute bins for the last 2 hours (24 timesteps)
        let recentBins = (0..<24).map { i in
            now.addingTimeInterval(-Double(i) * step)
        }.reversed().map { $0 }
        
        // Initialize arrays for features
        var glucoseValues = [Double]()
        var heartRateValues = [Double]()
        var insulinValues = [Double]()
        var carbValues = [Double]()
        
        // For each bin, find the closest glucose reading
        for binTime in recentBins {
            // Find glucose value closest to this bin time
            var closestGlucose: Double = 100.0 // Default if no data
            var minTimeDiff = Double.infinity
            
            for reading in glucoseData {
                let timeDiff = abs(reading.date.timeIntervalSince(binTime))
                if timeDiff < minTimeDiff && timeDiff < step { // Within 5 minutes
                    minTimeDiff = timeDiff
                    closestGlucose = reading.value
                }
            }
            
            glucoseValues.append(closestGlucose)
            
            // For now, use default values for other features when using cache
            // In a full implementation, these could also be cached
            heartRateValues.append(70.0) // Default heart rate
            insulinValues.append(0.0)    // Will calculate IOB separately
            carbValues.append(0.0)       // Will calculate COB separately
        }
        
        // Calculate current IOB and COB using NightScout SwiftData caches first
        let (iobCache, cobCache) = Self.calculateActiveIOBandCOBFromCaches(modelContext: modelContext, now: now)
        
        // Fallback to HealthKit only if caches are empty (e.g., first run or no recent data)
        let iob = iobCache > 0.0 ? iobCache : (try? await Self.calculateActiveInsulinFromHealthKit(store: store, now: now)) ?? 0.0
        let cob = cobCache > 0.0 ? cobCache : (try? await Self.calculateActiveCarbsFromHealthKit(store: store, now: now)) ?? 0.0
        
        print("📊 Cache-based features:")
        print("   Glucose range: \(glucoseValues.min() ?? 0)-\(glucoseValues.max() ?? 0) mg/dL")
        print("   IOB (cache/HealthKit): \(String(format: "%.2f", iob)) U")
        print("   COB (cache/HealthKit): \(String(format: "%.1f", cob)) g")
        
        // Build MLMultiArray [1, 24, 8] for WaveNet models
        let array = try MLMultiArray(shape: [1, 24, 8], dataType: .double)
        
        for i in 0..<24 {
            let baseIndex = i * 8
            
            // Feature 0: Blood glucose (mg/dL)
            array[baseIndex] = NSNumber(value: glucoseValues[i])
            
            // Feature 1: Heart rate (bpm)
            array[baseIndex + 1] = NSNumber(value: heartRateValues[i])
            
            // Feature 2: Active insulin (IOB)
            array[baseIndex + 2] = NSNumber(value: iob)
            
            // Feature 3: Active carbs (COB)
            array[baseIndex + 3] = NSNumber(value: cob)
            
            // Feature 4: Time of day (0-23)
            let hour = Calendar.current.component(.hour, from: recentBins[i])
            array[baseIndex + 4] = NSNumber(value: Double(hour))
            
            // Feature 5: Glucose momentum
            let momentum = i > 0 ? glucoseValues[i] - glucoseValues[i-1] : 0.0
            array[baseIndex + 5] = NSNumber(value: momentum)
            
            // Feature 6: Minutes since last insulin
            array[baseIndex + 6] = NSNumber(value: 30.0) // Default
            
            // Feature 7: Minutes since last carbs
            array[baseIndex + 7] = NSNumber(value: 60.0) // Default
        }
        
        print("✅ Built input window from SwiftData cache")
        return array
    }
    
    // MARK: - SwiftData Cache Helpers
    /// Calculate the total active insulin and carbs using NightScout SwiftData caches.
    /// - Parameters:
    ///   - modelContext: SwiftData model context.
    ///   - now: The reference time for activity calculations.
    /// - Returns: Tuple of (activeInsulin, activeCarbs)
    static func calculateActiveIOBandCOBFromCaches(modelContext: ModelContext, now: Date = Date()) -> (Double, Double) {
        var activeInsulin: Double = 0.0
        var activeCarbs: Double = 0.0
        
        // Calculate cutoff dates outside predicates to avoid SwiftData limitations
        let insulinCutoff = now.addingTimeInterval(-4 * 3600) // 4 hours ago
        let carbCutoff = now.addingTimeInterval(-5 * 3600) // 5 hours ago
        
        // Fetch insulin cache entries within 4 hours (active window)
        let insulinFetch = FetchDescriptor<NightScoutInsulinCache>(
            predicate: #Predicate<NightScoutInsulinCache> { cache in
                cache.timestamp >= insulinCutoff
            }
        )
        if let insulinCaches = try? modelContext.fetch(insulinFetch) {
            for cache in insulinCaches {
                activeInsulin += cache.getDecayedAmount(currentTime: now)
            }
        }
        
        // Fetch carb cache entries within 5 hours (active window)
        let carbFetch = FetchDescriptor<NightScoutCarbCache>(
            predicate: #Predicate<NightScoutCarbCache> { cache in
                cache.timestamp >= carbCutoff
            }
        )
        if let carbCaches = try? modelContext.fetch(carbFetch) {
            for cache in carbCaches {
                activeCarbs += cache.getDecayedAmount(currentTime: now)
            }
        }
        
        return (activeInsulin, activeCarbs)
    }
}
