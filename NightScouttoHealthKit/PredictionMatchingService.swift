//
//  PredictionMatchingService.swift
//  NightScouttoHealthKit
//
//  Created by Patrick Pallagi on 2025-05-21.
//

import Foundation
import SwiftData
import HealthKit

/// Service responsible for matching predictions with actual HealthKit blood glucose readings
class PredictionMatchingService {
    private let healthKitManager = HealthKitManager()
    
    /// Fetches actual blood glucose readings from HealthKit and matches them with predictions
    /// stored in SwiftData
    /// - Parameters:
    ///   - context: The SwiftData model context
    ///   - days: Number of days of history to process (default: 1 day)
    /// - Returns: The number of predictions that were updated with actual values
    @discardableResult
    func matchPredictionsWithActualValues(context: ModelContext, days: Int = 1) async throws -> Int {
        print("🔄 Starting to match predictions with actual HealthKit values...")
        
        // Fetch predictions from SwiftData that don't have actual BG values yet
        var descriptor = FetchDescriptor<Prediction>(predicate: nil, sortBy: [SortDescriptor(\.timestamp)])
        
        // Use a simple filter instead of a predicate for compatibility
        descriptor.includePendingChanges = true
        
        // Fetch all predictions sorted by timestamp
        let allPredictions = try context.fetch(descriptor)
        
        // Manually filter to find predictions without actual BG values
        let predictions = allPredictions.filter { $0.actualBG == 0.0 }
        
        if predictions.isEmpty {
            print("ℹ️ No predictions found that need matching with actual values")
            return 0
        }
        
        print("📊 Found \(predictions.count) predictions to match with actual values")
        
        // Determine time range to check in HealthKit
        guard let oldestPrediction = predictions.first?.timestamp,
              let newestPrediction = predictions.last?.timestamp else {
            return 0
        }
        
        // Add a much larger window to ensure we find matches
        // Start 1 hour before the oldest prediction to account for readings that happened just before predictions
        let startDate = oldestPrediction.addingTimeInterval(-3600)
        
        // End time should include the current time plus enough buffer to find matches for recent predictions
        // We'll use a 24-hour window from the newest prediction to be safe
        let endDate = max(newestPrediction.addingTimeInterval(24 * 3600), Date())
        
        print("📆 Time range: \(startDate.formatted()) to \(endDate.formatted())")
        
        // Fetch all glucose readings from HealthKit in this time range
        let samples = try await healthKitManager.fetchGlucoseForTimeRange(startDate: startDate, endDate: endDate)
        
        if samples.isEmpty {
            print("ℹ️ No HealthKit samples found in the time range")
            return 0
        }
        
        print("📊 Found \(samples.count) HealthKit glucose samples to match with predictions")
        
        // Counter for updated predictions
        var updatedCount = 0
        
        // Process each prediction and find matching actual value
        for prediction in predictions {
            // Skip if this prediction already has an actual BG value
            if prediction.actualBG > 0 {
                continue
            }
            
            // The target time is approximately 20 minutes after the prediction timestamp
            // This is when we expect to have the actual glucose reading to compare against
            let targetTime = prediction.timestamp.addingTimeInterval(20 * 60) // 20 minutes later
            
            print("🔍 Looking for match near \(targetTime.formatted())") // for debugging
            
            // Use an extended tolerance window (60 minutes instead of the default 30)
            if let (sample, value) = healthKitManager.findClosestGlucoseReading(to: prediction.timestamp, in: samples, tolerance: 3600) {
                // Calculate time difference in minutes for logging
                let predictionTime = prediction.timestamp
                let actualTime = sample.startDate
                let timeDifferenceMinutes = abs(actualTime.timeIntervalSince(predictionTime.addingTimeInterval(20 * 60))) / 60
                
                print("✅ Found match for prediction at \(prediction.formattedDate):")
                print("   → Prediction time: \(predictionTime.formatted())")
                print("   → Actual reading time: \(actualTime.formatted())")
                print("   → Actual BG: \(String(format: "%.1f", value)) mmol/L")
                print("   → Time difference: \(String(format: "%.1f", timeDifferenceMinutes)) minutes from expected")
                
                // Update the prediction
                prediction.actualBG = value
                prediction.actualBGTimestamp = sample.startDate
                updatedCount += 1
            } else {
                print("⚠️ No match found for prediction at \(prediction.formattedDate)")
            }
        }
        
        // Save the context with all updates
        if updatedCount > 0 {
            try context.save()
            print("✅ Successfully updated \(updatedCount) predictions with actual values")
        } else {
            print("⚠️ No predictions were updated with actual values")
            
            // Extra debugging to help diagnose the issue
            print("💡 DEBUG INFO: Found \(samples.count) total samples in time range")
            if !samples.isEmpty {
                print("💡 First sample time: \(samples.first!.startDate.formatted())")
                print("💡 Last sample time: \(samples.last!.startDate.formatted())")
            }
        }
        
        return updatedCount
    }
}
