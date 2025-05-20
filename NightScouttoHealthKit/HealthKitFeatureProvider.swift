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

        let now   = Date()
        let step  = 5.0 * 60        // 5 min in seconds
        let bins  = stride(from: 7, through: 0, by: -1).map { now.addingTimeInterval(-Double($0) * step) }

        // arrays we'll fill
        var hr  = [Double]()
        var bg  = [Double]()
        var carbsDose = [Double]()
        var bolusDose = [Double]()

        // fetch each 5-min bin
        for anchor in bins {
            hr.append(try await latestValue(of: heartRate,
                                            upTo: anchor,
                                            unit: HKUnit(from: "count/min")))
            bg.append(try await latestValue(of: glucose,
                                            upTo: anchor,
                                            unit: HKUnit(from: "mg/dL")))
            carbsDose.append(try await latestValue(of: carbSamples,
                                                   upTo: anchor,
                                                   unit: HKUnit.gram()))
            bolusDose.append(try await latestValue(of: bolusSamples,
                                                   upTo: anchor,
                                                   unit: HKUnit.internationalUnit(),
                                                   deliveryReason: .bolus))
        }

        // convert bolus + carbs to active / operative via e-decay (λ = 0.028 h-¹)
        func expDecay(_ doses: [Double], λ: Double = 0.028) -> [Double] {
            var out = [Double](repeating: 0, count: doses.count)
            out[0] = doses[0]
            for i in 1..<doses.count {
                out[i] = out[i - 1] * exp(-λ * 5 / 60) + doses[i]   // 5-min step
            }
            return out
        }

        let actIns  = expDecay(bolusDose)
        let opCarbs = expDecay(carbsDose)

        // ---- to MLMultiArray -------------------------------------------------
        let x = try MLMultiArray(shape: [1, 8, 4], dataType: .float32)
        var idx = 0
        for t in 0..<8 {
            x[idx] = NSNumber(value: hr[t]);         idx += 1
            x[idx] = NSNumber(value: bg[t]);         idx += 1
            x[idx] = NSNumber(value: actIns[t]);     idx += 1
            x[idx] = NSNumber(value: opCarbs[t]);    idx += 1
        }
        return x
    }
}
