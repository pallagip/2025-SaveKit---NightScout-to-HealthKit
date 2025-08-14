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
/// Updated to use cached HealthKit BG data for improved performance
class MultiModelPredictionMatchingService {
    private let healthKitManager = HealthKitManager()
    
    /// Matches predictions with actual HealthKit values specifically for export using cached data
    /// This updates MultiModelPrediction records with correct future readings from SwiftData cache
    /// - Parameters:
    ///   - predictions: Array of MultiModelPrediction records to match
    ///   - modelContext: SwiftData model context to access cached BG readings
    /// - Returns: The number of predictions that had valid future readings
    @discardableResult
    func matchPredictionsWithActualReadings(predictions: [MultiModelPrediction], modelContext: ModelContext) async throws -> Int {
        print("🔄 Starting MultiModelPrediction matching process using cached data...")
        
        if predictions.isEmpty {
            print("ℹ️ No predictions found to match")
            return 0
        }
        
        print("📊 Found \(predictions.count) predictions to match")
        
        // Determine time range to check in cached data
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
        
        // Fetch all cached glucose readings in this time range
        let cachedReadings = try fetchCachedBGReadings(from: startDate, to: endDate, modelContext: modelContext)
        
        if cachedReadings.isEmpty {
            print("ℹ️ No cached BG readings found in the time range")
            print("💡 Tip: Use 'Cache HealthKit BG Data' button to sync HealthKit data first")
            return 0
        }
        
        print("📊 Found \(cachedReadings.count) cached BG readings for matching")
        
        // Counter for matched predictions
        var matchedCount = 0
        
        // Process each prediction and find future matches
        for prediction in predictions {
            // The target time is EXACTLY 20 minutes after the prediction timestamp
            let targetTime = prediction.timestamp.addingTimeInterval(20 * 60) // Exactly 20 minutes later
            
            // Filter cached readings to ONLY include those that occurred AFTER the prediction time
            let futureReadings = cachedReadings.filter { $0.timestamp > prediction.timestamp }
            
            if futureReadings.isEmpty {
                // Skip if no future readings
                continue
            }
            
            // Find the closest future reading within a reasonable window (5 minutes)
            if let (reading, value) = findClosestFutureCachedReading(targetTime: targetTime, in: futureReadings, toleranceMinutes: 5) {
                // Calculate time difference
                let timeDifferenceMinutes = (reading.timestamp.timeIntervalSince1970 - prediction.timestamp.timeIntervalSince1970) / 60.0
                
                print("✅ Found future match for prediction at \(prediction.timestamp.formatted()):")
                print("   → Prediction time: \(prediction.timestamp.formatted())")
                print("   → Actual reading time: \(reading.timestamp.formatted())")
                print("   → Time difference: \(String(format: "%.1f", timeDifferenceMinutes)) minutes after prediction")
                
                // Only consider this a valid match for export if it's between 15-25 minutes after prediction
                if timeDifferenceMinutes >= 15 && timeDifferenceMinutes <= 25 {
                    // Update the prediction with actual BG data
                    prediction.setActualBG(mmol: value, timestamp: reading.timestamp)
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
    
    /// Finds the closest future glucose reading to a target time within a tolerance window using cached data
    /// - Parameters:
    ///   - targetTime: The exact target timestamp to match
    ///   - readings: Array of future HealthKitBGCache readings to search within
    ///   - toleranceMinutes: Maximum time difference in minutes
    /// - Returns: The closest matching reading and its value in mmol/L, or nil if none found
    private func findClosestFutureCachedReading(targetTime: Date, in readings: [HealthKitBGCache], toleranceMinutes: Double = 5.0) -> (reading: HealthKitBGCache, value: Double)? {
        // Convert tolerance to seconds
        let toleranceSeconds = toleranceMinutes * 60
        
        // Find the closest reading by time difference
        var closestReading: HealthKitBGCache? = nil
        var minTimeDifference = Double.infinity
        
        for reading in readings {
            let timeDifference = abs(reading.timestamp.timeIntervalSince(targetTime))
            
            // Only consider readings within the tolerance window
            if timeDifference <= toleranceSeconds && timeDifference < minTimeDifference {
                minTimeDifference = timeDifference
                closestReading = reading
            }
        }
        
        // If we found a matching reading, return it along with its value in mmol/L
        if let reading = closestReading {
            return (reading, reading.bloodGlucose_mmol)
        }
        
        return nil
    }
    
    /// Fetches cached BG readings from SwiftData within a time range
    /// - Parameters:
    ///   - startDate: Start of the time range
    ///   - endDate: End of the time range
    ///   - modelContext: SwiftData model context
    /// - Returns: Array of cached BG readings within the time range
    private func fetchCachedBGReadings(from startDate: Date, to endDate: Date, modelContext: ModelContext) throws -> [HealthKitBGCache] {
        let predicate = #Predicate<HealthKitBGCache> { cache in
            cache.timestamp >= startDate && cache.timestamp <= endDate
        }
        
        let descriptor = FetchDescriptor<HealthKitBGCache>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.timestamp, order: .forward)]
        )
        
        return try modelContext.fetch(descriptor)
    }

    // MARK: - Backfill insulin/carb associations from SwiftData caches
    /// Associates each prediction with the latest insulin/carb cache entry that occurred before it
    /// within 4h (insulin) and 5h (carbs) windows. Useful to fix predictions created when HealthKit
    /// was unavailable (e.g., background mode).
    /// - Returns: Tuple counts of updated insulin and carb associations
    @discardableResult
    func backfillInsulinAndCarbAssociations(predictions: [MultiModelPrediction], modelContext: ModelContext) throws -> (updatedInsulin: Int, updatedCarb: Int) {
        if predictions.isEmpty { return (0, 0) }
        var insulinUpdated = 0
        var carbUpdated = 0
        
        for prediction in predictions {
            let pTime = prediction.timestamp
            
            // Backfill insulin (4h window) if missing/invalid
            let needsInsulin = prediction.lastInsulinEntryTimestamp == nil ||
                prediction.timeSinceLastInsulin_minutes < 0 ||
                (prediction.lastInsulinEntryTimestamp != nil && pTime.timeIntervalSince(prediction.lastInsulinEntryTimestamp!) > 4 * 3600)
            if needsInsulin {
                let start = pTime.addingTimeInterval(-4 * 3600)
                let fetch = FetchDescriptor<NightScoutInsulinCache>(
                    predicate: #Predicate<NightScoutInsulinCache> { cache in
                        cache.timestamp >= start && cache.timestamp <= pTime
                    },
                    sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
                )
                if let found = try modelContext.fetch(fetch).first {
                    prediction.setInsulinTiming(lastInsulinTimestamp: found.timestamp, predictionTimestamp: pTime)
                    insulinUpdated += 1
                } else {
                    // Clear to indicate no valid insulin within 4h
                    prediction.setInsulinTiming(lastInsulinTimestamp: nil, predictionTimestamp: pTime)
                }
            }
            
            // Backfill carbs (5h window) if missing/invalid
            let needsCarb = prediction.lastCarbEntryTimestamp == nil ||
                prediction.timeSinceLastCarb_minutes < 0 ||
                (prediction.lastCarbEntryTimestamp != nil && pTime.timeIntervalSince(prediction.lastCarbEntryTimestamp!) > 5 * 3600)
            if needsCarb {
                let start = pTime.addingTimeInterval(-5 * 3600)
                let fetch = FetchDescriptor<NightScoutCarbCache>(
                    predicate: #Predicate<NightScoutCarbCache> { cache in
                        cache.timestamp >= start && cache.timestamp <= pTime
                    },
                    sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
                )
                if let found = try modelContext.fetch(fetch).first {
                    prediction.setCarbTiming(lastCarbTimestamp: found.timestamp, predictionTimestamp: pTime)
                    carbUpdated += 1
                } else {
                    // Clear to indicate no valid carbs within 5h
                    prediction.setCarbTiming(lastCarbTimestamp: nil, predictionTimestamp: pTime)
                }
            }
        }
        return (insulinUpdated, carbUpdated)
    }
}
