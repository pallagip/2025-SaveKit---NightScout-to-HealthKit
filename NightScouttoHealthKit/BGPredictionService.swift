//
//  BGPredictionService.swift
//  NightScouttoHealthKit
//
//  Created for PatrickPallagi on 2025-05-27
//

import Foundation
import CoreML
import Combine
import SwiftData

/// A service that handles blood glucose predictions using a pre-trained BGPersonal_BiLSTM model
/// Model architecture: Bidirectional LSTM + Dense layers
@MainActor
class BGPredictionService: ObservableObject {
    private let healthKitFeatureProvider = HealthKitFeatureProvider()
    
    /// Published properties that can be observed by views
    @Published var lastPrediction: Double = 0
    @Published var lastPredictionTimestamp: Date?
    @Published var isProcessing: Bool = false
    @Published var lastError: String?
    @Published var lastModel6Prediction: Double = 0
    @Published var lastModel6PredictionText: String = "—"
    
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
    
    /// Predict blood glucose using the pre-trained BGPersonal_BiLSTM model and dynamic factors
    /// - Returns: A tuple containing the predicted blood glucose value and timestamp
    @MainActor
    func predictBloodGlucose() async throws -> (value: Double, timestamp: Date) {
        isProcessing = true
        defer { isProcessing = false }
        
        do {
            // Clear any previous errors
            self.lastError = nil
            
            print("\n🩺 === HEALTH DATA FETCHING ===")
            
            // Get the latest glucose values and calculate trend (momentum)
            let currentGlucose = try await healthKitFeatureProvider.fetchLatestGlucoseValue()
            print("🩸 Current Blood Glucose: \(String(format: "%.1f", currentGlucose)) mg/dL")
            
            let recentGlucoseReadings = try await healthKitFeatureProvider.fetchRecentGlucoseValues(limit: 10)
            print("📊 Recent glucose readings count: \(recentGlucoseReadings.count)")
            if recentGlucoseReadings.count >= 2 {
                print("📈 Recent values: [\(String(format: "%.1f", recentGlucoseReadings[0])), \(String(format: "%.1f", recentGlucoseReadings[1]))] mg/dL")
            }
            
            // Calculate glucose momentum (rate of change)
            let momentum = calculateMomentum(from: recentGlucoseReadings)
            print("🚀 Glucose Momentum: \(String(format: "%.2f", momentum)) mg/dL/min")
            
            // Get IOB (Insulin On Board)
            let iob = try await getInsulinOnBoard()
            print("💉 Insulin On Board (IOB): \(String(format: "%.2f", iob)) units")
            
            // Get COB (Carbs On Board)
            let cob = try await getCarbsOnBoard()
            print("🍞 Carbs On Board (COB): \(String(format: "%.1f", cob)) grams")
            
            // Get time-of-day factor (circadian rhythm effect)
            let timeOfDayFactor = getTimeOfDayFactor()
            print("🕒 Time of Day Factor: \(String(format: "%.3f", timeOfDayFactor))")
            
            // Get recent heart rate (within last 30 minutes)
            let heartRate = try await healthKitFeatureProvider.fetchLatestHeartRate(minutesBack: 30.0)
            print("❤️ Heart Rate: \(String(format: "%.0f", heartRate)) bpm")
            
            print("🩺 === DATA FETCHING COMPLETE ===\n")
            
            // Build the input tensor for the model (1, 24, 4)
            let inputTensor = try buildInputTensor(
                currentGlucose: currentGlucose,
                recentReadings: recentGlucoseReadings,
                iob: iob,
                cob: cob,
                momentum: momentum,
                timeOfDayFactor: timeOfDayFactor,
                heartRate: heartRate
            )
            
            // Use BGTCN2Service for proper model prediction with scaling
            let predictionResult = try BGTCN2Service.shared.predict(
                window: inputTensor,
                currentBG: currentGlucose,
                usedMgdl: true
            )
            
            // Get the raw prediction value
            let outputValue = predictionResult.modelOutput
            
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
    /// - Parameters:
    ///   - currentGlucose: Current blood glucose value in mg/dL
    ///   - recentReadings: Array of recent glucose readings
    ///   - iob: Insulin on Board in units
    ///   - cob: Carbs on Board in grams
    ///   - momentum: Glucose momentum/trend
    ///   - timeOfDayFactor: Time of day factor for circadian rhythm
    ///   - heartRate: Current heart rate in beats per minute
    /// - Returns: MLMultiArray with shape [1, 24, 8]
    private func buildInputTensor(
        currentGlucose: Double,
        recentReadings: [Double],
        iob: Double,
        cob: Double,
        momentum: Double,
        timeOfDayFactor: Double,
        heartRate: Double
    ) throws -> MLMultiArray {
        // Create the input tensor with shape [1, 24, 8] to match all rangeupto Core ML models
        let inputTensor = try MLMultiArray(shape: [1, 24, 8], dataType: .float32)
        
        // Initialize all values to 0
        for i in 0..<(24 * 8) {
            inputTensor[i] = 0.0
        }
        
        // Calculate simple glucose trend from recent readings
        let glucoseTrend = recentReadings.count >= 2 ? 
            (recentReadings[0] - recentReadings[1]) : 0.0
        
        // Fill the tensor with 8 features for each of the 24 time steps
        // Feature order matches Core ML model expectations:
        // Feature 0: heart_rate - Instantaneous HR from Apple Watch (beats/min)
        // Feature 1: blood_glucose - Sensor glucose at the same timestamp (mmol/L)
        // Feature 2: insulin_dose - Cumulative bolus-insulin "decay" value (effective units still active)
        // Feature 3: dietary_carbohydrates - Cumulative carb-impact "decay" value (grams still being absorbed)
        // Feature 4: bg_trend - Short-term BG slope (Δ mmol/L per 5-min tick)
        // Feature 5: hr_trend - Short-term HR slope (Δ bpm per 5-min tick)
        // Feature 6: hour_sin - Circadian phase – sin(2π · hour/24)
        // Feature 7: hour_cos - Circadian phase – cos(2π · hour/24)
        
        // Log the raw input values
        print("🔍 Building Input Tensor:")
        print("🔍   Heart Rate: \(heartRate) bpm")
        print("🔍   Current Glucose: \(currentGlucose) mg/dL")
        print("🔍   IOB: \(iob) U")
        print("🔍   COB: \(cob) g")
        print("🔍   Glucose Trend: \(glucoseTrend) mg/dL")
        print("🔍   Time of Day Factor: \(timeOfDayFactor)")
        
        let normalizedGlucose = (currentGlucose - 50.0) / 350.0
        let normalizedHeartRate = (heartRate - 40.0) / 160.0  // Normalize HR from 40-200 bpm to 0-1
        print("🔍   Normalized Heart Rate: \(normalizedHeartRate)")
        print("🔍   Normalized Glucose: \(normalizedGlucose)")
        
        // Calculate additional features
        // Convert glucose from mg/dL to mmol/L for feature vector
        let glucoseMmol = currentGlucose / 18.0
        
        // Calculate BG trend in mmol/L per 5-min tick
        // Momentum is in mg/dL/min, so convert to mmol/L per 5-min tick
        let bgTrend = (momentum * 5.0) / 18.0
        
        // Calculate HR trend (if we have sufficient heart rate history)
        // For now, we'll use a default value of 0 if we don't have enough data
        let hrTrend = 0.0 // Would be calculated from historical HR data
        
        // Calculate circadian phase using hour of day (sin and cos components)
        let calendar = Calendar.current
        let hour = Double(calendar.component(.hour, from: Date()))
        let hourFraction = hour + Double(calendar.component(.minute, from: Date())) / 60.0
        let hourSin = sin(2.0 * .pi * hourFraction / 24.0)
        let hourCos = cos(2.0 * .pi * hourFraction / 24.0)
        
        print("🔍   Glucose (mmol/L): \(String(format: "%.2f", glucoseMmol))")
        print("🔍   BG Trend (mmol/L per 5min): \(String(format: "%.3f", bgTrend))")
        print("🔍   HR Trend (bpm per 5min): \(String(format: "%.1f", hrTrend))")
        print("🔍   Hour Sin: \(String(format: "%.3f", hourSin))")
        print("🔍   Hour Cos: \(String(format: "%.3f", hourCos))")
        
        // Calculate normalized heart rate for logging
        let normalizedHR = (heartRate - 60.0) / 80.0
        print("🔍   Normalized HR: \(String(format: "%.3f", normalizedHR))")
        
        for timeStep in 0..<24 {
            let baseIndex = timeStep * 8
            
            // Feature 0: heart_rate - Normalized heart rate (0-1 range to match scaler mean ≈ 0)
            let normalizedHR = (heartRate - 60.0) / 80.0  // Normalize around mean 60 bpm with range ±80
            inputTensor[baseIndex + 0] = NSNumber(value: Float(normalizedHR))
            
            // Feature 1: blood_glucose - Sensor glucose at the same timestamp (mmol/L)
            inputTensor[baseIndex + 1] = NSNumber(value: Float(glucoseMmol))
            
            // Feature 2: insulin_dose - Cumulative bolus-insulin "decay" value (effective units still active)
            inputTensor[baseIndex + 2] = NSNumber(value: Float(iob))
            
            // Feature 3: dietary_carbohydrates - Cumulative carb-impact "decay" value (grams still being absorbed)
            inputTensor[baseIndex + 3] = NSNumber(value: Float(cob))
            
            // Feature 4: bg_trend - Short-term BG slope (Δ mmol/L per 5-min tick)
            inputTensor[baseIndex + 4] = NSNumber(value: Float(bgTrend))
            
            // Feature 5: hr_trend - Short-term HR slope (Δ bpm per 5-min tick)
            inputTensor[baseIndex + 5] = NSNumber(value: Float(hrTrend))
            
            // Feature 6: hour_sin - Circadian phase – sin(2π · hour/24)
            inputTensor[baseIndex + 6] = NSNumber(value: Float(hourSin))
            
            // Feature 7: hour_cos - Circadian phase – cos(2π · hour/24)
            inputTensor[baseIndex + 7] = NSNumber(value: Float(hourCos))
        }
        
        // Log the first few tensor values (normalized values)
        print("🔍   Tensor values [0-7]: [\(String(format: "%.3f", normalizedHR)), \(String(format: "%.3f", glucoseMmol)), \(String(format: "%.3f", iob)), \(String(format: "%.3f", cob)), \(String(format: "%.3f", bgTrend)), \(String(format: "%.3f", hrTrend)), \(String(format: "%.3f", hourSin)), \(String(format: "%.3f", hourCos))]")
        
        return inputTensor
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
        // Use the model prediction directly (rawPrediction is in mmol/L, convert to mg/dL)
        var prediction = rawPrediction * 18.0  // Convert mmol/L to mg/dL
        
        // The model already accounts for most factors, but we can apply small adjustments
        // Apply time-of-day factor (circadian rhythm effect)
        prediction = prediction * timeOfDayFactor
        
        // Ensure prediction stays in a reasonable range (40-500 mg/dL)
        prediction = max(40.0, min(500.0, prediction))
        
        print("🔄 Final prediction calculation:")
        print("   Raw model output: \(String(format: "%.2f", rawPrediction)) mmol/L")
        print("   Converted to mg/dL: \(String(format: "%.1f", rawPrediction * 18.0)) mg/dL")
        print("   Time-of-day factor: \(String(format: "%.3f", timeOfDayFactor))")
        print("   Final prediction: \(String(format: "%.1f", prediction)) mg/dL")
        
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
        
        print("💉 Found \(recentInsulin.count) insulin doses in last 6 hours:")
        for (index, dose) in recentInsulin.enumerated() {
            let hoursAgo = Date().timeIntervalSince(dose.timestamp) / 3600.0
            print("  \(index + 1). \(String(format: "%.2f", dose.units))U at \(dose.timestamp) (\(String(format: "%.1f", hoursAgo))h ago)")
        }
        
        // Calculate IOB based on insulin activity curve
        // This is a simplified model - a real implementation would use more sophisticated models
        var totalIOB: Double = 0.0
        let now = Date()
        
        for dose in recentInsulin {
            let hoursAgo = now.timeIntervalSince(dose.timestamp) / 3600.0
            let remainingActivity = calculateInsulinActivityFactor(hoursAgo: hoursAgo)
            let contributingIOB = dose.units * remainingActivity
            totalIOB += contributingIOB
            print("    → \(String(format: "%.2f", dose.units))U * \(String(format: "%.2f", remainingActivity)) = \(String(format: "%.2f", contributingIOB))U IOB")
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
        
        print("🍞 Found \(recentCarbs.count) carb entries in last 6 hours:")
        for (index, intake) in recentCarbs.enumerated() {
            let hoursAgo = Date().timeIntervalSince(intake.timestamp) / 3600.0
            print("  \(index + 1). \(String(format: "%.1f", intake.grams))g at \(intake.timestamp) (\(String(format: "%.1f", hoursAgo))h ago)")
        }
        
        // Calculate COB based on carb absorption curve
        var totalCOB: Double = 0.0
        let now = Date()
        
        for intake in recentCarbs {
            let hoursAgo = now.timeIntervalSince(intake.timestamp) / 3600.0
            let remainingFactor = calculateCarbAbsorptionFactor(hoursAgo: hoursAgo)
            let contributingCOB = intake.grams * remainingFactor
            totalCOB += contributingCOB
            print("    → \(String(format: "%.1f", intake.grams))g * \(String(format: "%.2f", remainingFactor)) = \(String(format: "%.1f", contributingCOB))g COB")
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
    func createPredictionRecord(useMgdl: Bool, modelContext: ModelContext? = nil) async throws -> Prediction {
        // Get prediction from the forecasting algorithm (always returns mg/dL internally)
        let (predictedValueMgdl, timestamp) = try await predictBloodGlucose()
        
        // Log both representations for debugging
        print("🔍 Creating prediction record:")
        print("  - Predicted mg/dL: \(String(format: "%.1f", predictedValueMgdl))")
        print("  - Predicted mmol/L: \(String(format: "%.1f", predictedValueMgdl / 18.0))")
        print("  - Storing in \(useMgdl ? "mg/dL" : "mmol/L") format")
        
        // Run all 6 models and log their predictions to terminal
        do {
            // Get current glucose and recent readings to build input for all models
            let currentGlucose = try await healthKitFeatureProvider.fetchLatestGlucoseValue()
            let recentGlucoseReadings = try await healthKitFeatureProvider.fetchRecentGlucoseValues(limit: 10)
            let momentum = calculateMomentum(from: recentGlucoseReadings)
            let iob = try await getInsulinOnBoard()
            let cob = try await getCarbsOnBoard()
            let timeOfDayFactor = getTimeOfDayFactor()
            let heartRate = try await healthKitFeatureProvider.fetchLatestHeartRate(minutesBack: 30.0)
            
            // Build the input tensor (same as used for the main prediction)
            let inputTensor = try buildInputTensor(
                currentGlucose: currentGlucose,
                recentReadings: recentGlucoseReadings,
                iob: iob,
                cob: cob,
                momentum: momentum,
                timeOfDayFactor: timeOfDayFactor,
                heartRate: heartRate
            )
            
            // Run all models in series and capture their predictions
            let modelPredictions = await SeriesPredictionService.shared.runSeriesPredictions(
                window: inputTensor,
                currentBG: currentGlucose,
                usedMgdl: true,
                modelContext: modelContext
            )
            
            // Update Model 6 prediction if available
            if let model6Result = modelPredictions[6] {
                // Since we're already in a @MainActor context, we can update directly
                // Use modelOutput which is always in mmol/L (not predictionValue which depends on usedMgdl)
                self.lastModel6Prediction = model6Result.modelOutput
                // Format for display (assuming we want both units available)
                self.lastModel6PredictionText = String(format: "%.1f", model6Result.modelOutput)
                print("🟣 Captured Model 6 prediction: \(model6Result.modelOutput) mmol/L")
            }
        } catch {
            print("⚠️ Failed to run series predictions: \(error)")
        }
        
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
    
    /// Create a prediction record and also return individual model predictions
    /// - Parameter useMgdl: Whether to use mg/dL units (true) or mmol/L (false)
    /// - Returns: A tuple containing the main Prediction and a dictionary of individual model predictions
    @MainActor
    func createPredictionWithModelResults(useMgdl: Bool, modelContext: ModelContext? = nil) async throws -> (prediction: Prediction, modelPredictions: [Int: Prediction]) {
        // Get prediction from the forecasting algorithm (always returns mg/dL internally)
        let (predictedValueMgdl, timestamp) = try await predictBloodGlucose()
        
        // Log both representations for debugging
        print("🔍 Creating prediction record:")
        print("  - Predicted mg/dL: \(String(format: "%.1f", predictedValueMgdl))")
        print("  - Predicted mmol/L: \(String(format: "%.1f", predictedValueMgdl / 18.0))")
        print("  - Storing in \(useMgdl ? "mg/dL" : "mmol/L") format")
        
        var modelPredictions: [Int: Prediction] = [:]
        
        // Run all 6 models and capture their predictions
        do {
            // Get current glucose and recent readings to build input for all models
            let currentGlucose = try await healthKitFeatureProvider.fetchLatestGlucoseValue()
            let recentGlucoseReadings = try await healthKitFeatureProvider.fetchRecentGlucoseValues(limit: 10)
            let momentum = calculateMomentum(from: recentGlucoseReadings)
            let iob = try await getInsulinOnBoard()
            let cob = try await getCarbsOnBoard()
            let timeOfDayFactor = getTimeOfDayFactor()
            let heartRate = try await healthKitFeatureProvider.fetchLatestHeartRate(minutesBack: 30.0)
            
            // Build the input tensor (same as used for the main prediction)
            let inputTensor = try buildInputTensor(
                currentGlucose: currentGlucose,
                recentReadings: recentGlucoseReadings,
                iob: iob,
                cob: cob,
                momentum: momentum,
                timeOfDayFactor: timeOfDayFactor,
                heartRate: heartRate
            )
            
            // Run all models in series and capture their predictions
            modelPredictions = await SeriesPredictionService.shared.runSeriesPredictions(
                window: inputTensor,
                currentBG: currentGlucose,
                usedMgdl: true,
                modelContext: modelContext
            )
        } catch {
            print("⚠️ Failed to run series predictions: \(error)")
        }
        
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
        
        let prediction = Prediction(
            timestamp: timestamp,
            predictionValue: finalPredictionValue,
            usedMgdlUnits: useMgdl,
            currentBG: currentBGInMmol,
            stabilityStatus: stabilityStatus
        )
        
        return (prediction: prediction, modelPredictions: modelPredictions)
    }
}
