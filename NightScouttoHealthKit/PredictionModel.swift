import Foundation
import SwiftData
import CoreML
import Accelerate

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

final class BGTCNService {
    static let shared = BGTCNService()

    private let model: rangeupto1_tcn  // auto‑generated Core ML class
    private let mean: [Float]
    private let std: [Float]

    private init() {
        // Load compiled model
        guard let m = try? rangeupto1_tcn(configuration: MLModelConfiguration()) else {
            fatalError("❌ Could not load rangeupto1_tcn.mlpackage")
        }
        self.model = m
        
        // Use default scaling values for now (can be updated when metadata format is confirmed)
        self.mean = [0.0, 0.0, 0.0, 0.0]
        self.std  = [1.0, 1.0, 1.0, 1.0]
        precondition(mean.count == 4 && std.count == 4, "Scaler length mismatch")
    }

    /// Main entry – pass a raw 24×4 window (Float32, shape (24,4), row‑major).
    func predict(window raw: MLMultiArray,
                 currentBG: Double,
                 usedMgdl: Bool) throws -> Prediction {
        // 1. Copy & scale in‑place (raw is (24,4) or (1,24,4))
        let shape = raw.shape.map { $0.intValue }
        guard shape.suffix(2) == [24, 4] else {
            throw NSError(domain: "BGTCN", code: 1,
                          userInfo: [NSLocalizedDescriptionKey : "Expected (1,24,4) or (24,4) array"])
        }
        let ptr = UnsafeMutablePointer<Float32>(OpaquePointer(raw.dataPointer))
        let strideT = 4
        for f in 0..<4 {
            let m = mean[f], s = std[f]
            var idx = f
            for _ in 0..<24 {
                ptr[idx] = (ptr[idx] - m) / s
                idx += strideT
            }
        }
        // 2. Run prediction
        let input = rangeupto1_tcnInput(input_1: raw)
        let out   = try model.prediction(input: input)
        // Extract the first (and likely only) output value using reflection
        let bg20  = extractOutputValue(from: out)
        // 3. Build data object for SwiftData
        return Prediction(timestamp: Date(),
                          predictionValue: bg20,
                          usedMgdlUnits: usedMgdl,
                          currentBG: currentBG,
                          stabilityStatus: "",           // set by caller
                          modelOutput: bg20,
                          modelPredictedChange: bg20 - currentBG,
                          observedTrend: 0)
    }
    
    /// Extract the output value from the model prediction using reflection
    private func extractOutputValue(from prediction: rangeupto1_tcnOutput) -> Double {
        let mirror = Mirror(reflecting: prediction)
        var outputValue: Double = 0
        
        for child in mirror.children {
            if let value = child.value as? MLMultiArray {
                // Get the first value from the MLMultiArray
                if value.count > 0 {
                    outputValue = Double(value[0].doubleValue)
                    break
                }
            } else if let value = child.value as? Double {
                outputValue = value
                break
            } else if let value = child.value as? Float {
                outputValue = Double(value)
                break
            }
        }
        
        return outputValue
    }
}
