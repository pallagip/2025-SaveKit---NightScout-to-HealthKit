import Foundation
import CoreML
import HealthKit

/**
 Swift implementation for glucose prediction using the exported Random Forest model
 
 Usage:
 1. Add GlucosePredictor.mlpackage to your Xcode project
 2. Include scaler_params.json in your app bundle
 3. Use this class to make predictions from HealthKit data
 */

class GlucosePredictionSystem {
    private var model: MLModel?
    private var scalerMean: [Double] = []
    private var scalerScale: [Double] = []
    
    init() {
        print("🌲 Initializing GlucosePredictionSystem...")
        loadModel()
        loadScalerParams()
    }
    
    private func loadModel() {
        print("🔍 Looking for GlucosePredictor.mlpackage in bundle...")
        
        // Try multiple approaches to find the model
        var modelURL: URL?
        
        // Method 1: Look for compiled model (.mlmodelc)
        modelURL = Bundle.main.url(forResource: "GlucosePredictor", withExtension: "mlmodelc")
        if modelURL != nil {
            print("🔍 Found compiled model (.mlmodelc)")
        }
        
        // Method 2: Look for original package (.mlpackage)
        if modelURL == nil {
            modelURL = Bundle.main.url(forResource: "GlucosePredictor", withExtension: "mlpackage")
            if modelURL != nil {
                print("🔍 Found original package (.mlpackage)")
            }
        }
        
        // Method 3: Direct path search for compiled model
        if modelURL == nil {
            if let bundlePath = Bundle.main.resourcePath {
                let directPath = bundlePath + "/GlucosePredictor.mlmodelc"
                if FileManager.default.fileExists(atPath: directPath) {
                    modelURL = URL(fileURLWithPath: directPath)
                    print("🔍 Found model via direct path: \(directPath)")
                }
            }
        }
        
        guard let finalModelURL = modelURL else {
            print("❌ Could not find GlucosePredictor.mlpackage in bundle")
            print("📁 Available bundle resources:")
            if let bundlePath = Bundle.main.resourcePath {
                do {
                    let files = try FileManager.default.contentsOfDirectory(atPath: bundlePath)
                    for file in files {
                        if file.contains("Glucose") || file.contains("mlpackage") || file.contains("mlmodelc") {
                            print("   - \(file) ⭐")
                        } else {
                            print("   - \(file)")
                        }
                    }
                } catch {
                    print("   Error listing files: \(error)")
                }
            }
            return
        }
        
        print("✅ Found model at: \(finalModelURL)")
        
        do {
            model = try MLModel(contentsOf: finalModelURL)
            print("✅ CoreML model loaded successfully")
        } catch {
            print("❌ Failed to load CoreML model: \(error)")
            print("❌ Model URL: \(finalModelURL)")
        }
    }
    
    private func loadScalerParams() {
        print("🔍 Looking for scaler_params.json in bundle...")
        
        guard let url = Bundle.main.url(forResource: "scaler_params", withExtension: "json") else {
            print("❌ Could not find scaler_params.json in bundle")
            return
        }
        
        print("✅ Found scaler_params.json at: \(url)")
        
        do {
            let data = try Data(contentsOf: url)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let mean = json["mean"] as? [Double],
               let scale = json["scale"] as? [Double] {
                scalerMean = mean
                scalerScale = scale
                print("✅ Scaler parameters loaded: \(mean.count) features")
            } else {
                print("❌ Invalid scaler_params.json format")
            }
        } catch {
            print("❌ Failed to load scaler params: \(error)")
        }
    }
    
    /**
     Extract features from glucose history and other health data
     This must match EXACTLY with the Python implementation
     */
    func extractFeatures(
        glucoseHistory: [Double],
        carbsHistory: [Double],
        insulinHistory: [Double],
        heartRateHistory: [Double],
        currentTime: Date
    ) -> [Double] {
        var features: [Double] = []
        
        // Glucose features (8 features)
        let glucoseClean = glucoseHistory.filter { $0 >= 40.0 && $0 <= 500.0 }
        
        if !glucoseClean.isEmpty {
            let current = glucoseHistory.last ?? 100.0
            let mean = glucoseClean.reduce(0, +) / Double(glucoseClean.count)
            let std = sqrt(glucoseClean.map { pow($0 - mean, 2) }.reduce(0, +) / Double(glucoseClean.count))
            let trend = glucoseHistory.count > 1 ? (glucoseHistory.last! - glucoseHistory.first!) : 0.0
            let median = glucoseClean.sorted()[glucoseClean.count / 2]
            let sorted = glucoseClean.sorted()
            let q75 = sorted[Int(0.75 * Double(sorted.count))]
            let q25 = sorted[Int(0.25 * Double(sorted.count))]
            let iqr = q75 - q25
            
            features.append(contentsOf: [current, mean, std, trend, median, iqr])
            
            // Rate of change features
            if glucoseHistory.count >= 3 {
                let rate5min = glucoseHistory[glucoseHistory.count - 1] - glucoseHistory[glucoseHistory.count - 2]
                let rate10min = (glucoseHistory[glucoseHistory.count - 1] - glucoseHistory[glucoseHistory.count - 3]) / 2.0
                features.append(contentsOf: [rate5min, rate10min])
            } else {
                features.append(contentsOf: [0.0, 0.0])
            }
        } else {
            features.append(contentsOf: [100.0, 100.0, 0.0, 0.0, 100.0, 0.0, 0.0, 0.0])
        }
        
        // Recent inputs features (12 features: 4 each for carbs, insulin, heart_rate)
        let inputHistories = [carbsHistory, insulinHistory, heartRateHistory]
        let defaults = [0.0, 0.0, 70.0]
        
        for (i, history) in inputHistories.enumerated() {
            let defaultVal = defaults[i]
            let last6 = Array(history.suffix(6))
            
            if !last6.isEmpty {
                let last = last6.last ?? defaultVal
                let sum = last6.reduce(0, +)
                let max = last6.max() ?? defaultVal
                let mean = sum / Double(last6.count)
                features.append(contentsOf: [last, sum, max, mean])
            } else {
                features.append(contentsOf: [defaultVal, 0.0, defaultVal, defaultVal])
            }
        }
        
        // Time features (6 features)
        let calendar = Calendar.current
        let hour = Double(calendar.component(.hour, from: currentTime))
        let weekday = Double(calendar.component(.weekday, from: currentTime) - 1) // 0-6
        
        let hourSin = sin(2.0 * .pi * hour / 24.0)
        let hourCos = cos(2.0 * .pi * hour / 24.0)
        let daySin = sin(2.0 * .pi * weekday / 7.0)
        let dayCos = cos(2.0 * .pi * weekday / 7.0)
        
        features.append(contentsOf: [hourSin, hourCos, daySin, dayCos, hour, weekday])
        
        return features
    }
    
    /**
     Scale features using the saved StandardScaler parameters
     */
    private func scaleFeatures(_ features: [Double]) -> [Double] {
        guard features.count == scalerMean.count && features.count == scalerScale.count else {
            print("❌ Feature count mismatch: got \(features.count), expected \(scalerMean.count)")
            return features
        }
        
        return zip(zip(features, scalerMean), scalerScale).map { arg in
            let ((feature, mean), scale) = arg
            return (feature - mean) / scale
        }
    }
    
    /**
     Make glucose prediction for 20 minutes ahead
     */
    func predictGlucose(
        glucoseHistory: [Double],
        carbsHistory: [Double] = [],
        insulinHistory: [Double] = [],
        heartRateHistory: [Double] = [],
        currentTime: Date = Date()
    ) -> Double? {
        
        print("🌲 GlucosePredictionSystem.predictGlucose() called")
        print("🌲 Model loaded: \(model != nil)")
        print("🌲 Scaler params loaded: \(scalerMean.count) mean, \(scalerScale.count) scale")
        
        if model == nil {
            print("❌ Model not loaded - attempting to reload...")
            loadModel() // Try to load again
            if model != nil {
                print("✅ Model loaded successfully on retry")
            } else {
                print("❌ Model still not loaded after retry")
                return nil
            }
        }
        
        guard let model = model else {
            print("❌ Model still nil after reload attempt")
            return nil
        }
        
        // Extract and scale features
        let rawFeatures = extractFeatures(
            glucoseHistory: glucoseHistory,
            carbsHistory: carbsHistory,
            insulinHistory: insulinHistory,
            heartRateHistory: heartRateHistory,
            currentTime: currentTime
        )
        
        let scaledFeatures = scaleFeatures(rawFeatures)
        
        // Ensure we have exactly 26 features
        guard scaledFeatures.count == 26 else {
            print("❌ Expected 26 features, got \(scaledFeatures.count)")
            return nil
        }
        
        // Create input dictionary with feature names
        let featureNames = [
            "glucose_current", "glucose_clean_mean", "glucose_clean_std", "glucose_trend",
            "glucose_clean_median", "glucose_clean_iqr", "rate_5min", "rate_10min",
            "carbs_last", "carbs_sum_6", "carbs_max_6", "carbs_mean_6",
            "insulin_last", "insulin_sum_6", "insulin_max_6", "insulin_mean_6",
            "heart_rate_last", "heart_rate_sum_6", "heart_rate_max_6", "heart_rate_mean_6",
            "hour_sin", "hour_cos", "day_sin", "day_cos", "hour", "weekday"
        ]
        
        var inputDict: [String: Any] = [:]
        for (index, featureName) in featureNames.enumerated() {
            inputDict[featureName] = scaledFeatures[index]
        }
        
        // Make prediction using MLDictionaryFeatureProvider
        do {
            let inputProvider = try MLDictionaryFeatureProvider(dictionary: inputDict)
            let output = try model.prediction(from: inputProvider)
            
            // The model output is called 'prediction' based on the metadata
            if let prediction = output.featureValue(for: "prediction")?.doubleValue {
                return prediction
            }
            
        } catch {
            print("❌ Prediction failed: \(error)")
        }
        
        return nil
    }
}

// MARK: - HealthKit Integration Helper

extension GlucosePredictionSystem {
    
    /**
     Extract glucose predictions from HealthKit data
     */
    func predictFromHealthKit(
        healthStore: HKHealthStore,
        completion: @escaping (Double?) -> Void
    ) {
        
        let glucoseType = HKQuantityType.quantityType(forIdentifier: .bloodGlucose)!
        // TODO: Add carb and heart rate queries for complete feature extraction
        // let carbType = HKQuantityType.quantityType(forIdentifier: .dietaryCarbohydrates)!
        // let heartRateType = HKQuantityType.quantityType(forIdentifier: .heartRate)!
        
        let now = Date()
        let lookbackTime = Calendar.current.date(byAdding: .hour, value: -4, to: now)!
        
        let predicate = HKQuery.predicateForSamples(withStart: lookbackTime, end: now, options: .strictEndDate)
        
        // Query glucose data
        let glucoseQuery = HKSampleQuery(
            sampleType: glucoseType,
            predicate: predicate,
            limit: HKObjectQueryNoLimit,
            sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
        ) { [weak self] (_, samples, error) in
            
            guard let samples = samples as? [HKQuantitySample], !samples.isEmpty else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            
            // Convert to mg/dL if needed and extract values
            let unit = HKUnit(from: "mg/dL")
            let glucoseValues = samples.map { sample in
                sample.quantity.doubleValue(for: unit)
            }
            
            // For simplicity, using empty arrays for carbs/insulin/HR
            // In a real app, you'd query these as well
            let prediction = self?.predictGlucose(
                glucoseHistory: glucoseValues,
                currentTime: now
            )
            
            DispatchQueue.main.async {
                completion(prediction)
            }
        }
        
        healthStore.execute(glucoseQuery)
    }
}

// MARK: - Usage Example

/*
 Example usage in your app:
 
 let predictor = GlucosePredictionSystem()
 
 // Option 1: Manual prediction with known values
 let glucoseHistory = [120.0, 125.0, 130.0, 128.0, 126.0] // mg/dL
 let prediction = predictor.predictGlucose(glucoseHistory: glucoseHistory)
 print("Predicted glucose in 20 min: \(prediction ?? 0) mg/dL")
 
 // Option 2: HealthKit integration
 predictor.predictFromHealthKit(healthStore: healthStore) { prediction in
     if let pred = prediction {
         print("HealthKit prediction: \(pred) mg/dL")
     }
 }
 */
