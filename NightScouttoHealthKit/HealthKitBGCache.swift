import Foundation
import SwiftData
import HealthKit

@Model
final class HealthKitBGCache {
    var id: UUID
    var timestamp: Date
    var bloodGlucose_mmol: Double
    var bloodGlucose_mgdl: Int
    var healthKitUUID: String  // Store HealthKit sample UUID to avoid duplicates
    var sourceInfo: String     // Store source information (device, app, etc.)
    var createdAt: Date        // When this cache entry was created
    
    init(timestamp: Date, bloodGlucose_mmol: Double, healthKitUUID: String, sourceInfo: String = "") {
        self.id = UUID()
        self.timestamp = timestamp
        self.bloodGlucose_mmol = bloodGlucose_mmol
        self.bloodGlucose_mgdl = Int(round(bloodGlucose_mmol * 18.0))
        self.healthKitUUID = healthKitUUID
        self.sourceInfo = sourceInfo
        self.createdAt = Date()
    }
    
    // Convenience initializer from HealthKit sample
    convenience init(from sample: HKQuantitySample) {
        // First, get the value in mg/dL (which is the standard HealthKit unit)
        let mgdlUnit = HKUnit(from: "mg/dL")
        let mgdlValue = sample.quantity.doubleValue(for: mgdlUnit)
        
        // Convert mg/dL to mmol/L using the standard conversion factor
        let mmolValue = mgdlValue / 18.0
        
        let sourceInfo = sample.sourceRevision.source.name
        
        self.init(
            timestamp: sample.startDate,
            bloodGlucose_mmol: mmolValue,
            healthKitUUID: sample.uuid.uuidString,
            sourceInfo: sourceInfo
        )
    }
    
    // Helper method to get blood glucose in preferred units
    func bloodGlucoseValue(useMgdl: Bool) -> Double {
        return useMgdl ? Double(bloodGlucose_mgdl) : bloodGlucose_mmol
    }
    
    // Helper method to get formatted blood glucose string
    func formattedBloodGlucose(useMgdl: Bool) -> String {
        if useMgdl {
            return "\(bloodGlucose_mgdl) mg/dL"
        } else {
            return String(format: "%.1f mmol/L", bloodGlucose_mmol)
        }
    }
}
