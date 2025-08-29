//
//  DeltaBGPredictor.swift
//  NightScouttoHealthKit
//
//  Created for PatrickPallagi on 2025-08-28
//

import CoreML
import Accelerate

final class BGStandardizer {
    let T = 24, F = 8
    let mean: [Float]
    let std:  [Float]

    init(model: MLModel) {
        let meta = model.modelDescription.metadata
        let cd   = (meta[.creatorDefinedKey] as? [String:String]) ?? [:]

        func decode(_ k: String) -> [Float] {
            guard let s = cd[k], let d = s.data(using: .utf8),
                  let arr = try? JSONDecoder().decode([Double].self, from: d)
            else { return Array(repeating: 0, count: 8) }
            return arr.map { Float($0) }
        }

        self.mean = decode("scaler_mean")   // length = 8
        self.std  = decode("scaler_std")    // length = 8
    }

    /// Scales input features into an MLMultiArray shaped [1, 1, 12] for WaveNetPro models (rank 3)
    func makeInput(from features: [Float]) throws -> MLMultiArray {
        precondition(features.count == 12, "Expected 12 features, got \(features.count)")

        let x = try MLMultiArray(shape: [1, 1, 12], dataType: .float32)

        // Standardize feature-by-feature with available mean/std (use first 8 if available)
        for f in 0..<12 {
            let meanValue = f < mean.count ? mean[f] : 0.0
            let stdValue = f < std.count ? std[f] : 1.0
            
            // Apply proper normalization to prevent values in millions
            let normalizedValue = (features[f] - meanValue) / max(stdValue, 1e-6)
            x[f] = NSNumber(value: normalizedValue)
        }
        return x
    }
}

final class DeltaBGWaveNet {
    private let model: MLModel
    private let standardizer: BGStandardizer
    private let outName: String

    init(resource: String, outName: String = "delta_bg_20m") throws {
        // Try to load model from bundle - support both .mlmodelc and .mlpackage
        var url: URL?
        if let compiledURL = Bundle.main.url(forResource: resource, withExtension: "mlmodelc") {
            url = compiledURL
        } else if let packageURL = Bundle.main.url(forResource: resource, withExtension: "mlpackage") {
            url = packageURL
        }
        
        guard let modelURL = url else {
            throw NSError(domain: "WaveNet", code: 1, userInfo: [NSLocalizedDescriptionKey: "Model \(resource) not found"])
        }
        
        model = try MLModel(contentsOf: modelURL)
        standardizer = BGStandardizer(model: model)
        
        // if you didn't rename output in Python, set outName = "Identity"
        self.outName = outName
    }

    /// Predict delta BG from 12 features
    func predictDelta(features: [Float]) throws -> Float {
        let input = try standardizer.makeInput(from: features)
        
        // Handle models that require multiple inputs (both x_in and z_in)
        let inputDescriptions = model.modelDescription.inputDescriptionsByName
        print("🔍 Available input names: \(Array(inputDescriptions.keys))")
        
        var inputDict: [String: MLFeatureValue] = [:]
        
        // Check if model requires both x_in and z_in
        if inputDescriptions.keys.contains("x_in") && inputDescriptions.keys.contains("z_in") {
            print("🔍 Model requires both x_in and z_in - providing same input for both")
            inputDict["x_in"] = MLFeatureValue(multiArray: input)
            inputDict["z_in"] = MLFeatureValue(multiArray: input)
        } else if inputDescriptions.keys.contains("x_in") {
            print("🔍 Using input name: x_in")
            inputDict["x_in"] = MLFeatureValue(multiArray: input)
        } else if inputDescriptions.keys.contains("z_in") {
            print("🔍 Using input name: z_in")
            inputDict["z_in"] = MLFeatureValue(multiArray: input)
        } else if inputDescriptions.keys.contains("input") {
            print("🔍 Using input name: input")
            inputDict["input"] = MLFeatureValue(multiArray: input)
        } else {
            let fallbackName = inputDescriptions.keys.first ?? "input"
            print("🔍 Using fallback input name: \(fallbackName)")
            inputDict[fallbackName] = MLFeatureValue(multiArray: input)
        }
        
        let provider = try MLDictionaryFeatureProvider(dictionary: inputDict)
        let out = try model.prediction(from: provider)
        guard let delta = out.featureValue(for: outName)?.doubleValue
              ?? out.featureValue(for: "Identity")?.doubleValue else {
            throw NSError(domain: "WaveNet", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing output"])
        }
        return Float(delta)
    }
}

// tiny safe index
private extension Array {
    subscript(safe i: Int) -> Element? { (indices ~= i) ? self[i] : nil }
}
