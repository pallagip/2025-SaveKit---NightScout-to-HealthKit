//
//  HealthKitFeatureProvider.swift
//  NightScouttoHealthKit
//
//  Created by Patrick Pallagi on 2025-05-20.
//

import HealthKit
import CoreML
import Combine

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
        try await store.requestAuthorization(toShare: [], read: [
            glucose, heartRate, carbSamples, bolusSamples
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
            let bolus = try await latestValue(of: bolusSamples,
                                             upTo: anchor,
                                             unit: HKUnit.internationalUnit(),
                                             deliveryReason: .bolus)
            extendedBolusDose.append(bolus)
        }
        
        // Fetch carb intake from the last 3 hours at 15-minute intervals
        let carbsBins = stride(from: carbsStartTime.timeIntervalSince1970, 
                               to: now.timeIntervalSince1970, 
                               by: 15 * 60).map { Date(timeIntervalSince1970: $0) }
        
        for anchor in carbsBins {
            let carbs = try await latestValue(of: carbSamples,
                                             upTo: anchor,
                                             unit: HKUnit.gram())
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
        
        // Calculate active insulin with longer history
        func calculateActiveInsulin(doses: [Double], λ: Double = 0.028) -> Double {
            // Exponential decay model for insulin (λ = 0.028 h⁻¹)
            var activeInsulin = 0.0
            for (index, dose) in doses.enumerated() {
                // Calculate time since dose in hours (15-minute intervals)
                let timeInHours = Double(doses.count - 1 - index) * (15.0 / 60.0)
                // Apply exponential decay
                activeInsulin += dose * exp(-λ * timeInHours)
            }
            return activeInsulin
        }
        
        // Calculate active carbs with longer history
        func calculateActiveCarbs(doses: [Double], λ: Double = 0.028) -> Double {
            // Similar exponential decay model for carbs
            var activeCarbs = 0.0
            for (index, dose) in doses.enumerated() {
                // Calculate time since intake in hours (15-minute intervals)
                let timeInHours = Double(doses.count - 1 - index) * (15.0 / 60.0)
                // Apply exponential decay
                activeCarbs += dose * exp(-λ * timeInHours)
            }
            return activeCarbs
        }
        
        // Calculate total active insulin from extended history
        let totalActiveInsulin = calculateActiveInsulin(doses: extendedBolusDose)
        
        // Calculate total active carbs from extended history
        let totalActiveCarbs = calculateActiveCarbs(doses: extendedCarbsDose)
        
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
        
        // ---- to MLMultiArray -------------------------------------------------
        let x = try MLMultiArray(shape: [1, 8, 4], dataType: .float32)
        var idx = 0
        for t in 0..<8 {
            x[idx] = NSNumber(value: hr[t]);         idx += 1
            x[idx] = NSNumber(value: bg[t]);         idx += 1
            x[idx] = NSNumber(value: actIns[t]);     idx += 1
            x[idx] = NSNumber(value: opCarbs[t]);    idx += 1
        }
        
        print("🔄 Insulin considered from the last 4 hours, carbs from the last 3 hours")
        print("💉 Total active insulin: \(String(format: "%.2f", totalActiveInsulin)) IU")
        print("🍞 Total active carbs: \(String(format: "%.2f", totalActiveCarbs)) g")
        
        return x
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
}
