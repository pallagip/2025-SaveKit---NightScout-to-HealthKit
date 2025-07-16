import Foundation
import SwiftData
import CoreML
import Accelerate

// NOTE: Model 1 (BGTCNService) and all references to it have been commented out
// because Core ML types for Model 1 are not present in this project.
// The code is preserved here for future use when types become available.

@Model
final class Prediction: @unchecked Sendable, Identifiable, Hashable {
    // Core prediction data (original fields)
    var id: UUID  // Required for Identifiable conformance
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
        
        self.id = UUID()  // Generate unique ID for each instance
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
    
    // Helper for formatted date
    var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: timestamp)
    }
    
    // MARK: - Hashable Conformance
    static func == (lhs: Prediction, rhs: Prediction) -> Bool {
        return lhs.id == rhs.id
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

// MARK: - Model 1 Service (Original BGTCNService)
/*
final class BGTCNService: ModelService {
    static let shared = BGTCNService()

    private let model: rangeupto1_tcn  // auto‑generated Core ML class
    private let inputMean: [Float]
    private let inputStd: [Float]
    // Output scaling parameters for denormalization
    private let outputMean: Float = 7.0  // Typical glucose mean around 7 mmol/L (126 mg/dL)
    private let outputStd: Float = 3.0   // Reasonable glucose std around 3 mmol/L (54 mg/dL)

    private init() {
        // Load compiled model
        guard let m = try? rangeupto1_tcn(configuration: MLModelConfiguration()) else {
            fatalError("❌ Could not load rangeupto1_tcn.mlpackage")
        }
        self.model = m
        
        // Input scaling values for the 8 features: [heart_rate, blood_glucose, insulin_dose, dietary_carbohydrates, bg_trend, hr_trend, hour_sin, hour_cos]
        self.inputMean = [70.0, 7.0, 2.0, 30.0, 0.0, 0.0, 0.0, 0.0]  // Scale only first 4 features
        self.inputStd  = [20.0, 3.0, 5.0, 40.0, 1.0, 1.0, 1.0, 1.0]  // Scale only first 4 features
        precondition(inputMean.count == 8 && inputStd.count == 8, "Input scaler length mismatch")
    }

    /// Main entry – pass a raw 24×8 window (Float32, shape (24,8), row‑major).
    func predict(window raw: MLMultiArray,
                 currentBG: Double,
                 usedMgdl: Bool) throws -> Prediction {
        // 1. Copy & scale in‑place (raw is (24,8) or (1,24,8))
        let shape = raw.shape.map { $0.intValue }
        guard shape.suffix(2) == [24, 8] else {
            throw NSError(domain: "BGTCN", code: 1,
                          userInfo: [NSLocalizedDescriptionKey : "Expected (1,24,8) or (24,8) array"])
        }
        
        // Debug: Log raw input values before scaling
        let ptr = UnsafeMutablePointer<Float32>(OpaquePointer(raw.dataPointer))
        print("🔍 Model 1 Raw Input (first 8 features): [\(ptr[0]), \(ptr[1]), \(ptr[2]), \(ptr[3]), \(ptr[4]), \(ptr[5]), \(ptr[6]), \(ptr[7])]")
        print("🔍 Model 1 Input scaling factors - Mean: \(inputMean), Std: \(inputStd)")
        
        // Apply input scaling to the 8 features across 24 time steps
        let strideT = 8
        for f in 0..<8 {
            let m = inputMean[f], s = inputStd[f]
            var idx = f
            for _ in 0..<24 {
                let originalValue = ptr[idx]
                ptr[idx] = (ptr[idx] - m) / s
                if f == 0 { // Only log first feature to avoid spam
                    print("🔍 Model 1 Feature \(f): \(originalValue) -> \(ptr[idx])")
                    break // Only log first time step
                }
                idx += strideT
            }
        }
        
        // 2. Run prediction
        let input = rangeupto1_tcnInput(input_1: raw)
        let out   = try model.prediction(input: input)
        // Extract the raw normalized output value using reflection
        let normalizedOutput = extractOutputValue(from: out)
        
        // Denormalize the output: denormalized = normalized * std + mean
        let rawOutputMmol = normalizedOutput * Double(outputStd) + Double(outputMean)
        
        // Ensure the prediction is within reasonable bounds (2.0-30.0 mmol/L = 36-540 mg/dL)
        let clampedOutputMmol = max(2.0, min(30.0, rawOutputMmol))
        
        print("🔍 Model 1 Normalized Output: \(normalizedOutput)")
        print("🔍 Model 1 Denormalized Output: \(rawOutputMmol) mmol/L")
        print("🔍 Model 1 Clamped Output: \(clampedOutputMmol) mmol/L = \(String(format: "%.1f", clampedOutputMmol * 18.0)) mg/dL")
        
        // Convert model output to the requested units
        let predictionValue = usedMgdl ? (clampedOutputMmol * 18.0) : clampedOutputMmol
        let currentBGMmol = currentBG / 18.0  // Convert current BG to mmol/L for comparison
        
        // 3. Build data object for SwiftData
        let modelPredictedChange = clampedOutputMmol - currentBGMmol
        
        return Prediction(
            timestamp: Date(),
            predictionValue: predictionValue,
            usedMgdlUnits: usedMgdl,
            currentBG: currentBG,
            stabilityStatus: "",           // set by caller
            modelOutput: clampedOutputMmol,    // Store clamped model output in mmol/L
            modelPredictedChange: modelPredictedChange * (usedMgdl ? 18.0 : 1.0),  // Convert change to requested units
            observedTrend: 0,
            actualBG: 0,
            actualBGTimestamp: nil
        )
    }
    
    /// Extract the output value from the model prediction using reflection
    private func extractOutputValue(from prediction: rangeupto1_tcnOutput) -> Double {
        let mirror = Mirror(reflecting: prediction)
        var outputValue: Double = 0
        
        print("🔍 Model 1 Output Structure:")
        for (index, child) in mirror.children.enumerated() {
            print("🔍   Child \(index): label=\(child.label ?? "nil"), type=\(type(of: child.value))")
            
            // Handle MLDictionaryFeatureProvider (Core ML output format)
            if let provider = child.value as? MLDictionaryFeatureProvider {
                print("🔍   Found MLDictionaryFeatureProvider")
                
                // Try to get the feature names
                let featureNames = provider.featureNames
                print("🔍   Available feature names: \(featureNames)")
                
                // Try each feature name to find the output
                for featureName in featureNames {
                    if let featureValue = provider.featureValue(for: featureName) {
                        print("🔍   Feature '\(featureName)': type=\(featureValue.type)")
                        
                        if featureValue.type == .multiArray, let multiArray = featureValue.multiArrayValue {
                            print("🔍   MultiArray shape: \(multiArray.shape), count: \(multiArray.count)")
                            if multiArray.count > 0 {
                                outputValue = Double(multiArray[0].doubleValue)
                                print("🔍   Extracted value: \(outputValue)")
                                return outputValue
                            }
                        } else if featureValue.type == .double {
                            outputValue = featureValue.doubleValue
                            print("🔍   Extracted double value: \(outputValue)")
                            return outputValue
                        } else if featureValue.type == .int64 {
                            outputValue = Double(featureValue.int64Value)
                            print("🔍   Extracted int64 value: \(outputValue)")
                            return outputValue
                        }
                    }
                }
            }
            // Fallback to direct MLMultiArray access
            else if let value = child.value as? MLMultiArray {
                print("🔍   MLMultiArray shape: \(value.shape), count: \(value.count)")
                if value.count > 0 {
                    let firstValue = Double(value[0].doubleValue)
                    print("🔍   First value: \(firstValue)")
                    outputValue = firstValue
                    break
                }
            } else if let value = child.value as? Double {
                print("🔍   Double value: \(value)")
                outputValue = value
                break
            } else if let value = child.value as? Float {
                print("🔍   Float value: \(value)")
                outputValue = Double(value)
                break
            }
        }
        
        return outputValue
    }
}
*/

 // MARK: - Model 2 Service
final class BGTCN2Service: ModelService {
    static let shared = BGTCN2Service()

    private let model: rangeupto2_tcn
    private let scaler: RangeUpTo2Scaler

    private init() {
        guard let m = try? rangeupto2_tcn(configuration: MLModelConfiguration()) else {
            fatalError("❌ Could not load rangeupto2_tcn.mlpackage")
        }
        self.model = m
        self.scaler = RangeUpTo2Scaler()
    }

    func predict(window raw: MLMultiArray, currentBG: Double, usedMgdl: Bool) throws -> Prediction {
        let shape = raw.shape.map { $0.intValue }
        guard shape.suffix(2) == [24, 8] else {
            throw NSError(domain: "BGTCN2", code: 1, userInfo: [NSLocalizedDescriptionKey : "Expected (1,24,8) or (24,8) array"])
        }
        
        // Convert MLMultiArray to 2D array format for scaler
        let ptr = UnsafeMutablePointer<Float32>(OpaquePointer(raw.dataPointer))
        var inputData: [[Double]] = []
        
        for t in 0..<24 {
            var timestepData: [Double] = []
            for f in 0..<8 {
                let index = t * 8 + f
                timestepData.append(Double(ptr[index]))
            }
            inputData.append(timestepData)
        }
        
        print("🔍 Model 2 Raw Input (first timestep): \(inputData[0])")
        
        // Use the proper scaler to normalize input
        let scaledArray = try scaler.transformForCoreML(inputData)
        
        // Run prediction with properly scaled input
        let input = rangeupto2_tcnInput(input_1: scaledArray)
        let out = try model.prediction(input: input)
        
        // Extract the raw output value - this is a normalized value that needs denormalization
        let rawOutput = extractOutputValue(from: out)
        
        print("🔍 Model 2 Raw Output: \(rawOutput) mmol/L")
        
        // Apply proper output denormalization: raw_output * std + mean
        // Using standard glucose denormalization parameters
        let outputMean = 7.0  // mmol/L
        let outputStd = 3.0   // mmol/L
        let denormalizedOutput = (rawOutput * outputStd) + outputMean
        
        // Apply reasonable bounds checking (1.0-50.0 mmol/L = physiological range)
        let clampedOutputMmol = max(1.0, min(50.0, denormalizedOutput))
        
        // Convert model output to the requested units
        let predictionValue = usedMgdl ? (clampedOutputMmol * 18.0) : clampedOutputMmol
        let currentBGMmol = currentBG / 18.0  // Convert current BG to mmol/L for comparison
        
        let modelPredictedChange = clampedOutputMmol - currentBGMmol
        
        print("🔍 Model 2 Final Prediction: \(String(format: "%.1f", predictionValue)) \(usedMgdl ? "mg/dL" : "mmol/L")")
        
        return Prediction(
            timestamp: Date(),
            predictionValue: predictionValue,
            usedMgdlUnits: usedMgdl,
            currentBG: currentBG,
            stabilityStatus: "",
            modelOutput: clampedOutputMmol,
            modelPredictedChange: modelPredictedChange * (usedMgdl ? 18.0 : 1.0),
            observedTrend: 0,
            actualBG: 0,
            actualBGTimestamp: nil
        )
    }
    
    private func extractOutputValue(from prediction: rangeupto2_tcnOutput) -> Double {
        let mirror = Mirror(reflecting: prediction)
        var outputValue: Double = 0
        
        for child in mirror.children {
            if let provider = child.value as? MLDictionaryFeatureProvider {
                let featureNames = provider.featureNames
                for featureName in featureNames {
                    if let featureValue = provider.featureValue(for: featureName) {
                        if featureValue.type == .multiArray, let multiArray = featureValue.multiArrayValue {
                            if multiArray.count > 0 {
                                outputValue = Double(multiArray[0].doubleValue)
                                return outputValue
                            }
                        } else if featureValue.type == .double {
                            outputValue = featureValue.doubleValue
                            return outputValue
                        } else if featureValue.type == .int64 {
                            outputValue = Double(featureValue.int64Value)
                            return outputValue
                        }
                    }
                }
            } else if let value = child.value as? MLMultiArray {
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

// MARK: - Model 3 Service
final class BGTCN3Service: ModelService {
    static let shared = BGTCN3Service()
    private let model: rangeupto3_tcn
    private let scaler: RangeUpTo3Scaler

    private init() {
        guard let m = try? rangeupto3_tcn(configuration: MLModelConfiguration()) else {
            fatalError("❌ Could not load rangeupto3_tcn.mlpackage")
        }
        self.model = m
        self.scaler = RangeUpTo3Scaler()
    }

    func predict(window raw: MLMultiArray, currentBG: Double, usedMgdl: Bool) throws -> Prediction {
        let shape = raw.shape.map { $0.intValue }
        guard shape.suffix(2) == [24, 8] else {
            throw NSError(domain: "BGTCN3", code: 1, userInfo: [NSLocalizedDescriptionKey: "Expected (1,24,8) or (24,8) array"])
        }
        
        // Convert MLMultiArray to 2D array format for scaler
        let ptr = UnsafeMutablePointer<Float32>(OpaquePointer(raw.dataPointer))
        var inputData: [[Double]] = []
        
        for t in 0..<24 {
            var timestepData: [Double] = []
            for f in 0..<8 {
                let index = t * 8 + f
                timestepData.append(Double(ptr[index]))
            }
            inputData.append(timestepData)
        }
        
        // Use the proper scaler to normalize input
        let scaledArray = try scaler.transformForCoreML(inputData)
        
        // Run prediction with properly scaled input
        let input = rangeupto3_tcnInput(input_1: scaledArray)
        let out = try model.prediction(input: input)
        
        // Extract the raw output value - this is a normalized value that needs denormalization
        let rawOutput = extractOutputValue(from: out)
        
        print("🔍 Model 3 Raw Output: \(rawOutput) mmol/L")
        
        // Apply proper output denormalization: raw_output * std + mean
        // Using standard glucose denormalization parameters
        let outputMean = 7.0  // mmol/L
        let outputStd = 3.0   // mmol/L
        let denormalizedOutput = (rawOutput * outputStd) + outputMean
        
        // Apply reasonable bounds checking (1.0-50.0 mmol/L = physiological range)
        let clampedOutputMmol = max(1.0, min(50.0, denormalizedOutput))
        
        // Convert model output to the requested units
        let predictionValue = usedMgdl ? (clampedOutputMmol * 18.0) : clampedOutputMmol
        let currentBGMmol = currentBG / 18.0  // Convert current BG to mmol/L for comparison
        
        let modelPredictedChange = clampedOutputMmol - currentBGMmol
        
        return Prediction(
            timestamp: Date(),
            predictionValue: predictionValue,
            usedMgdlUnits: usedMgdl,
            currentBG: currentBG,
            stabilityStatus: "",
            modelOutput: clampedOutputMmol,
            modelPredictedChange: modelPredictedChange * (usedMgdl ? 18.0 : 1.0),
            observedTrend: 0,
            actualBG: 0,
            actualBGTimestamp: nil
        )
    }
    
    private func extractOutputValue(from prediction: rangeupto3_tcnOutput) -> Double {
        let mirror = Mirror(reflecting: prediction)
        var outputValue: Double = 0
        
        for child in mirror.children {
            if let provider = child.value as? MLDictionaryFeatureProvider {
                let featureNames = provider.featureNames
                for featureName in featureNames {
                    if let featureValue = provider.featureValue(for: featureName) {
                        if featureValue.type == .multiArray, let multiArray = featureValue.multiArrayValue {
                            if multiArray.count > 0 {
                                outputValue = Double(multiArray[0].doubleValue)
                                return outputValue
                            }
                        } else if featureValue.type == .double {
                            outputValue = featureValue.doubleValue
                            return outputValue
                        } else if featureValue.type == .int64 {
                            outputValue = Double(featureValue.int64Value)
                            return outputValue
                        }
                    }
                }
            } else if let value = child.value as? MLMultiArray, value.count > 0 {
                outputValue = Double(value[0].doubleValue)
                break
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

// MARK: - Model 4 Service
final class BGTCN4Service: ModelService {
    static let shared = BGTCN4Service()
    private let model: rangeupto4_tcn
    private let scaler: RangeUpTo4Scaler

    private init() {
        guard let m = try? rangeupto4_tcn(configuration: MLModelConfiguration()) else {
            fatalError("❌ Could not load rangeupto4_tcn.mlpackage")
        }
        self.model = m
        self.scaler = RangeUpTo4Scaler()
    }

    func predict(window raw: MLMultiArray, currentBG: Double, usedMgdl: Bool) throws -> Prediction {
        let shape = raw.shape.map { $0.intValue }
        guard shape.suffix(2) == [24, 8] else {
            throw NSError(domain: "BGTCN4", code: 1, userInfo: [NSLocalizedDescriptionKey: "Expected (1,24,8) or (24,8) array"])
        }
        
        // Convert MLMultiArray to 2D array format for scaler
        let ptr = UnsafeMutablePointer<Float32>(OpaquePointer(raw.dataPointer))
        var inputData: [[Double]] = []
        
        for t in 0..<24 {
            var timestepData: [Double] = []
            for f in 0..<8 {
                let index = t * 8 + f
                timestepData.append(Double(ptr[index]))
            }
            inputData.append(timestepData)
        }
        
        // Use the proper scaler to normalize input
        let scaledArray = try scaler.transformForCoreML(inputData)
        
        // Run prediction with properly scaled input
        let input = rangeupto4_tcnInput(input_1: scaledArray)
        let out = try model.prediction(input: input)
        
        // Extract the raw output value - this is a normalized value that needs denormalization
        let rawOutput = extractOutputValue(from: out)
        
        print("🔍 Model 4 Raw Output: \(rawOutput) mmol/L")
        
        // Apply proper output denormalization: raw_output * std + mean
        // Using standard glucose denormalization parameters
        let outputMean = 7.0  // mmol/L
        let outputStd = 3.0   // mmol/L
        let denormalizedOutput = (rawOutput * outputStd) + outputMean
        
        // Apply reasonable bounds checking (1.0-50.0 mmol/L = physiological range)
        let clampedOutputMmol = max(1.0, min(50.0, denormalizedOutput))
        
        // Convert model output to the requested units
        let predictionValue = usedMgdl ? (clampedOutputMmol * 18.0) : clampedOutputMmol
        let currentBGMmol = currentBG / 18.0  // Convert current BG to mmol/L for comparison
        
        let modelPredictedChange = clampedOutputMmol - currentBGMmol
        
        return Prediction(
            timestamp: Date(),
            predictionValue: predictionValue,
            usedMgdlUnits: usedMgdl,
            currentBG: currentBG,
            stabilityStatus: "",
            modelOutput: clampedOutputMmol,
            modelPredictedChange: modelPredictedChange * (usedMgdl ? 18.0 : 1.0),
            observedTrend: 0,
            actualBG: 0,
            actualBGTimestamp: nil
        )
    }
    
    private func extractOutputValue(from prediction: rangeupto4_tcnOutput) -> Double {
        let mirror = Mirror(reflecting: prediction)
        var outputValue: Double = 0
        
        for child in mirror.children {
            if let provider = child.value as? MLDictionaryFeatureProvider {
                let featureNames = provider.featureNames
                for featureName in featureNames {
                    if let featureValue = provider.featureValue(for: featureName) {
                        if featureValue.type == .multiArray, let multiArray = featureValue.multiArrayValue {
                            if multiArray.count > 0 {
                                outputValue = Double(multiArray[0].doubleValue)
                                return outputValue
                            }
                        } else if featureValue.type == .double {
                            outputValue = featureValue.doubleValue
                            return outputValue
                        } else if featureValue.type == .int64 {
                            outputValue = Double(featureValue.int64Value)
                            return outputValue
                        }
                    }
                }
            } else if let value = child.value as? MLMultiArray, value.count > 0 {
                outputValue = Double(value[0].doubleValue)
                break
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

// MARK: - Model 5 Service
final class BGTCN5Service: ModelService {
    static let shared = BGTCN5Service()
    private let model: rangeupto5_tcn
    private let scaler: RangeUpTo5Scaler

    private init() {
        guard let m = try? rangeupto5_tcn(configuration: MLModelConfiguration()) else {
            fatalError("❌ Could not load rangeupto5_tcn.mlpackage")
        }
        self.model = m
        self.scaler = RangeUpTo5Scaler()
    }

    func predict(window raw: MLMultiArray, currentBG: Double, usedMgdl: Bool) throws -> Prediction {
        let shape = raw.shape.map { $0.intValue }
        guard shape.suffix(2) == [24, 8] else {
            throw NSError(domain: "BGTCN5", code: 1, userInfo: [NSLocalizedDescriptionKey: "Expected (1,24,8) or (24,8) array"])
        }
        
        // Convert MLMultiArray to 2D array format for scaler
        let ptr = UnsafeMutablePointer<Float32>(OpaquePointer(raw.dataPointer))
        var inputData: [[Double]] = []
        
        for t in 0..<24 {
            var timestepData: [Double] = []
            for f in 0..<8 {
                let index = t * 8 + f
                timestepData.append(Double(ptr[index]))
            }
            inputData.append(timestepData)
        }
        
        // Use the proper scaler to normalize input
        let scaledArray = try scaler.transformForCoreML(inputData)
        
        // Run prediction with properly scaled input
        let input = rangeupto5_tcnInput(input_1: scaledArray)
        let out = try model.prediction(input: input)
        
        // Extract the raw output value - this is a normalized value that needs denormalization
        let rawOutput = extractOutputValue(from: out)
        
        print("🔍 Model 5 Raw Output: \(rawOutput) mmol/L")
        
        // Apply proper output denormalization: raw_output * std + mean
        // Using standard glucose denormalization parameters
        let outputMean = 7.0  // mmol/L
        let outputStd = 3.0   // mmol/L
        let denormalizedOutput = (rawOutput * outputStd) + outputMean
        
        // Apply reasonable bounds checking (1.0-50.0 mmol/L = physiological range)
        let clampedOutputMmol = max(1.0, min(50.0, denormalizedOutput))
        
        // Convert model output to the requested units
        let predictionValue = usedMgdl ? (clampedOutputMmol * 18.0) : clampedOutputMmol
        let currentBGMmol = currentBG / 18.0  // Convert current BG to mmol/L for comparison
        
        let modelPredictedChange = clampedOutputMmol - currentBGMmol
        
        return Prediction(
            timestamp: Date(),
            predictionValue: predictionValue,
            usedMgdlUnits: usedMgdl,
            currentBG: currentBG,
            stabilityStatus: "",
            modelOutput: clampedOutputMmol,
            modelPredictedChange: modelPredictedChange * (usedMgdl ? 18.0 : 1.0),
            observedTrend: 0,
            actualBG: 0,
            actualBGTimestamp: nil
        )
    }
    
    private func extractOutputValue(from prediction: rangeupto5_tcnOutput) -> Double {
        let mirror = Mirror(reflecting: prediction)
        var outputValue: Double = 0
        
        for child in mirror.children {
            if let provider = child.value as? MLDictionaryFeatureProvider {
                let featureNames = provider.featureNames
                for featureName in featureNames {
                    if let featureValue = provider.featureValue(for: featureName) {
                        if featureValue.type == .multiArray, let multiArray = featureValue.multiArrayValue {
                            if multiArray.count > 0 {
                                outputValue = Double(multiArray[0].doubleValue)
                                return outputValue
                            }
                        } else if featureValue.type == .double {
                            outputValue = featureValue.doubleValue
                            return outputValue
                        } else if featureValue.type == .int64 {
                            outputValue = Double(featureValue.int64Value)
                            return outputValue
                        }
                    }
                }
            } else if let value = child.value as? MLMultiArray, value.count > 0 {
                outputValue = Double(value[0].doubleValue)
                break
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

// MARK: - Model 6 Service
final class BGTCN6Service: ModelService {
    static let shared = BGTCN6Service()
    private let model: rangeupto6_tcn
    private let scaler: RangeUpTo6Scaler

    private init() {
        guard let m = try? rangeupto6_tcn(configuration: MLModelConfiguration()) else {
            fatalError("❌ Could not load rangeupto6_tcn.mlpackage")
        }
        self.model = m
        self.scaler = RangeUpTo6Scaler()
    }

    func predict(window raw: MLMultiArray, currentBG: Double, usedMgdl: Bool) throws -> Prediction {
        let shape = raw.shape.map { $0.intValue }
        guard shape.suffix(2) == [24, 8] else {
            throw NSError(domain: "BGTCN6", code: 1, userInfo: [NSLocalizedDescriptionKey: "Expected (1,24,8) or (24,8) array"])
        }
        
        // Convert MLMultiArray to 2D array format for scaler
        let ptr = UnsafeMutablePointer<Float32>(OpaquePointer(raw.dataPointer))
        var inputData: [[Double]] = []
        
        for t in 0..<24 {
            var timestepData: [Double] = []
            for f in 0..<8 {
                let index = t * 8 + f
                timestepData.append(Double(ptr[index]))
            }
            inputData.append(timestepData)
        }
        
        // Use the proper scaler to normalize input
        let scaledArray = try scaler.transformForCoreML(inputData)
        
        // Run prediction with properly scaled input
        let input = rangeupto6_tcnInput(input_1: scaledArray)
        let out = try model.prediction(input: input)
        
        // Extract the raw output value - this is a normalized value that needs denormalization
        let rawOutput = extractOutputValue(from: out)
        
        print("🔍 Model 6 Raw Output: \(rawOutput) mmol/L")
        
        // Apply proper output denormalization: raw_output * std + mean
        // Using standard glucose denormalization parameters
        let outputMean = 7.0  // mmol/L
        let outputStd = 3.0   // mmol/L
        let denormalizedOutput = (rawOutput * outputStd) + outputMean
        
        // Apply reasonable bounds checking (1.0-50.0 mmol/L = physiological range)
        let clampedOutputMmol = max(1.0, min(50.0, denormalizedOutput))
        
        // Convert model output to the requested units
        let predictionValue = usedMgdl ? (clampedOutputMmol * 18.0) : clampedOutputMmol
        let currentBGMmol = currentBG / 18.0  // Convert current BG to mmol/L for comparison
        
        let modelPredictedChange = clampedOutputMmol - currentBGMmol
        
        return Prediction(
            timestamp: Date(),
            predictionValue: predictionValue,
            usedMgdlUnits: usedMgdl,
            currentBG: currentBG,
            stabilityStatus: "",
            modelOutput: clampedOutputMmol,
            modelPredictedChange: modelPredictedChange * (usedMgdl ? 18.0 : 1.0),
            observedTrend: 0,
            actualBG: 0,
            actualBGTimestamp: nil
        )
    }
    
    private func extractOutputValue(from prediction: rangeupto6_tcnOutput) -> Double {
        let mirror = Mirror(reflecting: prediction)
        var outputValue: Double = 0
        
        for child in mirror.children {
            if let provider = child.value as? MLDictionaryFeatureProvider {
                let featureNames = provider.featureNames
                for featureName in featureNames {
                    if let featureValue = provider.featureValue(for: featureName) {
                        if featureValue.type == .multiArray, let multiArray = featureValue.multiArrayValue {
                            if multiArray.count > 0 {
                                outputValue = Double(multiArray[0].doubleValue)
                                return outputValue
                            }
                        } else if featureValue.type == .double {
                            outputValue = featureValue.doubleValue
                            return outputValue
                        } else if featureValue.type == .int64 {
                            outputValue = Double(featureValue.int64Value)
                            return outputValue
                        }
                    }
                }
            } else if let value = child.value as? MLMultiArray, value.count > 0 {
                outputValue = Double(value[0].doubleValue)
                break
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

// MARK: - Series Prediction Service
final class SeriesPredictionService {
    static let shared = SeriesPredictionService()
    
    private init() {}
    
    /// Helper method to create a copy of MLMultiArray
    private func copyMLMultiArray(_ original: MLMultiArray) -> MLMultiArray {
        guard let copy = try? MLMultiArray(shape: original.shape, dataType: original.dataType) else {
            fatalError("Failed to create MLMultiArray copy")
        }
        
        let originalPtr = UnsafeMutablePointer<Float32>(OpaquePointer(original.dataPointer))
        let copyPtr = UnsafeMutablePointer<Float32>(OpaquePointer(copy.dataPointer))
        
        let count = original.count
        for i in 0..<count {
            copyPtr[i] = originalPtr[i]
        }
        
        return copy
    }
    
    /// Run all 6 models in series, log predictions, and save to SwiftData
    /// Returns: Dictionary with model predictions (key: model number, value: prediction result)
    func runSeriesPredictions(window: MLMultiArray, currentBG: Double, usedMgdl: Bool, modelContext: ModelContext? = nil) async -> [Int: Prediction] {
        print("🔎 Starting Series Predictions - Current BG: \(currentBG) \(usedMgdl ? "mg/dL" : "mmol/L")")
        
        // Create MultiModelPrediction record
        let currentBGInMmol = usedMgdl ? (currentBG / 18.0) : currentBG
        let multiPrediction = MultiModelPrediction(timestamp: Date(), currentBG_mmol: currentBGInMmol)
        
        var modelPredictions: [Int: Prediction] = [:]
        
        do {
            // --- Model 1 commented out due to missing Core ML types ---
            /*
            let windowCopy1 = copyMLMultiArray(window)
            let prediction1 = try BGTCNService.shared.predict(window: windowCopy1, currentBG: currentBG, usedMgdl: usedMgdl)
            multiPrediction.setPrediction(model: 1, mmol: prediction1.modelOutput)
            modelPredictions[1] = prediction1
            print("✓ Model 1 (rangeupto1_tcn): \(String(format: "%.2f", prediction1.modelOutput)) mmol/L = \(String(format: "%.1f", prediction1.modelOutput * 18.0)) mg/dL")
            */
            // --- End Model 1 ---
            
            let windowCopy2 = copyMLMultiArray(window)
            let prediction2 = try BGTCN2Service.shared.predict(window: windowCopy2, currentBG: currentBG, usedMgdl: usedMgdl)
            multiPrediction.setPrediction(model: 2, mmol: prediction2.modelOutput)
            modelPredictions[2] = prediction2
            print("✓ Model 2 (rangeupto2_tcn): \(String(format: "%.2f", prediction2.modelOutput)) mmol/L = \(String(format: "%.1f", prediction2.modelOutput * 18.0)) mg/dL")
            
            let windowCopy3 = copyMLMultiArray(window)
            let prediction3 = try BGTCN3Service.shared.predict(window: windowCopy3, currentBG: currentBG, usedMgdl: usedMgdl)
            multiPrediction.setPrediction(model: 3, mmol: prediction3.modelOutput)
            modelPredictions[3] = prediction3
            print("✓ Model 3 (rangeupto3_tcn): \(String(format: "%.2f", prediction3.modelOutput)) mmol/L = \(String(format: "%.1f", prediction3.modelOutput * 18.0)) mg/dL")
            
            let windowCopy4 = copyMLMultiArray(window)
            let prediction4 = try BGTCN4Service.shared.predict(window: windowCopy4, currentBG: currentBG, usedMgdl: usedMgdl)
            multiPrediction.setPrediction(model: 4, mmol: prediction4.modelOutput)
            modelPredictions[4] = prediction4
            print("✓ Model 4 (rangeupto4_tcn): \(String(format: "%.2f", prediction4.modelOutput)) mmol/L = \(String(format: "%.1f", prediction4.modelOutput * 18.0)) mg/dL")
            
            let windowCopy5 = copyMLMultiArray(window)
            let prediction5 = try BGTCN5Service.shared.predict(window: windowCopy5, currentBG: currentBG, usedMgdl: usedMgdl)
            multiPrediction.setPrediction(model: 5, mmol: prediction5.modelOutput)
            modelPredictions[5] = prediction5
            print("✓ Model 5 (rangeupto5_tcn): \(String(format: "%.2f", prediction5.modelOutput)) mmol/L = \(String(format: "%.1f", prediction5.modelOutput * 18.0)) mg/dL")
            
            let windowCopy6 = copyMLMultiArray(window)
            let prediction6 = try BGTCN6Service.shared.predict(window: windowCopy6, currentBG: currentBG, usedMgdl: usedMgdl)
            multiPrediction.setPrediction(model: 6, mmol: prediction6.modelOutput)
            modelPredictions[6] = prediction6
            print("✓ Model 6 (rangeupto6_tcn): \(String(format: "%.2f", prediction6.modelOutput)) mmol/L = \(String(format: "%.1f", prediction6.modelOutput * 18.0)) mg/dL")
            
            // Save to SwiftData if context is provided
            if let context = modelContext {
                context.insert(multiPrediction)
                try context.save()
                print("💾 Saved multi-model prediction to SwiftData")
            }
            
            print("✅ Series Predictions Complete\n")
            
        } catch {
            print("❌ Series Prediction Error: \(error)")
        }
        
        return modelPredictions
    }
}

