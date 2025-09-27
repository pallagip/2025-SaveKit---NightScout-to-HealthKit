import Foundation
import SwiftData

@Model
final class RandomForestPrediction {
    var id: UUID
    var timestamp: Date
    
    // Random Forest prediction values
    var prediction_mmol: Double = 0.0
    var prediction_mgdl: Int = 0
    
    // Actual blood glucose reading ~20 minutes after prediction
    var actualBG_mmol: Double = 0.0
    var actualBG_mgdl: Int = 0
    var actualBGTimestamp: Date? = nil
    
    // Time difference between last carb entry and prediction button press
    var lastCarbEntryTimestamp: Date? = nil
    var timeSinceLastCarb_minutes: Double = -1.0  // -1 indicates no carb entry found
    
    // Time difference between last insulin entry and prediction button press
    var lastInsulinEntryTimestamp: Date? = nil
    var timeSinceLastInsulin_minutes: Double = -1.0  // -1 indicates no insulin entry found
    
    // Sequential prediction number for tracking
    var predictionCount: Int = 0
    
    init(timestamp: Date, predictionValue_mmol: Double, predictionCount: Int = 0) {
        self.id = UUID()
        self.timestamp = timestamp
        self.prediction_mmol = predictionValue_mmol
        self.prediction_mgdl = Int(round(predictionValue_mmol * 18.0))
        self.predictionCount = predictionCount
    }
    
    // Helper method to set Random Forest prediction
    func setPrediction(mmol: Double) {
        self.prediction_mmol = mmol
        self.prediction_mgdl = Int(round(mmol * 18.0))
    }
    
    // Helper method to set actual BG reading that occurred after prediction
    func setActualBG(mmol: Double, timestamp: Date) {
        self.actualBG_mmol = mmol
        self.actualBG_mgdl = Int(round(mmol * 18.0))
        self.actualBGTimestamp = timestamp
    }
    
    // Helper method to set carb timing information
    func setCarbTiming(lastCarbTimestamp: Date?, predictionTimestamp: Date) {
        self.lastCarbEntryTimestamp = lastCarbTimestamp
        
        if let lastCarbTimestamp = lastCarbTimestamp {
            // Calculate time difference in minutes
            self.timeSinceLastCarb_minutes = (predictionTimestamp.timeIntervalSince1970 - lastCarbTimestamp.timeIntervalSince1970) / 60.0
            // Enforce 5-hour window for carbs: outside window -> treat as missing
            if self.timeSinceLastCarb_minutes < 0 || self.timeSinceLastCarb_minutes > 5 * 60 {
                self.timeSinceLastCarb_minutes = -1.0
                self.lastCarbEntryTimestamp = nil
            }
        } else {
            // No carb entry found
            self.timeSinceLastCarb_minutes = -1.0
        }
    }
    
    // Helper method to set insulin timing information
    func setInsulinTiming(lastInsulinTimestamp: Date?, predictionTimestamp: Date) {
        self.lastInsulinEntryTimestamp = lastInsulinTimestamp
        
        if let lastInsulinTimestamp = lastInsulinTimestamp {
            // Calculate time difference in minutes
            self.timeSinceLastInsulin_minutes = (predictionTimestamp.timeIntervalSince1970 - lastInsulinTimestamp.timeIntervalSince1970) / 60.0
            // Enforce 4-hour window for insulin: outside window -> treat as missing
            if self.timeSinceLastInsulin_minutes < 0 || self.timeSinceLastInsulin_minutes > 4 * 60 {
                self.timeSinceLastInsulin_minutes = -1.0
                self.lastInsulinEntryTimestamp = nil
            }
        } else {
            // No insulin entry found
            self.timeSinceLastInsulin_minutes = -1.0
        }
    }
}
