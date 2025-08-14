import Foundation
import SwiftData
import CoreML
import Accelerate

// MARK: - WaveNet Models
// This file contains WaveNet*Service classes that use wavenetN.mlpackage models (wavenet1 to wavenet5).
// 
// All classes conform to ModelService and provide similar prediction interfaces,
// including input normalization, output extraction via reflection, and consistent scaling.

// MARK: - Helper Functions

/// Load model URL from main bundle for given model name and extension
private func loadModelURL(named modelName: String, withExtension ext: String) -> URL {
    guard let url = Bundle.main.url(forResource: modelName, withExtension: ext) else {
        fatalError("Could not find \(modelName).\(ext) in Bundle.main. Please add it to your Xcode project target.")
    }
    return url
}

/// Normalize MLMultiArray in-place using provided mean and std arrays (Double precision)
private func normalizeInput(_ raw: MLMultiArray, mean: [Double], std: [Double]) {
    let shape = raw.shape.map { $0.intValue }
    print("🔍 normalizeInput called with:")
    print("🔍   Tensor shape: \(shape)")
    print("🔍   Expected suffix: [24, \(mean.count)]")
    print("🔍   Actual suffix: \(Array(shape.suffix(2)))")
    print("🔍   Mean array count: \(mean.count)")
    print("🔍   Std array count: \(std.count)")
    print("🔍   Tensor total elements: \(raw.count)")
    
    guard shape.suffix(2) == [24, mean.count] else {
        print("❌ TENSOR SHAPE MISMATCH!")
        print("❌   Got shape: \(shape)")
        print("❌   Expected suffix: [24, \(mean.count)]")
        print("❌   Got suffix: \(Array(shape.suffix(2)))")
        fatalError("Unexpected MLMultiArray shape for normalization: \(shape)")
    }
    
    let ptr = raw.dataPointer.bindMemory(to: Float32.self, capacity: raw.count)
    var idx = 0
    for _ in 0..<24 {
        for f in 0..<mean.count {
            let originalValue = Double(ptr[idx])
            let normalizedValue = (originalValue - mean[f]) / std[f]
            ptr[idx] = Float32(normalizedValue)
            idx += 1
        }
    }
}

/// Extract a single Double output value from a generic MLModel output
private func extractOutputValue(from prediction: MLFeatureProvider) -> Double {
    // Get all feature names from the prediction
    let featureNames = prediction.featureNames
    
    // Try each feature name to find the output
    for featureName in featureNames {
        if let featureValue = prediction.featureValue(for: featureName) {
            if featureValue.type == .multiArray, let multiArray = featureValue.multiArrayValue {
                if multiArray.count > 0 {
                    return Double(multiArray[0].doubleValue)
                }
            } else if featureValue.type == .double {
                return featureValue.doubleValue
            } else if featureValue.type == .int64 {
                return Double(featureValue.int64Value)
            }
        }
    }
    return 0.0
}

// MARK: - WaveNet1Service (wavenet1.mlpackage)
final class WaveNet1Service: ModelService {
    static let shared = WaveNet1Service()
    
    private let model: MLModel
    private let inputMean: [Double] = [70.0, 7.0, 2.0, 30.0, 0.0, 0.0, 0.0, 0.0]
    private let inputStd: [Double] = [20.0, 3.0, 5.0, 40.0, 1.0, 1.0, 1.0, 1.0]
    
    private init() {
        // Load the compiled Core ML model from Bundle
        var modelURL: URL?
        
        if let bundleURL = Bundle.main.url(forResource: "wavenet1", withExtension: "mlmodelc") {
            print("✅ Found wavenet1.mlmodelc in Bundle: \(bundleURL)")
            modelURL = bundleURL
        } else {
            print("❌ wavenet1.mlmodelc not found in Bundle")
            // List what's actually in the Bundle for debugging
            if let bundlePath = Bundle.main.resourcePath {
                let contents = try? FileManager.default.contentsOfDirectory(atPath: bundlePath)
                print("📁 Bundle contents: \(contents?.filter { $0.contains("wavenet") } ?? [])")
            }
            modelURL = nil
        }
        
        guard let url = modelURL else {
            fatalError("Could not find wavenet1.mlpackage in Bundle or project directory")
        }
        
        do {
            model = try MLModel(contentsOf: url)
            print("✅ Successfully loaded wavenet1 model")
            
            // Debug model input/output specifications
            let modelDescription = model.modelDescription
            print("🔍 WaveNet1 Model Input Features:")
            for (name, description) in modelDescription.inputDescriptionsByName {
                print("🔍   Input '\(name)': \(description)")
                if let multiArrayConstraint = description.multiArrayConstraint {
                    print("🔍     Shape: \(multiArrayConstraint.shape)")
                    print("🔍     Data Type: \(multiArrayConstraint.dataType)")
                }
            }
            print("🔍 WaveNet1 Model Output Features:")
            for (name, description) in modelDescription.outputDescriptionsByName {
                print("🔍   Output '\(name)': \(description)")
            }
        } catch {
            fatalError("Failed to load wavenet1 model: \(error)")
        }
        precondition(inputMean.count == inputStd.count, "Input scaler length mismatch")
    }
    
    func predict(window raw: MLMultiArray, currentBG: Double, usedMgdl: Bool, predictionCount: Int = 0) throws -> Prediction {
        normalizeInput(raw, mean: inputMean, std: inputStd)
        
        let inputFeatures = try MLDictionaryFeatureProvider(dictionary: ["input_3": MLFeatureValue(multiArray: raw)])
        let out = try model.prediction(from: inputFeatures)
        
        let rawOutput = extractOutputValue(from: out)
        let outputMean = 0.0
        let outputStd = 1.0  // Reduced from 3.0 to prevent extreme deltas
        
        let deltaOutputMmol = (rawOutput * outputStd) + outputMean
        let currentBGMmol = usedMgdl ? (currentBG / 18.0) : currentBG
        let absolutePredictionMmol = currentBGMmol + deltaOutputMmol
        let clampedOutputMmol = max(2.0, min(25.0, absolutePredictionMmol))  // More realistic physiological range
        
        let predictionValue = usedMgdl ? (clampedOutputMmol * 18.0) : clampedOutputMmol
        let modelPredictedChange = deltaOutputMmol
        
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
            actualBGTimestamp: nil,
            predictionCount: predictionCount
        )
    }
}

// MARK: - WaveNet2Service (wavenet2.mlpackage)
final class WaveNet2Service: ModelService {
    static let shared = WaveNet2Service()
    
    private let model: MLModel
    private let inputMean: [Double] = [70.0, 7.0, 2.0, 30.0, 0.0, 0.0, 0.0, 0.0]
    private let inputStd: [Double] = [20.0, 3.0, 5.0, 40.0, 1.0, 1.0, 1.0, 1.0]
    
    private init() {
        // Load the compiled Core ML model from Bundle
        var modelURL: URL?
        
        if let bundleURL = Bundle.main.url(forResource: "wavenet2", withExtension: "mlmodelc") {
            print("✅ Found wavenet2.mlmodelc in Bundle: \(bundleURL)")
            modelURL = bundleURL
        } else {
            print("❌ wavenet2.mlmodelc not found in Bundle")
            modelURL = nil
        }
        
        guard let url = modelURL else {
            fatalError("Could not find wavenet2.mlpackage")
        }
        
        do {
            self.model = try MLModel(contentsOf: url)
        } catch {
            fatalError("Failed to load wavenet2 model: \(error)")
        }
        precondition(inputMean.count == inputStd.count, "Input scaler length mismatch")
    }
    
    func predict(window raw: MLMultiArray, currentBG: Double, usedMgdl: Bool, predictionCount: Int = 0) throws -> Prediction {
        normalizeInput(raw, mean: inputMean, std: inputStd)
        
        let inputFeatures = try MLDictionaryFeatureProvider(dictionary: ["input_3": MLFeatureValue(multiArray: raw)])
        let out = try model.prediction(from: inputFeatures)
        
        let rawOutput = extractOutputValue(from: out)
        let outputMean = 0.0
        let outputStd = 1.0  // Reduced from 3.0 to prevent extreme deltas
        
        let deltaOutputMmol = (rawOutput * outputStd) + outputMean
        let currentBGMmol = usedMgdl ? (currentBG / 18.0) : currentBG
        let absolutePredictionMmol = currentBGMmol + deltaOutputMmol
        let clampedOutputMmol = max(2.0, min(25.0, absolutePredictionMmol))  // More realistic physiological range
        
        let predictionValue = usedMgdl ? (clampedOutputMmol * 18.0) : clampedOutputMmol
        let modelPredictedChange = deltaOutputMmol
        
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
            actualBGTimestamp: nil,
            predictionCount: predictionCount
        )
    }
}

// MARK: - WaveNet3Service (wavenet3.mlpackage)
final class WaveNet3Service: ModelService {
    static let shared = WaveNet3Service()
    
    private let model: MLModel
    private let inputMean: [Double] = [70.0, 7.0, 2.0, 30.0, 0.0, 0.0, 0.0, 0.0]
    private let inputStd: [Double] = [20.0, 3.0, 5.0, 40.0, 1.0, 1.0, 1.0, 1.0]
    
    private init() {
        // Load the compiled Core ML model from Bundle
        var modelURL: URL?
        
        if let bundleURL = Bundle.main.url(forResource: "wavenet3", withExtension: "mlmodelc") {
            print("✅ Found wavenet3.mlmodelc in Bundle: \(bundleURL)")
            modelURL = bundleURL
        } else {
            print("❌ wavenet3.mlmodelc not found in Bundle")
            modelURL = nil
        }
        
        guard let url = modelURL else {
            fatalError("Could not find wavenet3.mlpackage")
        }
        
        do {
            self.model = try MLModel(contentsOf: url)
        } catch {
            fatalError("Failed to load wavenet3 model: \(error)")
        }
        precondition(inputMean.count == inputStd.count, "Input scaler length mismatch")
    }
    
    func predict(window raw: MLMultiArray, currentBG: Double, usedMgdl: Bool, predictionCount: Int = 0) throws -> Prediction {
        normalizeInput(raw, mean: inputMean, std: inputStd)
        
        let inputFeatures = try MLDictionaryFeatureProvider(dictionary: ["input_3": MLFeatureValue(multiArray: raw)])
        let out = try model.prediction(from: inputFeatures)
        
        let rawOutput = extractOutputValue(from: out)
        let outputMean = 0.0
        let outputStd = 1.0  // Reduced from 3.0 to prevent extreme deltas
        
        let deltaOutputMmol = (rawOutput * outputStd) + outputMean
        let currentBGMmol = usedMgdl ? (currentBG / 18.0) : currentBG
        let absolutePredictionMmol = currentBGMmol + deltaOutputMmol
        let clampedOutputMmol = max(2.0, min(25.0, absolutePredictionMmol))  // More realistic physiological range
        
        let predictionValue = usedMgdl ? (clampedOutputMmol * 18.0) : clampedOutputMmol
        let modelPredictedChange = deltaOutputMmol
        
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
            actualBGTimestamp: nil,
            predictionCount: predictionCount
        )
    }
}

// MARK: - WaveNet4Service (wavenet4.mlpackage)
final class WaveNet4Service: ModelService {
    static let shared = WaveNet4Service()
    
    private let model: MLModel
    private let inputMean: [Double] = [70.0, 7.0, 2.0, 30.0, 0.0, 0.0, 0.0, 0.0]
    private let inputStd: [Double] = [20.0, 3.0, 5.0, 40.0, 1.0, 1.0, 1.0, 1.0]
    
    private init() {
        // Load the compiled Core ML model from Bundle
        var modelURL: URL?
        
        if let bundleURL = Bundle.main.url(forResource: "wavenet4", withExtension: "mlmodelc") {
            print("✅ Found wavenet4.mlmodelc in Bundle: \(bundleURL)")
            modelURL = bundleURL
        } else {
            print("❌ wavenet4.mlmodelc not found in Bundle")
            modelURL = nil
        }
        
        guard let url = modelURL else {
            fatalError("Could not find wavenet4.mlpackage")
        }
        
        do {
            self.model = try MLModel(contentsOf: url)
        } catch {
            fatalError("Failed to load wavenet4 model: \(error)")
        }
        precondition(inputMean.count == inputStd.count, "Input scaler length mismatch")
    }
    
    func predict(window raw: MLMultiArray, currentBG: Double, usedMgdl: Bool, predictionCount: Int = 0) throws -> Prediction {
        normalizeInput(raw, mean: inputMean, std: inputStd)
        
        let inputFeatures = try MLDictionaryFeatureProvider(dictionary: ["input_3": MLFeatureValue(multiArray: raw)])
        let out = try model.prediction(from: inputFeatures)
        
        let rawOutput = extractOutputValue(from: out)
        let outputMean = 0.0
        let outputStd = 1.0  // Reduced from 3.0 to prevent extreme deltas
        
        let deltaOutputMmol = (rawOutput * outputStd) + outputMean
        let currentBGMmol = usedMgdl ? (currentBG / 18.0) : currentBG
        let absolutePredictionMmol = currentBGMmol + deltaOutputMmol
        let clampedOutputMmol = max(2.0, min(25.0, absolutePredictionMmol))  // More realistic physiological range
        
        let predictionValue = usedMgdl ? (clampedOutputMmol * 18.0) : clampedOutputMmol
        let modelPredictedChange = deltaOutputMmol
        
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
            actualBGTimestamp: nil,
            predictionCount: predictionCount
        )
    }
}

// MARK: - WaveNet5Service (wavenet5.mlpackage)
final class WaveNet5Service: ModelService {
    static let shared = WaveNet5Service()
    
    private let model: MLModel
    private let inputMean: [Double] = [70.0, 7.0, 2.0, 30.0, 0.0, 0.0, 0.0, 0.0]
    private let inputStd: [Double] = [20.0, 3.0, 5.0, 40.0, 1.0, 1.0, 1.0, 1.0]
    
    private init() {
        // Load the compiled Core ML model from Bundle
        var modelURL: URL?
        
        if let bundleURL = Bundle.main.url(forResource: "wavenet5", withExtension: "mlmodelc") {
            print("✅ Found wavenet5.mlmodelc in Bundle: \(bundleURL)")
            modelURL = bundleURL
        } else {
            print("❌ wavenet5.mlmodelc not found in Bundle")
            modelURL = nil
        }
        
        guard let url = modelURL else {
            fatalError("Could not find wavenet5.mlpackage")
        }
        
        do {
            self.model = try MLModel(contentsOf: url)
        } catch {
            fatalError("Failed to load wavenet5 model: \(error)")
        }
        precondition(inputMean.count == inputStd.count, "Input scaler length mismatch")
    }
    
    func predict(window raw: MLMultiArray, currentBG: Double, usedMgdl: Bool, predictionCount: Int = 0) throws -> Prediction {
        normalizeInput(raw, mean: inputMean, std: inputStd)
        
        let inputFeatures = try MLDictionaryFeatureProvider(dictionary: ["input_3": MLFeatureValue(multiArray: raw)])
        let out = try model.prediction(from: inputFeatures)
        
        let rawOutput = extractOutputValue(from: out)
        let outputMean = 0.0
        let outputStd = 1.0  // Reduced from 3.0 to prevent extreme deltas
        
        let deltaOutputMmol = (rawOutput * outputStd) + outputMean
        let currentBGMmol = usedMgdl ? (currentBG / 18.0) : currentBG
        let absolutePredictionMmol = currentBGMmol + deltaOutputMmol
        let clampedOutputMmol = max(2.0, min(25.0, absolutePredictionMmol))  // More realistic physiological range
        
        let predictionValue = usedMgdl ? (clampedOutputMmol * 18.0) : clampedOutputMmol
        let modelPredictedChange = deltaOutputMmol
        
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
            actualBGTimestamp: nil,
            predictionCount: predictionCount
        )
    }
}











// MARK: - SeriesPredictionService

final class SeriesPredictionService {
    static let shared = SeriesPredictionService()
    private let healthKitFeatureProvider = HealthKitFeatureProvider()
    
    private init() {}
    
    /// Run series predictions using SwiftData cache when HealthKit is unavailable
    /// - Parameters:
    ///   - modelContext: SwiftData model context
    /// - Returns: Dictionary of model predictions
    func predictWithSwiftDataCache(modelContext: ModelContext) async throws -> [Int: Prediction] {
        print("\n🗄️ === SWIFTDATA CACHE SERIES PREDICTION ===\n")
        print("⚠️ HealthKit unavailable, using cached Nightscout data for all 5 models")
        
        // Build input window from SwiftData cache
        let window = try await healthKitFeatureProvider.buildWindowFromSwiftDataCache(modelContext: modelContext)
        
        // Get latest glucose from cache for current BG
        let glucoseData = try await healthKitFeatureProvider.fetchGlucoseFromSwiftDataCache(modelContext: modelContext, limit: 1)
        guard let latestReading = glucoseData.first else {
            throw NSError(domain: "SwiftData", code: 3, userInfo: [NSLocalizedDescriptionKey: "No glucose data in cache"])
        }
        
        let currentBG = latestReading.value
        let usedMgdl = true // Cache data is in mg/dL
        
        print("🩸 Latest cached glucose: \(String(format: "%.1f", currentBG)) mg/dL at \(latestReading.date)")
        
        // Calculate prediction count
        let predictionCount = calculateNextMultiModelPredictionCount(modelContext: modelContext)
        
        // Run predictions with all models using cached data
        let predictions = await runSeriesPredictions(
            window: window,
            currentBG: currentBG,
            usedMgdl: usedMgdl,
            modelContext: modelContext
        )
        
        print("\n🗄️ === CACHE SERIES PREDICTION COMPLETE ===\n")
        
        return predictions
    }
    
    /// Calculate the next prediction count for MultiModelPrediction based on existing records
    /// - Parameter modelContext: SwiftData model context to query existing predictions
    /// - Returns: The next sequential prediction count (1, 2, 3, ...)
    private func calculateNextMultiModelPredictionCount(modelContext: ModelContext?) -> Int {
        guard let modelContext = modelContext else {
            print("⚠️ No model context provided, using count 1")
            return 1
        }
        
        do {
            // Query for the highest prediction count in existing MultiModelPredictions
            let descriptor = FetchDescriptor<MultiModelPrediction>(
                sortBy: [SortDescriptor(\MultiModelPrediction.predictionCount, order: .reverse)]
            )
            let predictions = try modelContext.fetch(descriptor)
            
            if let highestCount = predictions.first?.predictionCount {
                let nextCount = highestCount + 1
                print("📊 Next multi-model prediction count: \(nextCount) (previous highest: \(highestCount))")
                return nextCount
            } else {
                print("📊 No existing multi-model predictions found, starting with count 1")
                return 1
            }
        } catch {
            print("⚠️ Error fetching multi-model prediction count: \(error), defaulting to count 1")
            return 1
        }
    }
    
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
    
    /// Run all 5 WaveNet models in series, log predictions, and save to SwiftData
    /// Returns: Dictionary with model predictions (key: model number, value: prediction result)
    func runSeriesPredictions(window: MLMultiArray, currentBG: Double, usedMgdl: Bool, modelContext: ModelContext? = nil) async -> [Int: Prediction] {
        print("🔎 Starting Series Predictions - Current BG: \(currentBG) \(usedMgdl ? "mg/dL" : "mmol/L")")
        let currentBGInMmol = usedMgdl ? (currentBG / 18.0) : currentBG
        let predictionTimestamp = Date()
        
        // Calculate the next prediction count for MultiModelPrediction
        let predictionCount = calculateNextMultiModelPredictionCount(modelContext: modelContext)
        let multiPrediction = MultiModelPrediction(timestamp: predictionTimestamp, currentBG_mmol: currentBGInMmol, predictionCount: predictionCount)
        
        // Fetch last carb entry timestamp and calculate time difference
        do {
            let lastCarbTimestamp = try await healthKitFeatureProvider.fetchLastCarbEntryTimestamp()
            multiPrediction.setCarbTiming(lastCarbTimestamp: lastCarbTimestamp, predictionTimestamp: predictionTimestamp)
            
            if let lastCarbTimestamp = lastCarbTimestamp {
                let timeDifference = multiPrediction.timeSinceLastCarb_minutes
                print("🍞 Last carb entry: \(lastCarbTimestamp.formatted()) (\(String(format: "%.1f", timeDifference)) minutes ago)")
            } else {
                print("🍞 No carb entries found in HealthKit")
            }
        } catch {
            print("⚠️ Failed to fetch last carb entry: \(error)")
            multiPrediction.setCarbTiming(lastCarbTimestamp: nil, predictionTimestamp: predictionTimestamp)
        }
        // Fallback: use SwiftData carb cache (5h) if HK provided none
        if multiPrediction.timeSinceLastCarb_minutes < 0, let context = modelContext {
            let start = predictionTimestamp.addingTimeInterval(-5 * 3600)
            let fetch = FetchDescriptor<NightScoutCarbCache>(
                predicate: #Predicate<NightScoutCarbCache> { cache in
                    cache.timestamp >= start && cache.timestamp <= predictionTimestamp
                },
                sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
            )
            if let results = try? context.fetch(fetch), let cache = results.first {
                multiPrediction.setCarbTiming(lastCarbTimestamp: cache.timestamp, predictionTimestamp: predictionTimestamp)
                print("🍞 Fallback carb timestamp from cache: \(cache.timestamp)")
            }
        }
        
        // Fetch last insulin entry timestamp and calculate time difference
        do {
            let lastInsulinTimestamp = try await healthKitFeatureProvider.fetchLastInsulinEntryTimestamp()
            multiPrediction.setInsulinTiming(lastInsulinTimestamp: lastInsulinTimestamp, predictionTimestamp: predictionTimestamp)
            
            if let lastInsulinTimestamp = lastInsulinTimestamp {
                let timeDifference = multiPrediction.timeSinceLastInsulin_minutes
                print("💉 Last insulin entry: \(lastInsulinTimestamp.formatted()) (\(String(format: "%.1f", timeDifference)) minutes ago)")
            } else {
                print("💉 No insulin entries found in HealthKit")
            }
        } catch {
            print("⚠️ Failed to fetch last insulin entry: \(error)")
            multiPrediction.setInsulinTiming(lastInsulinTimestamp: nil, predictionTimestamp: predictionTimestamp)
        }
        // Fallback: use SwiftData insulin cache (4h) if HK provided none
        if multiPrediction.timeSinceLastInsulin_minutes < 0, let context = modelContext {
            let start = predictionTimestamp.addingTimeInterval(-4 * 3600)
            let fetch = FetchDescriptor<NightScoutInsulinCache>(
                predicate: #Predicate<NightScoutInsulinCache> { cache in
                    cache.timestamp >= start && cache.timestamp <= predictionTimestamp
                },
                sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
            )
            if let results = try? context.fetch(fetch), let cache = results.first {
                multiPrediction.setInsulinTiming(lastInsulinTimestamp: cache.timestamp, predictionTimestamp: predictionTimestamp)
                print("💉 Fallback insulin timestamp from cache: \(cache.timestamp)")
            }
        }
        
        var modelPredictions: [Int: Prediction] = [:]
        
        do {
            // WaveNet 1
            let windowCopy1 = copyMLMultiArray(window)
            let prediction1 = try WaveNet1Service.shared.predict(window: windowCopy1, currentBG: currentBG, usedMgdl: usedMgdl, predictionCount: predictionCount)
            multiPrediction.setPrediction(model: 1, mmol: prediction1.modelOutput)
            modelPredictions[1] = prediction1
            print("✓ WaveNet1: \(String(format: "%.2f", prediction1.modelOutput)) mmol/L = \(String(format: "%.1f", prediction1.modelOutput * 18.0)) mg/dL (Delta: \(String(format: "%.3f", prediction1.modelPredictedChange / (usedMgdl ? 18.0 : 1.0))))")
            
            // WaveNet 2
            let windowCopy2 = copyMLMultiArray(window)
            let prediction2 = try WaveNet2Service.shared.predict(window: windowCopy2, currentBG: currentBG, usedMgdl: usedMgdl, predictionCount: predictionCount)
            multiPrediction.setPrediction(model: 2, mmol: prediction2.modelOutput)
            modelPredictions[2] = prediction2
            print("✓ WaveNet2: \(String(format: "%.2f", prediction2.modelOutput)) mmol/L = \(String(format: "%.1f", prediction2.modelOutput * 18.0)) mg/dL (Delta: \(String(format: "%.3f", prediction2.modelPredictedChange / (usedMgdl ? 18.0 : 1.0))))")
            
            // WaveNet 3
            let windowCopy3 = copyMLMultiArray(window)
            let prediction3 = try WaveNet3Service.shared.predict(window: windowCopy3, currentBG: currentBG, usedMgdl: usedMgdl, predictionCount: predictionCount)
            multiPrediction.setPrediction(model: 3, mmol: prediction3.modelOutput)
            modelPredictions[3] = prediction3
            print("✓ WaveNet3: \(String(format: "%.2f", prediction3.modelOutput)) mmol/L = \(String(format: "%.1f", prediction3.modelOutput * 18.0)) mg/dL (Delta: \(String(format: "%.3f", prediction3.modelPredictedChange / (usedMgdl ? 18.0 : 1.0))))")
            
            // WaveNet 4
            let windowCopy4 = copyMLMultiArray(window)
            let prediction4 = try WaveNet4Service.shared.predict(window: windowCopy4, currentBG: currentBG, usedMgdl: usedMgdl, predictionCount: predictionCount)
            multiPrediction.setPrediction(model: 4, mmol: prediction4.modelOutput)
            modelPredictions[4] = prediction4
            print("✓ WaveNet4: \(String(format: "%.2f", prediction4.modelOutput)) mmol/L = \(String(format: "%.1f", prediction4.modelOutput * 18.0)) mg/dL (Delta: \(String(format: "%.3f", prediction4.modelPredictedChange / (usedMgdl ? 18.0 : 1.0))))")
            
            // WaveNet 5
            let windowCopy5 = copyMLMultiArray(window)
            let prediction5 = try WaveNet5Service.shared.predict(window: windowCopy5, currentBG: currentBG, usedMgdl: usedMgdl, predictionCount: predictionCount)
            multiPrediction.setPrediction(model: 5, mmol: prediction5.modelOutput)
            modelPredictions[5] = prediction5
            print("✓ WaveNet5: \(String(format: "%.2f", prediction5.modelOutput)) mmol/L = \(String(format: "%.1f", prediction5.modelOutput * 18.0)) mg/dL (Delta: \(String(format: "%.3f", prediction5.modelPredictedChange / (usedMgdl ? 18.0 : 1.0))))")
            
            // Only using 5 WaveNet models (WaveNet1-5)
            
            // Save to SwiftData if context is provided
            if let context = modelContext {
                context.insert(multiPrediction)
                do {
                    try context.save()
                    print("✅ MultiModelPrediction saved to SwiftData")
                } catch {
                    print("❌ Failed to save MultiModelPrediction: \(error)")
                }
            }
            
        } catch {
            print("❌ Series Prediction Error: \(error)")
        }
        
        return modelPredictions
    }
}

