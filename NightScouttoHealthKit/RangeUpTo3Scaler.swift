import Foundation
import CoreML

/// Scaler for RangeUpTo3 TCN model - handles input normalization
/// This class provides standardization (z-score normalization) for the 8-feature input data
class RangeUpTo3Scaler {
    
    // Scaler parameters loaded from rangeupto3_scaler.npz
    private let mean: [Double] = [
        9.88644971e-05,   // Feature 0
        7.07926289e+00,   // Feature 1  
        3.01271406e+01,   // Feature 2
        9.38179864e+01,   // Feature 3
        -6.91328817e-02,  // Feature 4
        -2.55738082e-01,  // Feature 5
        1.46512724e-04,   // Feature 6
        7.36155600e+00    // Feature 7
    ]
    
    private let scale: [Double] = [
        0.13996414,       // Feature 0
        2.49082564,       // Feature 1
        17.34068823,      // Feature 2
        18.17383343,      // Feature 3
        0.75749435,       // Feature 4
        0.59667495,       // Feature 5
        3.17837028,       // Feature 6
        3.96947432        // Feature 7
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
extension RangeUpTo3Scaler {
    /// Example usage of the scaler with the CoreML model
    static func exampleUsage() {
        let scaler = RangeUpTo3Scaler()
        
        // Example raw data - replace with your actual sensor readings
        var rawData: [[Double]] = []
        for timestep in 0..<numberOfTimesteps {
            rawData.append(Array(repeating: 0.0, count: numberOfFeatures))
        }
        
        do {
            // Scale the data for model input
            let modelInput = try scaler.prepareInputForModel(rawData)
            
            // Load and use your CoreML model
            // let model = try RangeUpTo3TCN(configuration: MLModelConfiguration())
            // let prediction = try model.prediction(from: modelInput)
            
            print("✅ Data successfully prepared for RangeUpTo3 TCN model")
        } catch {
            print("❌ Error preparing data: \(error)")
        }
    }
}
