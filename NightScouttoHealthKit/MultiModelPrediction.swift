import Foundation
import SwiftData

@Model
final class MultiModelPrediction {
    var id: UUID
    var timestamp: Date
    var currentBG_mmol: Double   // Current blood glucose in mmol/L
    var currentBG_mgdl: Int      // Current blood glucose in mg/dL
    
    // Model 1 (rangeupto1_tcn)
    var m1_pred_mmol: Double = 0.0
    var m1_pred_mgdl: Int = 0
    
    // Model 2 (rangeupto2_tcn)
    var m2_pred_mmol: Double = 0.0
    var m2_pred_mgdl: Int = 0
    
    // Model 3 (rangeupto3_tcn)
    var m3_pred_mmol: Double = 0.0
    var m3_pred_mgdl: Int = 0
    
    // Model 4 (rangeupto4_tcn)
    var m4_pred_mmol: Double = 0.0
    var m4_pred_mgdl: Int = 0
    
    // Model 5 (rangeupto5_tcn)
    var m5_pred_mmol: Double = 0.0
    var m5_pred_mgdl: Int = 0
    
    // Model 6 (new model)
    var m6_pred_mmol: Double = 0.0
    var m6_pred_mgdl: Int = 0
    
    // Average prediction (calculated from all 6 models)
    var avg_pred_mmol: Double = 0.0
    var avg_pred_mgdl: Int = 0
    
    // Actual blood glucose reading ~20 minutes after prediction
    var actualBG_mmol: Double = 0.0
    var actualBG_mgdl: Int = 0
    var actualBGTimestamp: Date? = nil
    
    // Time difference between last carb entry and prediction button press
    var lastCarbEntryTimestamp: Date? = nil
    var timeSinceLastCarb_minutes: Double = 0.0  // Time difference in minutes
    
    // Time difference between last insulin entry and prediction button press
    var lastInsulinEntryTimestamp: Date? = nil
    var timeSinceLastInsulin_minutes: Double = 0.0  // Time difference in minutes
    
    // Sequential prediction number for tracking progress toward 100 predictions
    var predictionCount: Int = 0
    
    init(timestamp: Date, currentBG_mmol: Double, predictionCount: Int = 0) {
        self.id = UUID()
        self.timestamp = timestamp
        self.currentBG_mmol = currentBG_mmol
        self.currentBG_mgdl = Int(round(currentBG_mmol * 18.0))
        self.predictionCount = predictionCount
    }
    
    // Helper method to set prediction for a specific model (1 to 6)
    func setPrediction(model: Int, mmol: Double) {
        let mgdl = Int(round(mmol * 18.0))
        
        switch model {
        case 1:
            m1_pred_mmol = mmol
            m1_pred_mgdl = mgdl
        case 2:
            m2_pred_mmol = mmol
            m2_pred_mgdl = mgdl
        case 3:
            m3_pred_mmol = mmol
            m3_pred_mgdl = mgdl
        case 4:
            m4_pred_mmol = mmol
            m4_pred_mgdl = mgdl
        case 5:
            m5_pred_mmol = mmol
            m5_pred_mgdl = mgdl
        case 6:
            m6_pred_mmol = mmol
            m6_pred_mgdl = mgdl
        default:
            break
        }
    }
    
    // Helper method to calculate and set average prediction from all 6 models
    func calculateAndSetAveragePrediction() {
        let predictions = [m1_pred_mmol, m2_pred_mmol, m3_pred_mmol, m4_pred_mmol, m5_pred_mmol, m6_pred_mmol]
        let validPredictions = predictions.filter { $0 > 0.0 }
        
        if !validPredictions.isEmpty {
            let averageMmol = validPredictions.reduce(0.0, +) / Double(validPredictions.count)
            self.avg_pred_mmol = averageMmol
            self.avg_pred_mgdl = Int(round(averageMmol * 18.0))
        }
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
        } else {
            // No carb entry found
            self.timeSinceLastCarb_minutes = -1.0  // Use -1 to indicate no carb entry found
        }
    }
    
    // Helper method to set insulin timing information
    func setInsulinTiming(lastInsulinTimestamp: Date?, predictionTimestamp: Date) {
        self.lastInsulinEntryTimestamp = lastInsulinTimestamp
        
        if let lastInsulinTimestamp = lastInsulinTimestamp {
            // Calculate time difference in minutes
            self.timeSinceLastInsulin_minutes = (predictionTimestamp.timeIntervalSince1970 - lastInsulinTimestamp.timeIntervalSince1970) / 60.0
        } else {
            // No insulin entry found
            self.timeSinceLastInsulin_minutes = -1.0  // Use -1 to indicate no insulin entry found
        }
    }
}
