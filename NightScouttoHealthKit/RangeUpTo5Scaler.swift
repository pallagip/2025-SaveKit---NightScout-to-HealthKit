import Foundation
import CoreML

/// Scaler for RangeUpTo5 TCN model - handles input normalization
/// This class provides standardization (z-score normalization) for the 8-feature input data
class RangeUpTo5Scaler {
    
    // Scaler parameters loaded from rangeupto5_scaler.npz
    private let mean: [Double] = [
        1.76495488e-05,   // Feature 0
        7.19699323e+00,   // Feature 1  
        2.95034769e+01,   // Feature 2
        9.31646099e+01,   // Feature 3
        -4.86531749e-02,  // Feature 4
        -2.38062278e-01,  // Feature 5
        6.01053870e-04,   // Feature 6
        7.79762118e+00    // Feature 7
    ]
    
    private let scale: [Double] = [
        0.13712759,       // Feature 0
        2.51077654,       // Feature 1
        17.95848206,      // Feature 2
        17.42685351,      // Feature 3
        0.75643173,       // Feature 4
        0.60726456,       // Feature 5
        3.10011919,       // Feature 6
        4.22656272        // Feature 7
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
extension RangeUpTo5Scaler {
    /// Example usage of the scaler with the CoreML model
    static func exampleUsage() {
        let scaler = RangeUpTo5Scaler()
        
        // Example raw data - replace with your actual sensor readings
        var rawData: [[Double]] = []
        for timestep in 0..<numberOfTimesteps {
            rawData.append(Array(repeating: 0.0, count: numberOfFeatures))
        }
        
        do {
            // Scale the data for model input
            let modelInput = try scaler.prepareInputForModel(rawData)
            
            // Load and use your CoreML model
            // let model = try RangeUpTo5TCN(configuration: MLModelConfiguration())
            // let prediction = try model.prediction(from: modelInput)
            
            print("✅ Data successfully prepared for RangeUpTo5 TCN model")
        } catch {
            print("❌ Error preparing data: \(error)")
        }
    }
}
