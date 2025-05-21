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
        
        // Add an extra hour to the end time to account for the delay in getting actual readings
        let startDate = oldestPrediction
        let endDate = max(newestPrediction.addingTimeInterval(3600), Date())
        
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
            
            // Find the closest glucose reading to this prediction's expected time
            // (which should be 20 minutes after the prediction time)
            if let (sample, value) = healthKitManager.findClosestGlucoseReading(to: prediction.timestamp, in: samples) {
                // Calculate time difference in minutes for logging
                let timeDifferenceMinutes = abs(sample.startDate.timeIntervalSince(prediction.timestamp.addingTimeInterval(20 * 60))) / 60
                
                print("✅ Found match for prediction at \(prediction.formattedDate):")
                print("   → Actual BG: \(String(format: "%.1f", value)) mmol/L")
                print("   → Time difference: \(String(format: "%.1f", timeDifferenceMinutes)) minutes")
                
                // Update the prediction
                prediction.actualBG = value
                prediction.actualBGTimestamp = sample.startDate
                updatedCount += 1
            }
        }
        
        // Save the context with all updates
        if updatedCount > 0 {
            try context.save()
            print("✅ Successfully updated \(updatedCount) predictions with actual values")
        } else {
            print("ℹ️ No predictions were updated with actual values")
        }
        
        return updatedCount
    }
}
