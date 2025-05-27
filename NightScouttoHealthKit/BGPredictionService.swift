//
//  BGPredictionService.swift
//  NightScouttoHealthKit
//
//  Created for PatrickPallagi on 2025-05-27
//

import Foundation
import CoreML
import Combine

/// A service that handles blood glucose predictions using a pre-trained BGPersonal model
/// Model architecture: GRU + Attention mechanism + Dense layers
@MainActor
class BGPredictionService: ObservableObject {
    private let healthKitFeatureProvider = HealthKitFeatureProvider()
    
    /// Published properties that can be observed by views
    @Published var lastPrediction: Double = 0
    @Published var lastPredictionTimestamp: Date?
    @Published var isProcessing: Bool = false
    @Published var lastError: String?
    
    /// Predict blood glucose using the pre-trained BGPersonal model
    /// - Returns: A tuple containing the predicted blood glucose value and timestamp
    @MainActor
    func predictBloodGlucose() async throws -> (value: Double, timestamp: Date) {
        isProcessing = true
        defer { isProcessing = false }
        
        do {
            // Clear any previous errors
            self.lastError = nil
            
            // Get the latest glucose value for reference
            let currentGlucose = try await healthKitFeatureProvider.fetchLatestGlucoseValue()
            
            // Build a mock input tensor of the correct shape for the model (1, 24, 71)
            // This is necessary because your BGPersonal model expects this specific shape
            let inputTensor = try MLMultiArray(shape: [1, 24, 71], dataType: .float32)
            
            // Zero-initialize the entire array
            for i in 0..<24*71 {
                inputTensor[i] = 0.0
            }
            
            // Add current glucose value as a key feature
            // Place it in a prominent position in the feature array
            // Note: This is a simplified approach - in a real implementation, you would 
            // need to properly format all features according to your model's expected input format
            inputTensor[0] = NSNumber(value: Float(currentGlucose))
            
            // Use the pre-trained BGPersonal model for prediction
            let model = try BGPersonal()
            
            // Create prediction with the correct input parameter name
            let prediction = try model.prediction(input_layer_1: inputTensor)
            
            // Log all properties of the prediction object to understand its structure
            print("Prediction object structure:")
            let mirror = Mirror(reflecting: prediction)
            var outputValue: Double = 0
            
            for (label, value) in mirror.children {
                print("   \(label ?? "unknown"): \(value) (\(type(of: value)))")
                
                // Attempt to find the output value
                if let multiArray = value as? MLMultiArray {
                    outputValue = multiArray[0].doubleValue
                    print("   Found output value: \(outputValue)")
                    break
                } else if let doubleValue = value as? Double {
                    outputValue = doubleValue
                    print("   Found output value: \(outputValue)")
                    break
                }
            }
            
            // Scale the prediction to a reasonable blood glucose range
            // Assuming the model's raw output needs to be scaled to a meaningful glucose value
            let scaledPrediction = 100.0 + (outputValue * 100.0) // Simple scaling for testing
            
            // Store the prediction and timestamp
            let timestamp = Date()
            self.lastPrediction = scaledPrediction
            self.lastPredictionTimestamp = timestamp
            
            print("🔮 Current glucose: \(String(format: "%.1f", currentGlucose)) mg/dL")
            print("🔮 Predicted glucose: \(String(format: "%.1f", scaledPrediction)) mg/dL")
            
            // Return the prediction and timestamp
            return (scaledPrediction, timestamp)
        } catch {
            // Handle errors
            self.lastError = "Prediction error: \(error.localizedDescription)"
            print("❌ Prediction error: \(error.localizedDescription)")
            throw error
        }
    }
    
    /// Create a prediction record that can be saved to the database
    /// - Parameter useMgdl: Whether to use mg/dL units (true) or mmol/L (false)
    /// - Returns: A Prediction object that can be saved to SwiftData
    @MainActor
    func createPredictionRecord(useMgdl: Bool) async throws -> Prediction {
        let (predictedValue, timestamp) = try await predictBloodGlucose()
        
        // Convert to mmol/L if storing in that unit (BGPersonal outputs in mg/dL)
        let valueInMmol = predictedValue / 18.0
        
        // Get current BG for reference
        let currentBGInMgdl = try await healthKitFeatureProvider.fetchLatestGlucoseValue()
        let currentBGInMmol = currentBGInMgdl / 18.0
        
        // Determine stability status based on recent trend
        // Simple placeholder implementation
        let stabilityStatus = "STABLE"
        
        // Create the prediction object with all necessary fields
        return Prediction(
            timestamp: timestamp,
            predictionValue: useMgdl ? predictedValue : valueInMmol,
            usedMgdlUnits: useMgdl,
            currentBG: currentBGInMmol,
            stabilityStatus: stabilityStatus
        )
    }
    
    /// Request HealthKit authorization (should be called early in the app lifecycle)
    func requestHealthKitAuthorization() async throws {
        try await healthKitFeatureProvider.requestAuth()
    }
}
