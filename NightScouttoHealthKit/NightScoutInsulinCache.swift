import Foundation
import SwiftData
import HealthKit

@Model
final class NightScoutInsulinCache {
    var id: UUID
    var timestamp: Date
    var insulinAmount: Double // Units of insulin
    var insulinType: String? // Type of insulin (e.g., "rapid", "long")
    var nightScoutId: String // NightScout treatment ID to avoid duplicates
    var sourceInfo: String // Source information
    var createdAt: Date // When this cache entry was created
    var decayedAmount: Double // Current decayed amount based on time
    
    init(timestamp: Date, insulinAmount: Double, insulinType: String? = nil, nightScoutId: String, sourceInfo: String = "") {
        self.id = UUID()
        self.timestamp = timestamp
        self.insulinAmount = insulinAmount
        self.insulinType = insulinType
        self.nightScoutId = nightScoutId
        self.sourceInfo = sourceInfo
        self.createdAt = Date()
        self.decayedAmount = insulinAmount // Initially no decay
    }
    
    // Apply insulin decay function (similar to HealthKit decay)
    func updateDecayedAmount(currentTime: Date = Date()) {
        let hoursElapsed = currentTime.timeIntervalSince(timestamp) / 3600.0
        
        // Standard insulin decay: exponential decay with 4-hour half-life
        // Similar to what's used in HealthKitFeatureProvider
        let decayConstant = 0.1733 // ln(2) / 4 hours
        self.decayedAmount = max(0.0, insulinAmount * exp(-decayConstant * hoursElapsed))
    }
    
    // Get decayed amount without updating stored value
    func getDecayedAmount(currentTime: Date = Date()) -> Double {
        let hoursElapsed = currentTime.timeIntervalSince(timestamp) / 3600.0
        let decayConstant = 0.1733 // ln(2) / 4 hours
        return max(0.0, insulinAmount * exp(-decayConstant * hoursElapsed))
    }
    
    // Check if insulin is still active (within 4 hours and has decayed amount > 0.01)
    func isActive(currentTime: Date = Date()) -> Bool {
        let hoursElapsed = currentTime.timeIntervalSince(timestamp) / 3600.0
        return hoursElapsed <= 4.0 && getDecayedAmount(currentTime: currentTime) > 0.01
    }
    
    // Helper method to get formatted insulin string
    func formattedInsulin() -> String {
        if let type = insulinType {
            return String(format: "%.2f U (%@)", insulinAmount, type)
        } else {
            return String(format: "%.2f U", insulinAmount)
        }
    }
}
