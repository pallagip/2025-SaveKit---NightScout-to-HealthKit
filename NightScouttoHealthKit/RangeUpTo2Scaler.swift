import Foundation
import CoreML

/// Scaler for RangeUpTo2 TCN model - handles input normalization
/// This class provides standardization (z-score normalization) for the 8-feature input data
class RangeUpTo2Scaler {
    
    // Scaler parameters loaded from rangeupto2_scaler.npz
    private let mean: [Double] = [
        -8.33385980e-05,  // Feature 0
        6.78879275e+00,   // Feature 1  
        2.89364856e+01,   // Feature 2
        9.25925429e+01,   // Feature 3
        7.05984944e-03,   // Feature 4
        -2.75050807e-01,  // Feature 5
        5.49607264e-05,   // Feature 6
        6.34844815e+00    // Feature 7
    ]
    
    private let scale: [Double] = [
        0.14624189,       // Feature 0
        2.488291,         // Feature 1
        17.99767167,      // Feature 2
        18.20024458,      // Feature 3
        0.74590794,       // Feature 4
        0.6065629,        // Feature 5
        3.38990451,       // Feature 6
        3.42000834        // Feature 7
    ]
    
    /// Number of features expected by the model
    static let numberOfFeatures = 8
    
    /// Number of timesteps expected by the model  
    static let numberOfTimesteps = 24
    
    /// Transform input data using standardization (z-score normalization)
    /// - Parameter input: 2D array of shape [timesteps, features] 
    /// - Returns: Scaled 2D array of same shape
    func transform(_ input: [[Double]]) -> [[Double]] {
        guard !input.isEmpty else { return input }
        guard input[0].count == Self.numberOfFeatures else {
            fatalError("Expected \(Self.numberOfFeatures) features, got \(input[0].count)")
        }
        
        var scaled = input
        for t in 0..<input.count {
            for f in 0..<Self.numberOfFeatures {
                scaled[t][f] = (input[t][f] - mean[f]) / scale[f]
            }
        }
        return scaled
    }
    
    /// Transform input data for CoreML model input
    /// - Parameter input: 2D array of shape [timesteps, features]
    /// - Returns: MLMultiArray ready for model prediction
    func transformForCoreML(_ input: [[Double]]) throws -> MLMultiArray {
        let scaledInput = transform(input)
        
        // Create MLMultiArray with shape [1, timesteps, features] for batch dimension
        let shape = [1, scaledInput.count, Self.numberOfFeatures] as [NSNumber]
        let multiArray = try MLMultiArray(shape: shape, dataType: .double)
        
        for t in 0..<scaledInput.count {
            for f in 0..<Self.numberOfFeatures {
                let index = [0, t, f] as [NSNumber]
                multiArray[index] = NSNumber(value: scaledInput[t][f])
            }
        }
        
        return multiArray
    }
    
    /// Inverse transform to get original scale data
    /// - Parameter scaledInput: Scaled 2D array 
    /// - Returns: Original scale 2D array
    func inverseTransform(_ scaledInput: [[Double]]) -> [[Double]] {
        guard !scaledInput.isEmpty else { return scaledInput }
        guard scaledInput[0].count == Self.numberOfFeatures else {
            fatalError("Expected \(Self.numberOfFeatures) features, got \(scaledInput[0].count)")
        }
        
        var original = scaledInput
        for t in 0..<scaledInput.count {
            for f in 0..<Self.numberOfFeatures {
                original[t][f] = (scaledInput[t][f] * scale[f]) + mean[f]
            }
        }
        return original
    }
    
    /// Convenience method to prepare data for the TCN model
    /// - Parameter rawData: Raw sensor data [timesteps, features]
    /// - Returns: Dictionary ready for CoreML prediction
    func prepareInputForModel(_ rawData: [[Double]]) throws -> [String: MLFeatureValue] {
        let scaledArray = try transformForCoreML(rawData)
        return ["input_1": MLFeatureValue(multiArray: scaledArray)]
    }
}

// MARK: - Usage Example
extension RangeUpTo2Scaler {
    /// Example usage of the scaler with the CoreML model
    static func exampleUsage() {
        let scaler = RangeUpTo2Scaler()
        
        // Example raw data - replace with your actual sensor readings
        var rawData: [[Double]] = []
        for timestep in 0..<numberOfTimesteps {
            rawData.append(Array(repeating: 0.0, count: numberOfFeatures))
        }
        
        do {
            // Scale the data for model input
            let modelInput = try scaler.prepareInputForModel(rawData)
            
            // Load and use your CoreML model
            // let model = try RangeUpTo2TCN(configuration: MLModelConfiguration())
            // let prediction = try model.prediction(from: modelInput)
            
            print("✅ Data successfully prepared for RangeUpTo2 TCN model")
        } catch {
            print("❌ Error preparing data: \(error)")
        }
    }
}
