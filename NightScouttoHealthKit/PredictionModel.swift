import Foundation
import SwiftData

@Model
class Prediction {
    var timestamp: Date
    var predictionValue: Double  // Always stored in mmol/L
    var usedMgdlUnits: Bool      // Track which unit was used during prediction
    
    init(timestamp: Date, predictionValue: Double, usedMgdlUnits: Bool) {
        self.timestamp = timestamp
        self.predictionValue = predictionValue
        self.usedMgdlUnits = usedMgdlUnits
    }
    
    // Helper to get formatted prediction value in the appropriate units
    var formattedValue: String {
        if usedMgdlUnits {
            return String(format: "%.0f", predictionValue * 18.0)
        } else {
            return String(format: "%.1f", predictionValue)
        }
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
