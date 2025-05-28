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
    
    // Constants for prediction scaling and adjustment
    private let baseGlucose: Double = 100.0
    private let insulinSensitivityFactor: Double = 40.0 // mg/dL drop per 1U of insulin
    private let carbRatio: Double = 10.0 // 1U per 10g carbs
    
    // Cache for IOB and COB calculations
    private var cachedIOB: Double = 0
    private var cachedCOB: Double = 0
    private var cachedIOBTimestamp: Date?
    private var cachedCOBTimestamp: Date?
    
    // Cache timeout in minutes
    private let cacheTimeoutMinutes: Double = 5
    
    /// Predict blood glucose using the pre-trained BGPersonal model and dynamic factors
    /// - Returns: A tuple containing the predicted blood glucose value and timestamp
    @MainActor
    func predictBloodGlucose() async throws -> (value: Double, timestamp: Date) {
        isProcessing = true
        defer { isProcessing = false }
        
        do {
            // Clear any previous errors
            self.lastError = nil
            
            // Get the latest glucose values and calculate trend (momentum)
            let currentGlucose = try await healthKitFeatureProvider.fetchLatestGlucoseValue()
            let recentGlucoseReadings = try await healthKitFeatureProvider.fetchRecentGlucoseValues(limit: 10)
            
            // Calculate glucose momentum (rate of change)
            let momentum = calculateMomentum(from: recentGlucoseReadings)
            
            // Get IOB (Insulin On Board)
            let iob = try await getInsulinOnBoard()
            
            // Get COB (Carbs On Board)
            let cob = try await getCarbsOnBoard()
            
            // Get time-of-day factor (circadian rhythm effect)
            let timeOfDayFactor = getTimeOfDayFactor()
            
            // Build the input tensor for the model (1, 24, 71)
            let inputTensor = try buildInputTensor(
                currentGlucose: currentGlucose,
                recentReadings: recentGlucoseReadings,
                iob: iob,
                cob: cob,
                momentum: momentum,
                timeOfDayFactor: timeOfDayFactor
            )
            
            // Use the pre-trained BGPersonal model for prediction
            let model = try BGPersonal()
            
            // Create prediction with the correct input parameter name
            let prediction = try model.prediction(input_layer_1: inputTensor)
            
            // Extract the prediction value from the model output
            let outputValue = extractOutputValue(from: prediction)
            
            // Calculate the scaled and adjusted prediction
            let scaledPrediction = calculateFinalPrediction(
                rawPrediction: outputValue,
                currentGlucose: currentGlucose,
                iob: iob,
                cob: cob,
                momentum: momentum,
                timeOfDayFactor: timeOfDayFactor
            )
            
            // Store the prediction and timestamp
            let timestamp = Date()
            self.lastPrediction = scaledPrediction
            self.lastPredictionTimestamp = timestamp
            
            print("🔮 Current glucose: \(String(format: "%.1f", currentGlucose)) mg/dL")
            print("🔮 Predicted glucose: \(String(format: "%.1f", scaledPrediction)) mg/dL")
            print("🔮 Predicted glucose (mmol/L): \(String(format: "%.1f", scaledPrediction / 18.0)) mmol/L")
            print("📊 Prediction factors: IOB=\(String(format: "%.2f", iob))U, COB=\(String(format: "%.1f", cob))g, Momentum=\(String(format: "%.2f", momentum)) mg/dL/min")
            
            // Return the prediction and timestamp (always in mg/dL internally)
            return (scaledPrediction, timestamp)
        } catch {
            // Handle errors
            self.lastError = "Prediction error: \(error.localizedDescription)"
            print("❌ Prediction error: \(error.localizedDescription)")
            throw error
        }
    }
    
    /// Build the input tensor for the prediction model
    private func buildInputTensor(
        currentGlucose: Double,
        recentReadings: [Double],
        iob: Double,
        cob: Double,
        momentum: Double,
        timeOfDayFactor: Double
    ) throws -> MLMultiArray {
        // Create the input tensor with the correct shape
        let inputTensor = try MLMultiArray(shape: [1, 24, 71], dataType: .float32)
        
        // Initially zero-initialize the array
        for i in 0..<24*71 {
            inputTensor[i] = 0.0
        }
        
        // Fill in key features at specific positions
        // Position 0: Current glucose value
        inputTensor[0] = NSNumber(value: Float(currentGlucose))
        
        // Add recent glucose readings (for trend analysis)
        for (index, reading) in recentReadings.enumerated() {
            if index < 10 { // Only use up to 10 recent readings
                inputTensor[index + 1] = NSNumber(value: Float(reading))
            }
        }
        
        // Add IOB, COB, momentum, and time factor at specific positions
        inputTensor[11] = NSNumber(value: Float(iob))
        inputTensor[12] = NSNumber(value: Float(cob))
        inputTensor[13] = NSNumber(value: Float(momentum))
        inputTensor[14] = NSNumber(value: Float(timeOfDayFactor))
        
        return inputTensor
    }
    
    /// Extract the output value from the model prediction
    private func extractOutputValue(from prediction: BGPersonalOutput) -> Double {
        let mirror = Mirror(reflecting: prediction)
        var outputValue: Double = 0
        
        for (_, value) in mirror.children {
            // Attempt to find the output value
            if let multiArray = value as? MLMultiArray {
                outputValue = multiArray[0].doubleValue
                break
            } else if let doubleValue = value as? Double {
                outputValue = doubleValue
                break
            }
        }
        
        return outputValue
    }
    
    /// Calculate the final prediction based on all factors
    private func calculateFinalPrediction(
        rawPrediction: Double,
        currentGlucose: Double,
        iob: Double,
        cob: Double,
        momentum: Double,
        timeOfDayFactor: Double
    ) -> Double {
        // Start with the current glucose as base
        var prediction = currentGlucose
        
        // Apply model prediction as a scaling factor
        prediction = prediction + (rawPrediction * 50.0)
        
        // Apply insulin effect (IOB decreases glucose)
        prediction = prediction - (iob * insulinSensitivityFactor)
        
        // Apply carb effect (COB increases glucose)
        prediction = prediction + (cob / carbRatio * insulinSensitivityFactor)
        
        // Apply momentum (trend effect over 30 minutes)
        prediction = prediction + (momentum * 30.0)
        
        // Apply time-of-day factor
        prediction = prediction * timeOfDayFactor
        
        // Ensure prediction stays in a reasonable range
        prediction = max(40.0, min(400.0, prediction))
        
        return prediction
    }
    
    /// Calculate momentum (rate of change) from recent glucose readings
    private func calculateMomentum(from readings: [Double]) -> Double {
        guard readings.count >= 2 else { return 0.0 }
        
        // Use the most recent readings for calculating rate of change
        let latestReading = readings[0]
        let previousReading = readings[1]
        
        // Assume readings are 5 minutes apart, calculate mg/dL per minute
        let rateOfChange = (latestReading - previousReading) / 5.0
        
        return rateOfChange
    }
    
    /// Get Insulin On Board (IOB)
    private func getInsulinOnBoard() async throws -> Double {
        // Check if we have a recent cached value
        if let timestamp = cachedIOBTimestamp,
           Date().timeIntervalSince(timestamp) < (cacheTimeoutMinutes * 60) {
            return cachedIOB
        }
        
        // Fetch recent insulin doses from HealthKit
        let recentInsulin = try await healthKitFeatureProvider.fetchRecentInsulinDoses(hoursBack: 6)
        
        // Calculate IOB based on insulin activity curve
        // This is a simplified model - a real implementation would use more sophisticated models
        var totalIOB: Double = 0.0
        let now = Date()
        
        for dose in recentInsulin {
            let hoursAgo = now.timeIntervalSince(dose.timestamp) / 3600.0
            let remainingActivity = calculateInsulinActivityFactor(hoursAgo: hoursAgo)
            totalIOB += dose.units * remainingActivity
        }
        
        // Cache the result
        cachedIOB = totalIOB
        cachedIOBTimestamp = now
        
        return totalIOB
    }
    
    /// Calculate insulin activity factor based on hours since dose
    private func calculateInsulinActivityFactor(hoursAgo: Double) -> Double {
        // Simplified bilinear insulin activity curve for rapid-acting insulin
        // Assumes peak activity at 1 hour, duration of 4 hours
        if hoursAgo < 0 {
            return 0.0 // Future doses don't affect current IOB
        } else if hoursAgo < 1.0 {
            return 1.0 - (hoursAgo * 0.5) // Linear increase to peak
        } else if hoursAgo < 4.0 {
            return 0.5 - (0.5 * (hoursAgo - 1.0) / 3.0) // Linear decay from peak
        } else {
            return 0.0 // No activity after 4 hours
        }
    }
    
    /// Get Carbs On Board (COB)
    private func getCarbsOnBoard() async throws -> Double {
        // Check if we have a recent cached value
        if let timestamp = cachedCOBTimestamp,
           Date().timeIntervalSince(timestamp) < (cacheTimeoutMinutes * 60) {
            return cachedCOB
        }
        
        // Fetch recent carb intake from HealthKit
        let recentCarbs = try await healthKitFeatureProvider.fetchRecentCarbIntake(hoursBack: 6)
        
        // Calculate COB based on carb absorption curve
        var totalCOB: Double = 0.0
        let now = Date()
        
        for intake in recentCarbs {
            let hoursAgo = now.timeIntervalSince(intake.timestamp) / 3600.0
            let remainingFactor = calculateCarbAbsorptionFactor(hoursAgo: hoursAgo)
            totalCOB += intake.grams * remainingFactor
        }
        
        // Cache the result
        cachedCOB = totalCOB
        cachedCOBTimestamp = now
        
        return totalCOB
    }
    
    /// Calculate carb absorption factor based on hours since intake
    private func calculateCarbAbsorptionFactor(hoursAgo: Double) -> Double {
        // Simplified linear carb absorption curve
        // Assumes linear absorption over 4 hours
        if hoursAgo < 0 {
            return 1.0 // Future carbs are fully unabsorbed
        } else if hoursAgo < 4.0 {
            return 1.0 - (hoursAgo / 4.0) // Linear absorption
        } else {
            return 0.0 // Fully absorbed after 4 hours
        }
    }
    
    /// Get time-of-day factor for circadian rhythm effects
    private func getTimeOfDayFactor() -> Double {
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: Date())
        
        // Implement circadian rhythm factors:
        // - Dawn phenomenon: Higher BG in early morning (4-8 AM)
        // - Post-meal periods: Higher BG after typical meal times
        // - Overnight: Lower BG during sleep (1-3 AM)
        switch hour {
        case 4...7: // Dawn phenomenon
            return 1.10
        case 8...9: // Breakfast effect
            return 1.05
        case 12...13: // Lunch effect
            return 1.05
        case 18...19: // Dinner effect
            return 1.05
        case 1...3: // Overnight
            return 0.95
        default:
            return 1.0
        }
    }
    
    /// Create a prediction record that can be saved to the database
    /// - Parameter useMgdl: Whether to use mg/dL units (true) or mmol/L (false)
    /// - Returns: A Prediction object that can be saved to SwiftData
    @MainActor
    func createPredictionRecord(useMgdl: Bool) async throws -> Prediction {
        // Get prediction from the forecasting algorithm (always returns mg/dL internally)
        let (predictedValueMgdl, timestamp) = try await predictBloodGlucose()
        
        // Log both representations for debugging
        print("🔍 Creating prediction record:")
        print("  - Predicted mg/dL: \(String(format: "%.1f", predictedValueMgdl))")
        print("  - Predicted mmol/L: \(String(format: "%.1f", predictedValueMgdl / 18.0))")
        print("  - Storing in \(useMgdl ? "mg/dL" : "mmol/L") format")
        
        // Get current BG for reference
        let currentBGInMgdl = try await healthKitFeatureProvider.fetchLatestGlucoseValue()
        let currentBGInMmol = currentBGInMgdl / 18.0
        
        // Calculate momentum for stability status
        let recentReadings = try await healthKitFeatureProvider.fetchRecentGlucoseValues(limit: 3)
        let momentum = calculateMomentum(from: recentReadings)
        
        // Determine stability status based on recent trend
        let stabilityStatus = determineStabilityStatus(momentum: momentum)
        
        // Create the prediction object with all necessary fields
        // If using mmol/L, convert the prediction from mg/dL to mmol/L
        let finalPredictionValue = useMgdl ? predictedValueMgdl : (predictedValueMgdl / 18.0)
        
        return Prediction(
            timestamp: timestamp,
            predictionValue: finalPredictionValue,
            usedMgdlUnits: useMgdl,
            currentBG: currentBGInMmol,
            stabilityStatus: stabilityStatus
        )
    }
    
    /// Determine stability status based on glucose momentum
    private func determineStabilityStatus(momentum: Double) -> String {
        switch momentum {
        case _ where momentum < -2.0:
            return "FALLING"
        case _ where momentum < -1.0:
            return "DECREASING"
        case _ where momentum < 1.0:
            return "STABLE"
        case _ where momentum < 2.0:
            return "INCREASING"
        default:
            return "RISING"
        }
    }
    
    /// Request HealthKit authorization (should be called early in the app lifecycle)
    func requestHealthKitAuthorization() async throws {
        try await healthKitFeatureProvider.requestAuth()
    }
}
