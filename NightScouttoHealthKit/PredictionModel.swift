import Foundation
import SwiftData

@Model
final class Prediction: @unchecked Sendable {
    // Core prediction data (original fields)
    var timestamp: Date
    var predictionValue: Double  // Always stored in mmol/L
    var usedMgdlUnits: Bool      // Track which unit was used during prediction
    
    // Current BG data (new fields with default values)
    var currentBG: Double = 0.0        // Current blood glucose at prediction time (mmol/L)
    var stabilityStatus: String = ""  // STABLE, RISING, or FALLING
    
    // Model data (new fields with default values)
    var modelOutput: Double = 0.0      // Raw model output (0-1 scale)
    var modelPredictedChange: Double = 0.0  // Model's predicted change (mmol/L)
    
    // Trend data (new fields with default values)
    var observedTrend: Double = 0.0    // Observed BG trend (mmol/L over 20 min)
    
    // Weight and combination data (new fields with default values)
    var modelWeight: Double = 0.0      // Weight given to model's prediction
    var trendWeight: Double = 0.0      // Weight given to observed trend
    var finalPredictedChange: Double = 0.0  // Final predicted change after weighting
    
    // Actual blood glucose value from HealthKit (added for ML comparison)
    var actualBG: Double = 0.0         // Actual blood glucose value from HealthKit (mmol/L)
    var actualBGTimestamp: Date?       // When the actual reading was recorded
    
    init(timestamp: Date, 
         predictionValue: Double, 
         usedMgdlUnits: Bool, 
         currentBG: Double = 0,
         stabilityStatus: String = "",
         modelOutput: Double = 0,
         modelPredictedChange: Double = 0,
         observedTrend: Double = 0,
         modelWeight: Double = 0,
         trendWeight: Double = 0,
         finalPredictedChange: Double = 0,
         actualBG: Double = 0,
         actualBGTimestamp: Date? = nil) {
        
        self.timestamp = timestamp
        self.predictionValue = predictionValue
        self.usedMgdlUnits = usedMgdlUnits
        self.currentBG = currentBG
        self.stabilityStatus = stabilityStatus
        self.modelOutput = modelOutput
        self.modelPredictedChange = modelPredictedChange
        self.observedTrend = observedTrend
        self.modelWeight = modelWeight
        self.trendWeight = trendWeight
        self.finalPredictedChange = finalPredictedChange
        self.actualBG = actualBG
        self.actualBGTimestamp = actualBGTimestamp
    }
    
    // Helper to get formatted prediction value in the appropriate units
    var formattedValue: String {
        // predictionValue is already stored in the correct units (mg/dL or mmol/L)
        // Format accordingly - no conversion needed
        if usedMgdlUnits {
            return String(format: "%.0f", predictionValue)
        } else {
            return String(format: "%.1f", predictionValue)
        }
    }
    
    // Helper to get the prediction value in mg/dL regardless of how it's stored
    var predictionValueInMgdl: Double {
        return usedMgdlUnits ? predictionValue : (predictionValue * 18.0)
    }
    
    // Helper to get the prediction value in mmol/L regardless of how it's stored
    var predictionValueInMmol: Double {
        return usedMgdlUnits ? (predictionValue / 18.0) : predictionValue
    }
    
    // Helper to get units as string
    var units: String {
        return usedMgdlUnits ? "mg/dL" : "mmol/L"
    }
    
    // Helper for formatted date
    var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        return formatter.string(from: timestamp)
    }
}
