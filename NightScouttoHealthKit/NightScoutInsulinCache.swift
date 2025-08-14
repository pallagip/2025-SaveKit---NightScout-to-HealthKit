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
        
        // Normalized insulin decay: exponential chosen so remaining ~1% at 4h cutoff
        // k = ln(1/epsilon) / windowHours, with epsilon = 0.01 and windowHours = 4
        let windowHours = 4.0
        let epsilon = 0.01
        let decayConstant = log(1.0 / epsilon) / windowHours
        self.decayedAmount = max(0.0, insulinAmount * exp(-decayConstant * max(0.0, hoursElapsed)))
    }
    
    // Get decayed amount without updating stored value
    func getDecayedAmount(currentTime: Date = Date()) -> Double {
        let hoursElapsed = currentTime.timeIntervalSince(timestamp) / 3600.0
        let windowHours = 4.0
        let epsilon = 0.01
        let decayConstant = log(1.0 / epsilon) / windowHours
        return max(0.0, insulinAmount * exp(-decayConstant * max(0.0, hoursElapsed)))
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
