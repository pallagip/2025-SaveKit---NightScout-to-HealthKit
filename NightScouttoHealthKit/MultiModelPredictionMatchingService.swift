//
//  MultiModelPredictionMatchingService.swift
//  NightScouttoHealthKit
//
//  Created by Patrick Pallagi on 2025-07-12.
//

import Foundation
import SwiftData
import HealthKit

/// A specialized service for matching MultiModelPrediction records with actual values for CSV exports
/// This service finds real blood glucose readings that occurred ~20 minutes after predictions
class MultiModelPredictionMatchingService {
    private let healthKitManager = HealthKitManager()
    
    /// Matches predictions with actual HealthKit values specifically for export
    /// This updates MultiModelPrediction records with correct future readings
    /// - Parameter predictions: Array of MultiModelPrediction records to match
    /// - Returns: The number of predictions that had valid future readings
    @discardableResult
    func matchPredictionsWithActualReadings(predictions: [MultiModelPrediction]) async throws -> Int {
        print("🔄 Starting MultiModelPrediction matching process...")
        
        if predictions.isEmpty {
            print("ℹ️ No predictions found to match")
            return 0
        }
        
        print("📊 Found \(predictions.count) predictions to match")
        
        // Determine time range to check in HealthKit
        guard let oldestPrediction = predictions.map({ $0.timestamp }).min(),
              let newestPrediction = predictions.map({ $0.timestamp }).max() else {
            return 0
        }
        
        // Use a larger window to ensure we find all possible matches
        let startDate = oldestPrediction // Start from the first prediction time
        
        // End time should include the current time plus buffer for future predictions
        // Add 24 hours to newest prediction to be safe
        let endDate = max(newestPrediction.addingTimeInterval(24 * 3600), Date())
        
        print("📆 Time range: \(startDate.formatted()) to \(endDate.formatted())")
        
        // Fetch all glucose readings from HealthKit in this time range
        let samples = try await healthKitManager.fetchGlucoseForTimeRange(startDate: startDate, endDate: endDate)
        
        if samples.isEmpty {
            print("ℹ️ No HealthKit samples found in the time range")
            return 0
        }
        
        print("📊 Found \(samples.count) HealthKit glucose samples for matching")
        
        // Counter for matched predictions
        var matchedCount = 0
        
        // Process each prediction and find future matches
        for prediction in predictions {
            // The target time is EXACTLY 20 minutes after the prediction timestamp
            let targetTime = prediction.timestamp.addingTimeInterval(20 * 60) // Exactly 20 minutes later
            
            // Filter samples to ONLY include those that occurred AFTER the prediction time
            let futureSamples = samples.filter { $0.startDate > prediction.timestamp }
            
            if futureSamples.isEmpty {
                // Skip if no future samples
                continue
            }
            
            // Find the closest future sample within a reasonable window (5 minutes)
            if let (sample, value) = findClosestFutureReading(targetTime: targetTime, in: futureSamples, toleranceMinutes: 5) {
                // Calculate time difference
                let timeDifferenceMinutes = (sample.startDate.timeIntervalSince1970 - prediction.timestamp.timeIntervalSince1970) / 60.0
                
                print("✅ Found future match for prediction at \(prediction.timestamp.formatted()):")
                print("   → Prediction time: \(prediction.timestamp.formatted())")
                print("   → Actual reading time: \(sample.startDate.formatted())")
                print("   → Time difference: \(String(format: "%.1f", timeDifferenceMinutes)) minutes after prediction")
                
                // Only consider this a valid match for export if it's between 15-25 minutes after prediction
                if timeDifferenceMinutes >= 15 && timeDifferenceMinutes <= 25 {
                    // Update the prediction with actual BG data
                    prediction.setActualBG(mmol: value, timestamp: sample.startDate)
                    matchedCount += 1
                } else {
                    // Clear any existing values if it's outside our desired window
                    prediction.actualBG_mmol = 0.0
                    prediction.actualBG_mgdl = 0
                    prediction.actualBGTimestamp = nil
                    print("   → Ignoring match: Time difference outside 15-25 minute window")
                }
            } else {
                // Clear any existing values if no proper future match was found
                prediction.actualBG_mmol = 0.0
                prediction.actualBG_mgdl = 0
                prediction.actualBGTimestamp = nil
            }
        }
        
        if matchedCount > 0 {
            print("✅ Successfully matched \(matchedCount) predictions with future readings")
        } else {
            print("⚠️ No predictions were matched with valid future readings")
        }
        
        return matchedCount
    }
    
    /// Finds the closest future glucose reading to a target time within a tolerance window
    /// - Parameters:
    ///   - targetTime: The exact target timestamp to match
    ///   - samples: Array of future HKQuantitySamples to search within
    ///   - toleranceMinutes: Maximum time difference in minutes
    /// - Returns: The closest matching sample and its value in mmol/L, or nil if none found
    private func findClosestFutureReading(targetTime: Date, in samples: [HKQuantitySample], toleranceMinutes: Double = 5.0) -> (sample: HKQuantitySample, value: Double)? {
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
}
