import Foundation
import SwiftData
import UIKit
import HealthKit

class RandomForestCSVExportManager {
    static let shared = RandomForestCSVExportManager()
    
    private init() {}
    
    // MARK: - Constants
    private let mmolToMgdl: Double = 18.0
    
    // MARK: - ISO-8601 formatter (Central European Time, no fractional seconds)
    private let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withColonSeparatorInTime]
        formatter.timeZone = TimeZone(identifier: "Europe/Berlin") ?? TimeZone(secondsFromGMT: 3600)!
        return formatter
    }()
    
    // MARK: - Public Entry Point
    func exportRandomForestPredictions(predictions: [RandomForestPrediction], modelContext: ModelContext) async throws -> URL {
        let csvFilePath = getCSVFilePath()
        
        // First, try to match predictions with actual readings using cached data
        let matchingService = RandomForestPredictionMatchingService()
        let matchedCount = try await matchingService.matchPredictionsWithActualReadings(predictions: predictions, modelContext: modelContext)
        print("🌲 Matched \(matchedCount) Random Forest predictions with actual readings")
        
        // Create CSV header
        let header = createCSVHeader()
        
        // Build CSV content
        var csvContent = header + "\r\n"
        
        // Sort predictions chronologically and renumber them sequentially for perfect order
        let sortedPredictions = predictions.sorted(by: { $0.timestamp < $1.timestamp })
        print("📅 Reordered \(sortedPredictions.count) predictions chronologically for CSV export")
        
        for (index, prediction) in sortedPredictions.enumerated() {
            let isoTimestamp = timestampFormatter.string(from: prediction.timestamp)
            var csvLine = isoTimestamp
            
            // Add sequential prediction count (1-based) ordered by timestamp
            let sequentialCount = index + 1
            csvLine += ",\(sequentialCount)"
            
            // Add Random Forest prediction values
            let pred_mmol = String(format: "%.2f", prediction.predictionMmol)
            let pred_mgdl = String(format: "%.0f", prediction.predictionMmol * 18.0)
            csvLine += ",\(pred_mmol),\(pred_mgdl)"
            
            // Add actual BG reading (20 minutes after prediction)
            if prediction.actualBG_mmol > 0 {
                let actualBG_mmol = String(format: "%.2f", prediction.actualBG_mmol)
                let actualBG_mgdl = String(prediction.actualBG_mgdl)
                csvLine += ",\(actualBG_mmol),\(actualBG_mgdl)"
            } else {
                csvLine += ",," // Empty values if no actual reading found
            }
            
            // Add carb timing data
            if let lastCarbTimestamp = prediction.lastCarbEntryTimestamp, prediction.timeSinceLastCarb_minutes >= 0 {
                let carbTimestampString = timestampFormatter.string(from: lastCarbTimestamp)
                let timeSinceCarb = String(format: "%.1f", prediction.timeSinceLastCarb_minutes)
                csvLine += ",\(carbTimestampString),\(timeSinceCarb)"
            } else {
                // No carb entry found - leave both cells empty
                csvLine += ",,"
            }
            
            // Add insulin timing data
            if let lastInsulinTimestamp = prediction.lastInsulinEntryTimestamp, prediction.timeSinceLastInsulin_minutes >= 0 {
                let insulinTimestampString = timestampFormatter.string(from: lastInsulinTimestamp)
                let timeSinceInsulin = String(format: "%.1f", prediction.timeSinceLastInsulin_minutes)
                csvLine += ",\(insulinTimestampString),\(timeSinceInsulin)"
            } else {
                // No insulin entry found - leave both cells empty
                csvLine += ",,"
            }
            
            csvContent += csvLine + "\r\n"
        }
        
        // Write to file
        try csvContent.write(to: csvFilePath, atomically: true, encoding: .utf8)
        
        print("🌲 Exported \(predictions.count) Random Forest predictions to CSV: \(csvFilePath.lastPathComponent)")
        return csvFilePath
    }
    
    // MARK: - Helper Functions
    
    private func createCSVHeader() -> String {
        let columns: [String] = [
            "Timestamp_CET",
            "Prediction_Count",
            "RandomForest_Prediction_20min_mmol",
            "RandomForest_Prediction_20min_mgdl",
            "Actual_BG_After_20min_mmol",
            "Actual_BG_After_20min_mgdl",
            "Last_Carb_Entry_Timestamp",
            "Time_Since_Last_Carb_Minutes",
            "Last_Insulin_Entry_Timestamp",
            "Time_Since_Last_Insulin_Minutes"
        ]
        
        return columns.joined(separator: ",")
    }
    
    private func getCSVFilePath() -> URL {
        let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documentsDirectory.appendingPathComponent("random_forest_predictions.csv")
    }
    
    // MARK: - File Access
    
    func getCSVFileURL() -> URL {
        return getCSVFilePath()
    }
}

// MARK: - Random Forest Prediction Matching Service

class RandomForestPredictionMatchingService {
    private let healthKitManager = HealthKitManager()
    
    /// Matches Random Forest predictions with actual HealthKit values for export
    /// - Parameters:
    ///   - predictions: Array of RandomForestPrediction objects to match
    ///   - modelContext: The SwiftData model context
    /// - Returns: The number of predictions that had valid future readings
    @discardableResult
    func matchPredictionsWithActualReadings(predictions: [RandomForestPrediction], modelContext: ModelContext) async throws -> Int {
        print("🔄 Starting Random Forest prediction matching process...")
        
        if predictions.isEmpty {
            print("ℹ️ No Random Forest predictions found to match")
            return 0
        }
        
        print("🌲 Found \(predictions.count) Random Forest predictions to match")
        
        // Determine time range to check in HealthKit
        guard let oldestPrediction = predictions.map({ $0.timestamp }).min(),
              let newestPrediction = predictions.map({ $0.timestamp }).max() else {
            return 0
        }
        
        let startDate = oldestPrediction
        let endDate = max(newestPrediction.addingTimeInterval(24 * 3600), Date())
        
        print("📆 Time range: \(startDate.formatted()) to \(endDate.formatted())")
        
        // Fetch all glucose readings from HealthKit in this time range
        let samples = try await healthKitManager.fetchGlucoseForTimeRange(startDate: startDate, endDate: endDate)
        
        if samples.isEmpty {
            print("ℹ️ No HealthKit samples found in the time range")
            return 0
        }
        
        print("🌲 Found \(samples.count) HealthKit glucose samples for Random Forest matching")
        
        var matchedCount = 0
        
        // Process each prediction and find future matches
        for prediction in predictions {
            // The target time is EXACTLY 20 minutes after the prediction timestamp
            let targetTime = prediction.timestamp.addingTimeInterval(20 * 60)
            
            // Filter samples to ONLY include those that occurred AFTER the prediction time
            let futureSamples = samples.filter { $0.startDate > prediction.timestamp }
            
            if futureSamples.isEmpty {
                continue
            }
            
            // Find the closest future sample within a reasonable window (5 minutes)
            if let (sample, value) = findClosestFutureReading(targetTime: targetTime, in: futureSamples, toleranceMinutes: 5) {
                let timeDifferenceMinutes = (sample.startDate.timeIntervalSince1970 - prediction.timestamp.timeIntervalSince1970) / 60.0
                
                print("✅ Found future match for Random Forest prediction at \(prediction.timestamp.formatted()):")
                print("   → Prediction time: \(prediction.timestamp.formatted())")
                print("   → Actual reading time: \(sample.startDate.formatted())")
                print("   → Time difference: \(String(format: "%.1f", timeDifferenceMinutes)) minutes after prediction")
                
                // Only consider this a valid match if it's between 15-25 minutes after prediction
                if timeDifferenceMinutes >= 15 && timeDifferenceMinutes <= 25 {
                    prediction.setActualBG(mmol: value, timestamp: sample.startDate)
                    matchedCount += 1
                } else {
                    // Clear the value if it's outside our desired window
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
        
        // Save the context with all updates
        try modelContext.save()
        
        if matchedCount > 0 {
            print("✅ Successfully matched \(matchedCount) Random Forest predictions with future readings")
        } else {
            print("⚠️ No Random Forest predictions were matched with valid future readings")
        }
        
        return matchedCount
    }
    
    /// Finds the closest future glucose reading to a target time within a tolerance window
    private func findClosestFutureReading(targetTime: Date, in samples: [HKQuantitySample], toleranceMinutes: Double = 5.0) -> (sample: HKQuantitySample, value: Double)? {
        let toleranceSeconds = toleranceMinutes * 60
        
        var closestSample: HKQuantitySample? = nil
        var minTimeDifference = Double.infinity
        
        for sample in samples {
            let timeDifference = abs(sample.startDate.timeIntervalSince(targetTime))
            
            if timeDifference <= toleranceSeconds && timeDifference < minTimeDifference {
                minTimeDifference = timeDifference
                closestSample = sample
            }
        }
        
        if let sample = closestSample {
            let unit = HKUnit(from: "mg/dL")
            let valueInMgdl = sample.quantity.doubleValue(for: unit)
            let valueInMmol = valueInMgdl / 18.0 // Convert to mmol/L
            
            return (sample, valueInMmol)
        }
        
        return nil
    }
}
