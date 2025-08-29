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
import Accelerate

/// A service that handles blood glucose predictions using a pre-trained BGPersonal_BiLSTM model
/// Model architecture: Bidirectional LSTM + Dense layers
@MainActor
class BGPredictionService: ObservableObject {
    private let healthKitFeatureProvider = HealthKitFeatureProvider()
    
    // WaveNetPro model predictors (lazy-loaded to avoid initialization errors)
    private lazy var wavenetPro1: DeltaBGWaveNet? = {
        do {
            print("🔄 Initializing WaveNetPro1...")
            let predictor = try DeltaBGWaveNet(resource: "wavenetpro1")
            print("✅ WaveNetPro1 loaded successfully")
            return predictor
        } catch {
            print("❌ Failed to load WaveNetPro1: \(error.localizedDescription)")
            print("   Details: \(error)")
            return nil
        }
    }()
    
    private lazy var wavenetPro2: DeltaBGWaveNet? = {
        do {
            print("🔄 Initializing WaveNetPro2...")
            let predictor = try DeltaBGWaveNet(resource: "wavenetpro2")
            print("✅ WaveNetPro2 loaded successfully")
            return predictor
        } catch {
            print("❌ Failed to load WaveNetPro2: \(error.localizedDescription)")
            print("   Details: \(error)")
            return nil
        }
    }()
    
    private lazy var wavenetPro3: DeltaBGWaveNet? = {
        do {
            print("🔄 Initializing WaveNetPro3...")
            let predictor = try DeltaBGWaveNet(resource: "wavenetpro3")
            print("✅ WaveNetPro3 loaded successfully")
            return predictor
        } catch {
            print("❌ Failed to load WaveNetPro3: \(error.localizedDescription)")
            print("   Details: \(error)")
            return nil
        }
    }()
    
    /// Published properties that can be observed by views
    @Published var lastPrediction: Double = 0
    @Published var lastPredictionTimestamp: Date?
    @Published var isProcessing: Bool = false
    @Published var lastError: String?
    @Published var lastModel5Prediction: Double = 0
    @Published var lastModel5PredictionText: String = "—"
    
    // WaveNetPro predictions (in mmol/L)
    @Published var wavenetPro1Prediction: Double = 0
    @Published var wavenetPro2Prediction: Double = 0
    @Published var wavenetPro3Prediction: Double = 0
    
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
    
    /// Predict blood glucose using SwiftData cache when HealthKit is unavailable
    /// - Parameter modelContext: SwiftData model context
    /// - Returns: A tuple containing the predicted blood glucose value and timestamp
    @MainActor
    func predictWithSwiftDataCache(modelContext: ModelContext) async throws -> (value: Double, timestamp: Date) {
        isProcessing = true
        defer { isProcessing = false }
        
        do {
            self.lastError = nil
            
            print("\n🗄️ === SWIFTDATA CACHE PREDICTION ===\n")
            print("⚠️ HealthKit unavailable, using cached Nightscout data")
            
            // Build input window from SwiftData cache
            let inputTensor = try await healthKitFeatureProvider.buildWindowFromSwiftDataCache(modelContext: modelContext)
            
            // Get latest glucose from cache for current BG
            let glucoseData = try await healthKitFeatureProvider.fetchGlucoseFromSwiftDataCache(modelContext: modelContext, limit: 1)
            guard let latestReading = glucoseData.first else {
                throw NSError(domain: "SwiftData", code: 3, userInfo: [NSLocalizedDescriptionKey: "No glucose data in cache"])
            }
            
            let currentGlucose = latestReading.value
            print("🩸 Latest cached glucose: \(String(format: "%.1f", currentGlucose)) mg/dL at \(latestReading.date)")
            
            // Calculate prediction count
            let predictionCount = calculateNextPredictionCount(modelContext: modelContext)
            
            // Use WaveNet2Service for prediction
            let predictionResult = try WaveNet2Service.shared.predict(
                window: inputTensor,
                currentBG: currentGlucose,
                usedMgdl: true,
                predictionCount: predictionCount
            )
            
            print("\n🎯 === CACHE-BASED PREDICTION RESULT ===")
            print("📊 Predicted: \(String(format: "%.1f", predictionResult.predictionValue)) mg/dL")
            print("⏰ For time: \(predictionResult.timestamp)")
            print("🗄️ === CACHE PREDICTION COMPLETE ===\n")
            
            // Update last prediction
            self.lastPrediction = predictionResult.predictionValue
            self.lastPredictionTimestamp = predictionResult.timestamp
            
            return (value: predictionResult.predictionValue, timestamp: predictionResult.timestamp)
            
        } catch {
            self.lastError = error.localizedDescription
            print("❌ Cache prediction error: \(error)")
            throw error
        }
    }
    
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
            
            // Use WaveNet2Service for proper model prediction with scaling
            let predictionResult = try WaveNet2Service.shared.predict(
                window: inputTensor,
                currentBG: currentGlucose,
                usedMgdl: true
            )
            
            // Get the raw prediction value (this is now a CHANGE in blood glucose, not absolute value)
            let predictedChange = predictionResult.modelOutput
            
            // Calculate the final prediction: current BG + predicted change
            let scaledPrediction = calculateFinalPrediction(
                predictedChange: predictedChange,
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
    
    /// Build the input tensor for the prediction model with 24 historical time steps
    /// - Parameters:
    ///   - currentGlucose: Current blood glucose value in mg/dL
    ///   - recentReadings: Array of recent glucose readings (should have 24+ values for 2 hours of 5-min intervals)
    ///   - iob: Insulin on Board in units
    ///   - cob: Carbs on Board in grams
    ///   - momentum: Glucose momentum/trend
    ///   - timeOfDayFactor: Time of day factor for circadian rhythm
    ///   - heartRate: Current heart rate in beats per minute
    /// - Returns: MLMultiArray with shape [1, 24, 8] representing 24 time steps of 8 features each
    private func buildInputTensor(
        currentGlucose: Double,
        recentReadings: [Double],
        iob: Double,
        cob: Double,
        momentum: Double,
        timeOfDayFactor: Double,
        heartRate: Double
    ) throws -> MLMultiArray {
        print("🔍 === BUILDING INPUT TENSOR ===")
        print("🔍 Current Glucose: \(currentGlucose) mg/dL")
        print("🔍 Recent Readings Count: \(recentReadings.count)")
        print("🔍 IOB: \(iob) U, COB: \(cob) g")
        
        // Create tensor with explicit shape [1, 24, 8]
        guard let inputTensor = try? MLMultiArray(shape: [1, 24, 8], dataType: .float32) else {
            throw NSError(domain: "TensorCreationError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create MLMultiArray with shape [1, 24, 8]"])
        }
        
        // Verify tensor shape immediately after creation
        let createdShape = inputTensor.shape.map { $0.intValue }
        print("🔍 Created tensor shape: \(createdShape)")
        print("🔍 Tensor element count: \(inputTensor.count)")
        
        if createdShape != [1, 24, 8] {
            throw NSError(domain: "TensorShapeError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Tensor shape mismatch: got \(createdShape), expected [1, 24, 8]"])
        }
        
        // Create historical time series data for 24 time steps (2 hours of 5-minute intervals)
        // Each time step has 8 features as expected by the WaveNet model
        
        // Prepare historical data arrays (pad with current values if insufficient history)
        var glucoseHistory = Array(recentReadings.prefix(24))
        while glucoseHistory.count < 24 {
            glucoseHistory.insert(currentGlucose, at: 0) // Pad with current glucose if insufficient history
        }
        
        // For now, use current heart rate for all time steps (would need historical HR data for proper implementation)
        let heartRateHistory = Array(repeating: heartRate, count: 24)
        
        print("🔍 Glucose History (last 24): \(glucoseHistory.map { String(format: "%.0f", $0) }.joined(separator: ", "))")
        
        // Calculate circadian components
        let calendar = Calendar.current
        let hour = Double(calendar.component(.hour, from: Date()))
        let hourFraction = hour + Double(calendar.component(.minute, from: Date())) / 60.0
        let hourSin = sin(2.0 * .pi * hourFraction / 24.0)
        let hourCos = cos(2.0 * .pi * hourFraction / 24.0)
        
        // Fill tensor with historical time series data
        // Feature order matches training: blood_glucose, insulin_dose, dietary_carbohydrates, heart_rate, bg_trend, hr_trend, hour_sin, hour_cos
        for timeStep in 0..<24 {
            let baseIndex = timeStep * 8
            
            // Get historical values for this time step
            let stepGlucose = glucoseHistory[timeStep]
            let stepHeartRate = heartRateHistory[timeStep]
            
            // Convert glucose to mmol/L
            let stepGlucoseMmol = stepGlucose / 18.0
            
            // Calculate trends (simplified - would use actual historical differences)
            let bgTrend = timeStep > 0 ? (glucoseHistory[timeStep] - glucoseHistory[timeStep-1]) / 18.0 / 5.0 : 0.0
            let hrTrend = 0.0 // Would calculate from HR history
            
            // Feature 0: blood_glucose (mmol/L)
            inputTensor[baseIndex + 0] = NSNumber(value: Float(stepGlucoseMmol))
            
            // Feature 1: insulin_dose (IOB - decays over time, simplified)
            let timeDecayFactor = max(0.0, 1.0 - Double(timeStep) * 0.1) // Simple decay
            inputTensor[baseIndex + 1] = NSNumber(value: Float(iob * timeDecayFactor))
            
            // Feature 2: dietary_carbohydrates (COB - decays over time)
            inputTensor[baseIndex + 2] = NSNumber(value: Float(cob * timeDecayFactor))
            
            // Feature 3: heart_rate (normalized around 70 bpm)
            let normalizedHR = (stepHeartRate - 70.0) / 30.0
            inputTensor[baseIndex + 3] = NSNumber(value: Float(normalizedHR))
            
            // Feature 4: bg_trend (mmol/L per 5min)
            inputTensor[baseIndex + 4] = NSNumber(value: Float(bgTrend))
            
            // Feature 5: hr_trend (bpm per 5min)
            inputTensor[baseIndex + 5] = NSNumber(value: Float(hrTrend))
            
            // Feature 6: hour_sin (circadian)
            inputTensor[baseIndex + 6] = NSNumber(value: Float(hourSin))
            
            // Feature 7: hour_cos (circadian)
            inputTensor[baseIndex + 7] = NSNumber(value: Float(hourCos))
        }
        
        // Final verification of tensor shape and content
        let finalShape = inputTensor.shape.map { $0.intValue }
        print("🔍 Final tensor shape: \(finalShape)")
        print("🔍 Final tensor element count: \(inputTensor.count)")
        
        // Log first time step values for verification
        let firstStepValues = (0..<8).map { i in
            String(format: "%.3f", inputTensor[i].floatValue)
        }.joined(separator: ", ")
        print("🔍 First time step [0-7]: [\(firstStepValues)]")
        
        // Ensure shape is still correct before returning
        if finalShape != [1, 24, 8] {
            throw NSError(domain: "TensorShapeError", code: 2, userInfo: [NSLocalizedDescriptionKey: "Tensor shape corrupted: got \(finalShape), expected [1, 24, 8]"])
        }
        
        print("🔍 ✅ Tensor creation completed successfully")
        return inputTensor
    }
    

    /// Calculate the final prediction based on all factors
    private func calculateFinalPrediction(
        predictedChange: Double,
        currentGlucose: Double,
        iob: Double,
        cob: Double,
        momentum: Double,
        timeOfDayFactor: Double
    ) -> Double {
        // Convert predicted change from mmol/L to mg/dL
        let changeInMgdl = predictedChange * 18.0
        
        // Calculate final prediction: current BG + predicted change
        var prediction = currentGlucose + changeInMgdl
        
        // Apply time-of-day adjustment (circadian rhythm effect)
        prediction *= timeOfDayFactor
        
        // Ensure prediction is within reasonable bounds
        prediction = max(40.0, min(400.0, prediction))
        
        // Log the calculation steps
        print("🔮 Prediction Calculation:")
        print("   Current BG: \(String(format: "%.1f", currentGlucose)) mg/dL")
        print("   Predicted change: \(String(format: "%.2f", predictedChange)) mmol/L = \(String(format: "%.1f", changeInMgdl)) mg/dL")
        print("   Before time adjustment: \(String(format: "%.1f", currentGlucose + changeInMgdl)) mg/dL")
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
        
        // Fetch recent insulin doses from HealthKit (last 4 hours for IOB calculation)
        let recentInsulin = try await healthKitFeatureProvider.fetchRecentInsulinDoses(hoursBack: 4.0)
        
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
        
        // Apply reasonable bounds to IOB (0-10 units max)
        totalIOB = max(0.0, min(10.0, totalIOB))
        
        // Cache the result
        cachedIOB = totalIOB
        cachedIOBTimestamp = now
        
        print("💉 Total IOB calculated: \(String(format: "%.2f", totalIOB)) units")
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
        
        // Fetch recent carb intake from HealthKit (last 3 hours for COB calculation)
        let recentCarbs = try await healthKitFeatureProvider.fetchRecentCarbIntake(hoursBack: 3.0)
        
        print("🍞 Found \(recentCarbs.count) carb entries in last 3 hours:")
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
        
        // Apply reasonable bounds to COB (0-100 grams max)
        totalCOB = max(0.0, min(100.0, totalCOB))
        
        // Cache the result
        cachedCOB = totalCOB
        cachedCOBTimestamp = now
        
        print("🍞 Total COB calculated: \(String(format: "%.1f", totalCOB)) grams")
        return totalCOB
    }
    
    /// Calculate carb absorption factor based on hours since intake
    private func calculateCarbAbsorptionFactor(hoursAgo: Double) -> Double {
        // Simplified linear carb absorption curve
        // Assumes linear absorption over 3 hours
        if hoursAgo < 0 {
            return 1.0 // Future carbs are fully unabsorbed
        } else if hoursAgo < 3.0 {
            return 1.0 - (hoursAgo / 3.0) // Linear absorption
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
            
            // Update Model 5 prediction if available
            if let model5Result = modelPredictions[5] {
                // Since we're already in a @MainActor context, we can update directly
                // Use modelOutput which is always in mmol/L (not predictionValue which depends on usedMgdl)
                self.lastModel5Prediction = model5Result.modelOutput
                // Format for display (assuming we want both units available)
                self.lastModel5PredictionText = String(format: "%.1f", model5Result.modelOutput)
                print("🟣 Captured Model 5 prediction: \(model5Result.modelOutput) mmol/L")
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
        
        // Track workout data if modelContext is available
        if let modelContext = modelContext {
            let workoutTrackingService = WorkoutTrackingService()
            let _ = await workoutTrackingService.createWorkoutTimeRecord(
                predictionTimestamp: timestamp,
                modelContext: modelContext
            )
        }
        
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
    
    /// Migrate existing predictions to have sequential prediction counts
    /// This fixes the issue where existing predictions show "—" instead of numbers
    /// - Parameter modelContext: SwiftData model context to update existing predictions
    func migratePredictionCounts(modelContext: ModelContext) {
        do {
            // Fetch all predictions sorted by timestamp (oldest first)
            let descriptor = FetchDescriptor<Prediction>(
                sortBy: [SortDescriptor(\Prediction.timestamp, order: .forward)]
            )
            let allPredictions = try modelContext.fetch(descriptor)
            
            print("📊 Starting prediction count migration for \(allPredictions.count) predictions")
            
            // Update predictions with sequential counts
            for (index, prediction) in allPredictions.enumerated() {
                let newCount = index + 1
                prediction.predictionCount = newCount
                print("📊 Updated prediction \(prediction.id) with count \(newCount)")
            }
            
            // Save changes
            try modelContext.save()
            print("✅ Successfully migrated \(allPredictions.count) predictions with sequential counts")
            
        } catch {
            print("⚠️ Error migrating prediction counts: \(error)")
        }
    }
    
    /// Calculate the next prediction count based on existing predictions in SwiftData
    /// - Parameter modelContext: SwiftData model context to query existing predictions
    /// - Returns: The next sequential prediction count (1, 2, 3, ...)
    func calculateNextPredictionCount(modelContext: ModelContext?) -> Int {
        guard let modelContext = modelContext else {
            print("⚠️ No model context provided, using count 1")
            return 1
        }
        
        do {
            // Query for the highest prediction count in existing predictions
            let descriptor = FetchDescriptor<Prediction>(
                sortBy: [SortDescriptor(\Prediction.predictionCount, order: .reverse)]
            )
            let predictions = try modelContext.fetch(descriptor)
            
            if let highestCount = predictions.first?.predictionCount {
                let nextCount = highestCount + 1
                print("📊 Next prediction count: \(nextCount) (previous highest: \(highestCount))")
                return nextCount
            } else {
                print("📊 No existing predictions found, starting with count 1")
                return 1
            }
        } catch {
            print("⚠️ Error fetching prediction count: \(error), defaulting to count 1")
            return 1
        }
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
        
        // Calculate the next prediction count
        let predictionCount = calculateNextPredictionCount(modelContext: modelContext)
        
        // Create the prediction object with all necessary fields
        // If using mmol/L, convert the prediction from mg/dL to mmol/L
        let finalPredictionValue = useMgdl ? predictedValueMgdl : (predictedValueMgdl / 18.0)
        
        let prediction = Prediction(
            timestamp: timestamp,
            predictionValue: finalPredictionValue,
            usedMgdlUnits: useMgdl,
            currentBG: currentBGInMmol,
            stabilityStatus: stabilityStatus,
            predictionCount: predictionCount
        )
        
        return (prediction: prediction, modelPredictions: modelPredictions)
    }
    
    /// Run WaveNetPro predictions using the three pro models
    /// - Returns: Dictionary with pro model predictions (1, 2, 3 for the three pro models)
    @MainActor
    func predictWithWaveNetPro() async throws -> [Int: Double] {
        isProcessing = true
        defer { isProcessing = false }
        
        do {
            self.lastError = nil
            
            print("\n🔥 === WAVENETPRO PREDICTION ===")
            
            // Get current glucose and build comprehensive input data
            let currentGlucose = try await healthKitFeatureProvider.fetchLatestGlucoseValue()
            let recentGlucoseReadings = try await healthKitFeatureProvider.fetchRecentGlucoseValues(limit: 24)
            let heartRate = try await healthKitFeatureProvider.fetchLatestHeartRate(minutesBack: 30.0)
            let iob = try await getInsulinOnBoard()
            let cob = try await getCarbsOnBoard()
            
            print("🩸 Current BG: \(String(format: "%.1f", currentGlucose)) mg/dL")
            print("❤️ Heart Rate: \(String(format: "%.0f", heartRate)) bpm")
            print("💉 IOB: \(String(format: "%.2f", iob)) units")
            print("🍞 COB: \(String(format: "%.1f", cob)) grams")
            
            // Build the 12-feature input for DeltaBGPredictor
            let features = try buildWaveNetProFeatures(
                currentGlucose: currentGlucose,
                recentReadings: recentGlucoseReadings,
                heartRate: heartRate,
                iob: iob,
                cob: cob
            )
            
            var results: [Int: Double] = [:]
            
            // Run WaveNetPro1
            if let predictor1 = wavenetPro1 {
                do {
                    print("🔥 Running WaveNetPro1 prediction...")
                    let delta1 = try predictor1.predictDelta(features: features)
                    let currentBGMmol = currentGlucose / 18.0
                    let prediction1 = currentBGMmol + Double(delta1)
                    results[1] = prediction1
                    wavenetPro1Prediction = prediction1
                    print("🔥 WaveNetPro1 SUCCESS: \(String(format: "%.2f", prediction1)) mmol/L (\(String(format: "%.0f", prediction1 * 18.0)) mg/dL)")
                } catch {
                    print("❌ WaveNetPro1 prediction error: \(error)")
                    print("   Error details: \(error.localizedDescription)")
                }
            } else {
                print("❌ WaveNetPro1 predictor is nil - failed to initialize")
            }
            
            // Run WaveNetPro2
            if let predictor2 = wavenetPro2 {
                do {
                    print("🔥 Running WaveNetPro2 prediction...")
                    let delta2 = try predictor2.predictDelta(features: features)
                    let currentBGMmol = currentGlucose / 18.0
                    let prediction2 = currentBGMmol + Double(delta2)
                    results[2] = prediction2
                    wavenetPro2Prediction = prediction2
                    print("🔥 WaveNetPro2 SUCCESS: \(String(format: "%.2f", prediction2)) mmol/L (\(String(format: "%.0f", prediction2 * 18.0)) mg/dL)")
                } catch {
                    print("❌ WaveNetPro2 prediction error: \(error)")
                    print("   Error details: \(error.localizedDescription)")
                }
            } else {
                print("❌ WaveNetPro2 predictor is nil - failed to initialize")
            }
            
            // Run WaveNetPro3
            if let predictor3 = wavenetPro3 {
                do {
                    print("🔥 Running WaveNetPro3 prediction...")
                    let delta3 = try predictor3.predictDelta(features: features)
                    let currentBGMmol = currentGlucose / 18.0
                    let prediction3 = currentBGMmol + Double(delta3)
                    results[3] = prediction3
                    wavenetPro3Prediction = prediction3
                    print("🔥 WaveNetPro3 SUCCESS: \(String(format: "%.2f", prediction3)) mmol/L (\(String(format: "%.0f", prediction3 * 18.0)) mg/dL)")
                } catch {
                    print("❌ WaveNetPro3 prediction error: \(error)")
                    print("   Error details: \(error.localizedDescription)")
                }
            } else {
                print("❌ WaveNetPro3 predictor is nil - failed to initialize")
            }
            
            print("🔥 === WAVENETPRO COMPLETE ===\n")
            
            return results
            
        } catch {
            self.lastError = error.localizedDescription
            print("❌ WaveNetPro prediction error: \(error)")
            throw error
        }
    }
    
    /// Build 12-feature input for WaveNetPro models in the correct format
    /// Expected features: [current_bg, bg_trend, iob, cob, heart_rate, hour_sin, hour_cos, bg_1h_ago, bg_2h_ago, bg_3h_ago, bg_4h_ago, bg_5h_ago]
    private func buildWaveNetProFeatures(
        currentGlucose: Double,
        recentReadings: [Double],
        heartRate: Double,
        iob: Double,
        cob: Double
    ) throws -> [Float] {
        print("🔍 === BUILDING WAVENETPRO FEATURES ===")
        
        // Convert current glucose to mmol/L and normalize
        let currentBGMmol = Float(currentGlucose / 18.0)
        
        // Calculate BG trend from recent readings (mmol/L per 5 min)
        let bgTrend: Float
        if recentReadings.count >= 2 {
            let current = recentReadings[0] / 18.0
            let previous = recentReadings[1] / 18.0
            bgTrend = Float((current - previous) / 5.0)
        } else {
            bgTrend = 0.0
        }
        
        // Normalize heart rate (subtract baseline and scale)
        let normalizedHeartRate = Float((heartRate - 70.0) / 30.0)
        
        // Calculate circadian components
        let calendar = Calendar.current
        let hour = Double(calendar.component(.hour, from: Date()))
        let hourFraction = hour + Double(calendar.component(.minute, from: Date())) / 60.0
        let hourSin = Float(sin(2.0 * .pi * hourFraction / 24.0))
        let hourCos = Float(cos(2.0 * .pi * hourFraction / 24.0))
        
        // Get historical BG values (1-5 hours ago, in mmol/L)
        var historicalBG: [Float] = []
        for i in 1...5 {
            let index = i * 12 // 12 readings per hour (5-min intervals)
            if index < recentReadings.count {
                historicalBG.append(Float(recentReadings[index] / 18.0))
            } else {
                historicalBG.append(currentBGMmol) // Pad with current if insufficient history
            }
        }
        
        // Build the 12-feature vector with proper scaling
        let features: [Float] = [
            currentBGMmol,              // [0] current_bg (mmol/L) - already normalized
            bgTrend,                    // [1] bg_trend (mmol/L per 5 min) - already small
            Float(iob / 10.0),          // [2] iob (units) - scale down from 0-10 to 0-1
            Float(cob / 100.0),         // [3] cob (grams) - scale down from 0-100 to 0-1
            normalizedHeartRate,        // [4] heart_rate (normalized) - already normalized
            hourSin,                    // [5] hour_sin (circadian) - already -1 to 1
            hourCos,                    // [6] hour_cos (circadian) - already -1 to 1
            historicalBG[0],            // [7] bg_1h_ago (mmol/L) - already normalized
            historicalBG[1],            // [8] bg_2h_ago (mmol/L) - already normalized
            historicalBG[2],            // [9] bg_3h_ago (mmol/L) - already normalized
            historicalBG[3],            // [10] bg_4h_ago (mmol/L) - already normalized
            historicalBG[4]             // [11] bg_5h_ago (mmol/L) - already normalized
        ]
        
        print("🔍 Features shape: 12 features")
        print("🔍 Current BG: \(String(format: "%.2f", features[0])) mmol/L")
        print("🔍 BG Trend: \(String(format: "%.3f", features[1])) mmol/L per 5min")
        print("🔍 IOB: \(String(format: "%.2f", features[2])) units")
        print("🔍 COB: \(String(format: "%.1f", features[3])) grams")
        print("🔍 Heart Rate: \(String(format: "%.2f", features[4])) (normalized)")
        print("🔍 === FEATURES BUILD COMPLETE ===")
        
        return features
    }
}

