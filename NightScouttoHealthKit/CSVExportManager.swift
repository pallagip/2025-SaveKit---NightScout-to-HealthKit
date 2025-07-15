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
    
    // MARK: - ISO-8601 formatter (UTC, no fractional seconds)
    private let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withColonSeparatorInTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)!
        return formatter
    }()
    
    // MARK: - Model Color Map
    // Model 1 coloring is defined but CSV export uses only models 2–6
    private let modelColorMap: [String: [String: String]] = [
        "M1": ["base": "#DC143C", "mmol": "#F37C94", "mgdl": "#AD102F"],
        "M2": ["base": "#008080", "mmol": "#00B3B3", "mgdl": "#004D4D"],
        "M3": ["base": "#FFBF00", "mmol": "#FFDF80", "mgdl": "#CC9900"],
        "M4": ["base": "#8A2BE2", "mmol": "#C89BF1", "mgdl": "#701AC0"],
        "M5": ["base": "#32CD32", "mmol": "#98E698", "mgdl": "#28A428"],
        "M6": ["base": "#FFA500", "mmol": "#FFD580", "mgdl": "#CC8400"] // Added M6 to align with requested models 2-6
    ]
    
    // MARK: - Public Entry Point
    func exportStoredPredictions(predictions: [MultiModelPrediction]) async throws -> URL {
        let csvFilePath = getCSVFilePath()
        
        // First, try to match predictions with actual readings
        let matchingService = MultiModelPredictionMatchingService()
        let matchedCount = try await matchingService.matchPredictionsWithActualReadings(predictions: predictions)
        print("📊 Matched \(matchedCount) predictions with actual readings")
        
        // Create CSV header
        let header = createCSVHeader()
        
        // Build CSV content
        var csvContent = header + "\r\n"
        
        for prediction in predictions.sorted(by: { $0.timestamp < $1.timestamp }) {
            let isoTimestamp = timestampFormatter.string(from: prediction.timestamp)
            var csvLine = isoTimestamp
            
            // Build model data array for models 2 to 6
            // Note: Model 1 data export is commented out; uncomment to enable model 1 export
            
            /*
            // Model 1 data (commented out)
            let model1Data = (prediction.m1_pred_mmol, prediction.m1_pred_mgdl)
            let currentBG_mmol_1 = String(format: "%.2f", prediction.currentBG_mmol)
            let currentBG_mgdl_1 = String(prediction.currentBG_mgdl)
            let pred_mmol_1 = String(format: "%.2f", model1Data.0)
            let pred_mgdl_1 = String(model1Data.1)
            csvLine += ",\(currentBG_mmol_1),\(currentBG_mgdl_1),\(pred_mmol_1),\(pred_mgdl_1)"
            */
            
            // Models 2-6 data
            let modelData = [
                (prediction.m2_pred_mmol, prediction.m2_pred_mgdl),
                (prediction.m3_pred_mmol, prediction.m3_pred_mgdl),
                (prediction.m4_pred_mmol, prediction.m4_pred_mgdl),
                (prediction.m5_pred_mmol, prediction.m5_pred_mgdl),
                (prediction.m6_pred_mmol, prediction.m6_pred_mgdl) // assuming m6_pred_mmol, m6_pred_mgdl exist on MultiModelPrediction
            ]
            
            for (predMmol, predMgdl) in modelData {
                let currentBG_mmol = String(format: "%.2f", prediction.currentBG_mmol)
                let currentBG_mgdl = String(prediction.currentBG_mgdl)
                let pred_mmol = String(format: "%.2f", predMmol)
                let pred_mgdl = String(predMgdl)
                
                csvLine += ",\(currentBG_mmol),\(currentBG_mgdl),\(pred_mmol),\(pred_mgdl)"
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
        var columns: [String] = ["Timestamp_UTC"]
        
        // Comment out Model 1 columns, uncomment to enable Model 1 CSV export
        /*
        columns += [
            "M1_Current_BG_mmol",
            "M1_Current_BG_mgdl",
            "M1_Pred_20min_mmol",
            "M1_Pred_20min_mgdl"
        ]
        */
        
        // Add columns for models 2-6
        for modelNum in 2...6 {
            columns += [
                "M\(modelNum)_Current_BG_mmol",
                "M\(modelNum)_Current_BG_mgdl",
                "M\(modelNum)_Pred_20min_mmol",
                "M\(modelNum)_Pred_20min_mgdl"
            ]
        }
        
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
    
    // MARK: - Color Map Access
    
    func getColorMap() -> [String: [String: String]] {
        return modelColorMap
    }
    
    // MARK: - File Access
    
    func getCSVFileURL() -> URL {
        return getCSVFilePath()
    }
}

// MARK: - Model Service Protocol

protocol ModelService {
    func predict(window: MLMultiArray, currentBG: Double, usedMgdl: Bool) throws -> Prediction
}
