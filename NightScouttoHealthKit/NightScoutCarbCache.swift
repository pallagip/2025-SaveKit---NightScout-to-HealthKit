import Foundation
import SwiftData
import HealthKit

@Model
final class NightScoutCarbCache {
    var id: UUID
    var timestamp: Date
    var carbAmount: Double // Grams of carbohydrates
    var carbType: String? // Type of carbs (e.g., "breakfast", "snack")
    var nightScoutId: String // NightScout treatment ID to avoid duplicates
    var sourceInfo: String // Source information
    var createdAt: Date // When this cache entry was created
    var decayedAmount: Double // Current decayed amount based on time
    
    init(timestamp: Date, carbAmount: Double, carbType: String? = nil, nightScoutId: String, sourceInfo: String = "") {
        self.id = UUID()
        self.timestamp = timestamp
        self.carbAmount = carbAmount
        self.carbType = carbType
        self.nightScoutId = nightScoutId
        self.sourceInfo = sourceInfo
        self.createdAt = Date()
        self.decayedAmount = carbAmount // Initially no decay
    }
    
    // Apply carbohydrate decay function (similar to HealthKit decay)
    func updateDecayedAmount(currentTime: Date = Date()) {
        let hoursElapsed = currentTime.timeIntervalSince(timestamp) / 3600.0
        
        // Normalized carb decay: exponential chosen so remaining ~1% at 5h cutoff
        // k = ln(1/epsilon) / windowHours, with epsilon = 0.01 and windowHours = 5
        let windowHours = 5.0
        let epsilon = 0.01
        let decayConstant = log(1.0 / epsilon) / windowHours
        self.decayedAmount = max(0.0, carbAmount * exp(-decayConstant * max(0.0, hoursElapsed)))
    }
    
    // Get decayed amount without updating stored value
    func getDecayedAmount(currentTime: Date = Date()) -> Double {
        let hoursElapsed = currentTime.timeIntervalSince(timestamp) / 3600.0
        let windowHours = 5.0
        let epsilon = 0.01
        let decayConstant = log(1.0 / epsilon) / windowHours
        return max(0.0, carbAmount * exp(-decayConstant * max(0.0, hoursElapsed)))
    }
    
    // Check if carbs are still active (within 5 hours and has decayed amount > 0.1)
    func isActive(currentTime: Date = Date()) -> Bool {
        let hoursElapsed = currentTime.timeIntervalSince(timestamp) / 3600.0
        return hoursElapsed <= 5.0 && getDecayedAmount(currentTime: currentTime) > 0.1
    }
    
    // Helper method to get formatted carb string
    func formattedCarbs() -> String {
        if let type = carbType {
            return String(format: "%.1f g (%@)", carbAmount, type)
        } else {
            return String(format: "%.1f g", carbAmount)
        }
    }
}
