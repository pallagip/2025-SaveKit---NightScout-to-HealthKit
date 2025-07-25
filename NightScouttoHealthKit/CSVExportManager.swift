import Foundation
import SwiftData
import UIKit
import HealthKit
import CoreML

class CSVExportManager {
    static let shared = CSVExportManager()
    
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
    
    // MARK: - Model Color Map
    // Color scheme for WaveNet models 1-5 in CSV visualization
    private let modelColors: [String: [String: String]] = [
        "WaveNet1": ["base": "#007AFF", "mmol": "#66B3FF", "mgdl": "#0056CC"], // Blue
        "WaveNet2": ["base": "#34C759", "mmol": "#7DD87F", "mgdl": "#28A745"], // Green
        "WaveNet3": ["base": "#FF9500", "mmol": "#FFB84D", "mgdl": "#CC7700"], // Orange
        "WaveNet4": ["base": "#FF3B30", "mmol": "#FF7A73", "mgdl": "#CC2E26"], // Red
        "WaveNet5": ["base": "#AF52DE", "mmol": "#C785E8", "mgdl": "#8C42B1"]  // Purple
    ]
    
    // MARK: - Public Entry Point
    func exportStoredPredictions(predictions: [MultiModelPrediction], modelContext: ModelContext) async throws -> URL {
        let csvFilePath = getCSVFilePath()
        
        // First, try to match predictions with actual readings
        let matchingService = MultiModelPredictionMatchingService()
        let matchedCount = try await matchingService.matchPredictionsWithActualReadings(predictions: predictions)
        print("📊 Matched \(matchedCount) predictions with actual readings")
        
        // Create CSV header
        let header = createCSVHeader()
        
        // Build CSV content
        var csvContent = header + "\r\n"
        
        // Fetch average predictions from SwiftData
        let averagePredictions = try fetchAveragePredictions(from: modelContext)
        print("📊 Found \(averagePredictions.count) average predictions in SwiftData")
        
        for prediction in predictions.sorted(by: { $0.timestamp < $1.timestamp }) {
            let isoTimestamp = timestampFormatter.string(from: prediction.timestamp)
            var csvLine = isoTimestamp
            
            // WaveNet models 1-5 data
            let modelData = [
                (prediction.m1_pred_mmol, prediction.m1_pred_mgdl),
                (prediction.m2_pred_mmol, prediction.m2_pred_mgdl),
                (prediction.m3_pred_mmol, prediction.m3_pred_mgdl),
                (prediction.m4_pred_mmol, prediction.m4_pred_mgdl),
                (prediction.m5_pred_mmol, prediction.m5_pred_mgdl)
            ]
            
            for (predMmol, predMgdl) in modelData {
                let currentBG_mmol = String(format: "%.2f", prediction.currentBG_mmol)
                let currentBG_mgdl = String(prediction.currentBG_mgdl)
                let pred_mmol = String(format: "%.2f", predMmol)
                let pred_mgdl = String(predMgdl)
                
                csvLine += ",\(currentBG_mmol),\(currentBG_mgdl),\(pred_mmol),\(pred_mgdl)"
            }
            
            // Add average prediction data (find matching timestamp within 30 seconds)
            if let avgPrediction = findMatchingAveragePrediction(for: prediction.timestamp, in: averagePredictions) {
                let avgPred_mmol = String(format: "%.2f", avgPrediction.predictionValue)
                let avgPred_mgdl = String(Int(round(avgPrediction.predictionValue * 18.0)))
                csvLine += ",\(avgPred_mmol),\(avgPred_mgdl)"
            } else {
                csvLine += ",," // Empty values if no average prediction found
            }
            
            // Add actual BG reading (20 minutes after prediction)
            if prediction.actualBG_mmol > 0 {
                let actualBG_mmol = String(format: "%.2f", prediction.actualBG_mmol)
                let actualBG_mgdl = String(prediction.actualBG_mgdl)
                csvLine += ",\(actualBG_mmol),\(actualBG_mgdl)"
            } else {
                csvLine += ",," // Empty values if no actual reading found
            }
            
            csvContent += csvLine + "\r\n"
        }
        
        // Write to file
        try csvContent.write(to: csvFilePath, atomically: true, encoding: .utf8)
        
        print("📊 Exported \(predictions.count) predictions to CSV: \(csvFilePath.lastPathComponent)")
        return csvFilePath
    }
    
    // MARK: - Helper Functions
    
    private func createCSVHeader() -> String {
        var columns: [String] = ["Timestamp_CET"]
        
        // Add columns for WaveNet models 1-5
        for modelNum in 1...5 {
            columns += [
                "WaveNet\(modelNum)_Current_BG_mmol",
                "WaveNet\(modelNum)_Current_BG_mgdl",
                "WaveNet\(modelNum)_Pred_20min_mmol",
                "WaveNet\(modelNum)_Pred_20min_mgdl"
            ]
        }
        
        // Add average prediction columns
        columns += [
            "Average_Pred_20min_mmol",
            "Average_Pred_20min_mgdl"
        ]
        
        // Add actual BG columns at the end
        columns += [
            "Actual_BG_After_20min_mmol",
            "Actual_BG_After_20min_mgdl"
        ]
        return columns.joined(separator: ",")
    }
    
    private func getCSVFilePath() -> URL {
        let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documentsDirectory.appendingPathComponent("predictions.csv")
    }
    
    // MARK: - Average Prediction Helpers
    
    private func fetchAveragePredictions(from modelContext: ModelContext) throws -> [Prediction] {
        let descriptor = FetchDescriptor<Prediction>(
            predicate: #Predicate<Prediction> { prediction in
                prediction.isAveragePrediction == true
            },
            sortBy: [SortDescriptor(\Prediction.timestamp, order: .forward)]
        )
        return try modelContext.fetch(descriptor)
    }
    
    private func findMatchingAveragePrediction(for timestamp: Date, in averagePredictions: [Prediction]) -> Prediction? {
        // Find average prediction within 30 seconds of the MultiModelPrediction timestamp
        return averagePredictions.first { avgPrediction in
            abs(avgPrediction.timestamp.timeIntervalSince(timestamp)) <= 30.0
        }
    }
    
    // MARK: - Color Map Access
    
    func getColorMap() -> [String: [String: String]] {
        return modelColors
    }
    
    // MARK: - File Access
    
    func getCSVFileURL() -> URL {
        return getCSVFilePath()
    }
}

// ModelService protocol is now imported from PredictionModel.swift
