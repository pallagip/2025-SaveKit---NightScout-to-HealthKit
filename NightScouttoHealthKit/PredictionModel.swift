import Foundation
import SwiftData
import CoreML
import Accelerate

// Protocol definition for all model services
protocol ModelService {
    func predict(window raw: MLMultiArray, currentBG: Double, usedMgdl: Bool) throws -> Prediction
}

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
    
    // New fields for identifying model types and average predictions
    var modelIndex: Int = 0            // 0=average, 1-5=WaveNet models
    var isAveragePrediction: Bool = false  // Flag to identify average predictions
    var note: String = ""              // Additional metadata/notes about the prediction
    
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
         actualBGTimestamp: Date? = nil,
         modelIndex: Int = 0,
         isAveragePrediction: Bool = false,
         note: String = "") {
        
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
        self.modelIndex = modelIndex
        self.isAveragePrediction = isAveragePrediction
        self.note = note
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

// MARK: - Model 1 Service (WaveNet1)
final class BGTCNService: ModelService {
    static let shared = BGTCNService()

    private let model: MLModel  // Core ML model
    private let inputMean: [Float]
    private let inputStd: [Float]
    // Output scaling parameters for denormalization
    private let outputMean: Float = 7.0  // Typical glucose mean around 7 mmol/L (126 mg/dL)
    private let outputStd: Float = 3.0   // Reasonable glucose std around 3 mmol/L (54 mg/dL)

    private init() {
        // Load compiled model
        guard let modelURL = Bundle.main.url(forResource: "wavenet1", withExtension: "mlpackage"),
              let m = try? MLModel(contentsOf: modelURL) else {
            fatalError("❌ Could not load wavenet1.mlpackage")
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
        let inputFeatures = try MLDictionaryFeatureProvider(dictionary: ["input_3": MLFeatureValue(multiArray: raw)])
        let out = try model.prediction(from: inputFeatures)
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
    private func extractOutputValue(from prediction: MLFeatureProvider) -> Double {
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
// MARK: - Model 2 Service
final class BGTCN2Service: ModelService {
    static let shared = BGTCN2Service()

    private let model: MLModel
    // private let scaler: RangeUpTo2Scaler  // Commented out - scaler now built into ML model

    private init() {
        guard let modelURL = Bundle.main.url(forResource: "wavenet2", withExtension: "mlpackage"),
              let m = try? MLModel(contentsOf: modelURL) else {
            fatalError("❌ Could not load wavenet2.mlpackage")
        }
        self.model = m
        // self.scaler = RangeUpTo2Scaler()  // Commented out - scaler now built into ML model
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
        
        // Use the proper scaler to normalize input - COMMENTED OUT: scaler now built into ML model
        // let scaledArray = try scaler.transformForCoreML(inputData)
        
        // Run prediction with raw input (scaling now handled by ML model)
        let inputFeatures = try MLDictionaryFeatureProvider(dictionary: ["input_3": MLFeatureValue(multiArray: raw)])
        let out = try model.prediction(from: inputFeatures)
        
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
    
    private func extractOutputValue(from prediction: MLFeatureProvider) -> Double {
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

    private let model: MLModel
    // private let scaler: RangeUpTo3Scaler  // Commented out - scaler now built into ML model

    private init() {
        guard let modelURL = Bundle.main.url(forResource: "wavenet3", withExtension: "mlpackage"),
              let m = try? MLModel(contentsOf: modelURL) else {
            fatalError("❌ Could not load wavenet3.mlpackage")
        }
        self.model = m
        // self.scaler = RangeUpTo3Scaler()  // Commented out - scaler now built into ML model
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
        
        // Use the proper scaler to normalize input - COMMENTED OUT: scaler now built into ML model
        // let scaledArray = try scaler.transformForCoreML(inputData)
        
        // Run prediction with raw input (scaling now handled by ML model)
        let inputFeatures = try MLDictionaryFeatureProvider(dictionary: ["input_3": MLFeatureValue(multiArray: raw)])
        let out = try model.prediction(from: inputFeatures)
        
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
    
    private func extractOutputValue(from prediction: MLFeatureProvider) -> Double {
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

final class BGTCN4Service: ModelService {
    static let shared = BGTCN4Service()

    private let model: MLModel
    // private let scaler: RangeUpTo4Scaler  // Commented out - scaler now built into ML model

    private init() {
        guard let modelURL = Bundle.main.url(forResource: "wavenet4", withExtension: "mlpackage"),
              let m = try? MLModel(contentsOf: modelURL) else {
            fatalError("❌ Could not load wavenet4.mlpackage")
        }
        self.model = m
        // self.scaler = RangeUpTo4Scaler()  // Commented out - scaler now built into ML model
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
        
        // Use the proper scaler to normalize input - COMMENTED OUT: scaler now built into ML model
        // let scaledArray = try scaler.transformForCoreML(inputData)
        
        // Run prediction with raw input (scaling now handled by ML model)
        let inputFeatures = try MLDictionaryFeatureProvider(dictionary: ["input_3": MLFeatureValue(multiArray: raw)])
        let out = try model.prediction(from: inputFeatures)
        
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
    
    private func extractOutputValue(from prediction: MLFeatureProvider) -> Double {
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
    private let model: MLModel
    // private let scaler: RangeUpTo5Scaler  // Commented out - scaler now built into ML model

    private init() {
        guard let modelURL = Bundle.main.url(forResource: "wavenet5", withExtension: "mlpackage"),
              let m = try? MLModel(contentsOf: modelURL) else {
            fatalError("❌ Could not load wavenet5.mlpackage")
        }
        self.model = m
        // self.scaler = RangeUpTo5Scaler()  // Commented out - scaler now built into ML model
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
        
        // Use the proper scaler to normalize input - COMMENTED OUT: scaler now built into ML model
        // let scaledArray = try scaler.transformForCoreML(inputData)
        
        // Run prediction with raw input (scaling now handled by ML model)
        let inputFeatures = try MLDictionaryFeatureProvider(dictionary: ["input_3": MLFeatureValue(multiArray: raw)])
        let out = try model.prediction(from: inputFeatures)
        
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
    
    private func extractOutputValue(from prediction: MLFeatureProvider) -> Double {
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
