//
//  RandomForestIntegration.swift
//  NightScouttoHealthKit
//
//  Created for PatrickPallagi on 2025-09-23
//

import Foundation
import CoreML
import HealthKit
import SwiftData
import Combine

/// Service for integrating the Random Forest GlucosePredictor model with HealthKit data
/// This provides a clean interface similar to the WaveNet integrations
@MainActor
class RandomForestIntegrationService: ObservableObject {
    private let healthKitFeatureProvider = HealthKitFeatureProvider()
    private let updatedGlucosePredictorService = UpdatedGlucosePredictorService()
    
    /// Published properties for UI observation
    @Published var lastPrediction: Double = 0
    @Published var lastPredictionTimestamp: Date?
    @Published var isProcessing: Bool = false
    @Published var lastError: String?
    
    /// Singleton instance
    static let shared = RandomForestIntegrationService()
    
    private init() {
        print("🌲 RandomForestIntegrationService.init() called")
    }
    
    /// Make a Random Forest prediction using comprehensive HealthKit data
    /// - Returns: Prediction value in mg/dL and timestamp
    func predictWithRandomForest() async throws -> (value: Double, timestamp: Date) {
        isProcessing = true
        defer { isProcessing = false }
        
        do {
            self.lastError = nil
            
            print("\n🌲 === RANDOM FOREST PREDICTION ===")
            
            // Gather comprehensive HealthKit data
            let currentGlucose = try await healthKitFeatureProvider.fetchLatestGlucoseValue()
            let glucoseHistory = try await healthKitFeatureProvider.fetchRecentGlucoseValues(limit: 24) // 24 readings for 2 hours
            let carbHistory = try await fetchCarbHistory()
            let insulinHistory = try await fetchInsulinHistory()
            let heartRateHistory = try await fetchHeartRateHistory()
            
            print("🩸 Current glucose: \(String(format: "%.1f", currentGlucose)) mg/dL")
            print("📊 Glucose history: \(glucoseHistory.count) readings")
            print("🍞 Carb history: \(carbHistory.count) entries")
            print("💉 Insulin history: \(insulinHistory.count) entries")
            print("❤️ Heart rate history: \(heartRateHistory.count) readings")
            
            // Use the UpdatedGlucosePredictorService to make prediction
            let timestamp = Date()
            let predictionResult = updatedGlucosePredictorService.predictAbsoluteGlucose(
                glucoseHistory: glucoseHistory,
                carbsHistory: carbHistory,
                insulinHistory: insulinHistory,
                heartRateHistory: heartRateHistory,
                currentTime: timestamp
            )
            
            guard let result = predictionResult, let predictedValue = result.absolutePrediction else {
                throw NSError(domain: "RandomForestError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Random Forest prediction failed"])
            }
            
            // Update published properties
            self.lastPrediction = predictedValue
            self.lastPredictionTimestamp = timestamp
            
            print("🌲 Random Forest prediction: \(String(format: "%.1f", predictedValue)) mg/dL")
            print("🌲 === RANDOM FOREST COMPLETE ===\n")
            
            return (value: predictedValue, timestamp: timestamp)
            
        } catch {
            self.lastError = error.localizedDescription
            print("❌ Random Forest prediction error: \(error)")
            throw error
        }
    }
    
    /// Create a Prediction record using Random Forest model
    /// - Parameter useMgdl: Whether to store in mg/dL (true) or mmol/L (false)
    /// - Parameter modelContext: SwiftData context for prediction count
    /// - Returns: Prediction object ready for SwiftData storage
    func createRandomForestPrediction(useMgdl: Bool = true, modelContext: ModelContext? = nil) async throws -> Prediction {
        let (predictedValueMgdl, timestamp) = try await predictWithRandomForest()
        
        // Calculate prediction count
        let predictionCount = calculateNextPredictionCount(modelContext: modelContext)
        
        // Get current BG for reference
        let currentBGInMgdl = try await healthKitFeatureProvider.fetchLatestGlucoseValue()
        let currentBGInMmol = currentBGInMgdl / 18.0
        
        // Calculate stability status
        let recentReadings = try await healthKitFeatureProvider.fetchRecentGlucoseValues(limit: 3)
        let momentum = calculateMomentum(from: recentReadings)
        let stabilityStatus = determineStabilityStatus(momentum: momentum)
        
        // Convert prediction if needed
        let finalPredictionValue = useMgdl ? predictedValueMgdl : (predictedValueMgdl / 18.0)
        
        print("🔍 Creating Random Forest prediction record:")
        print("  - Predicted mg/dL: \(String(format: "%.1f", predictedValueMgdl))")
        print("  - Predicted mmol/L: \(String(format: "%.1f", predictedValueMgdl / 18.0))")
        print("  - Storing in \(useMgdl ? "mg/dL" : "mmol/L") format")
        print("  - Prediction count: \(predictionCount)")
        print("  - Stability: \(stabilityStatus)")
        
        return Prediction(
            timestamp: timestamp,
            predictionValue: finalPredictionValue,
            usedMgdlUnits: useMgdl,
            currentBG: currentBGInMmol,
            stabilityStatus: stabilityStatus,
            predictionCount: predictionCount
        )
    }
    
    /// Predict using Random Forest with SwiftData cache fallback
    /// - Parameter modelContext: SwiftData model context
    /// - Returns: Prediction value and timestamp
    func predictWithRandomForestCache(modelContext: ModelContext) async throws -> (value: Double, timestamp: Date) {
        isProcessing = true
        defer { isProcessing = false }
        
        do {
            self.lastError = nil
            
            print("\n🌲🗄️ === RANDOM FOREST CACHE PREDICTION ===")
            print("⚠️ Using cached data for Random Forest prediction")
            
            // Get cached glucose data
            let glucoseData = try await healthKitFeatureProvider.fetchGlucoseFromSwiftDataCache(modelContext: modelContext, limit: 24)
            let glucoseHistory = glucoseData.map { $0.value }
            
            // Get cached carb and insulin data
            let carbHistory = try await fetchCachedCarbHistory(modelContext: modelContext)
            let insulinHistory = try await fetchCachedInsulinHistory(modelContext: modelContext)
            
            // Use default heart rate if no cached data available
            let heartRateHistory = Array(repeating: 70.0, count: 6) // Default resting heart rate
            
            guard !glucoseHistory.isEmpty else {
                throw NSError(domain: "CacheError", code: 1, userInfo: [NSLocalizedDescriptionKey: "No cached glucose data available"])
            }
            
            print("📊 Using \(glucoseHistory.count) cached glucose readings")
            print("🍞 Using \(carbHistory.count) cached carb entries")
            print("💉 Using \(insulinHistory.count) cached insulin entries")
            
            let timestamp = Date()
            let predictionResult = updatedGlucosePredictorService.predictAbsoluteGlucose(
                glucoseHistory: glucoseHistory,
                carbsHistory: carbHistory,
                insulinHistory: insulinHistory,
                heartRateHistory: heartRateHistory,
                currentTime: timestamp
            )
            
            guard let result = predictionResult, let predictedValue = result.absolutePrediction else {
                throw NSError(domain: "RandomForestError", code: 2, userInfo: [NSLocalizedDescriptionKey: "Random Forest cache prediction failed"])
            }
            
            self.lastPrediction = predictedValue
            self.lastPredictionTimestamp = timestamp
            
            print("🌲 Random Forest cache prediction: \(String(format: "%.1f", predictedValue)) mg/dL")
            print("🌲🗄️ === RANDOM FOREST CACHE COMPLETE ===\n")
            
            return (value: predictedValue, timestamp: timestamp)
            
        } catch {
            self.lastError = error.localizedDescription
            print("❌ Random Forest cache prediction error: \(error)")
            throw error
        }
    }
    
    // MARK: - Private Helper Methods
    
    /// Fetch recent carb history from HealthKit
    private func fetchCarbHistory() async throws -> [Double] {
        let carbIntakes = try await healthKitFeatureProvider.fetchRecentCarbIntake(hoursBack: 6.0)
        return carbIntakes.map { $0.grams }
    }
    
    /// Fetch recent insulin history from HealthKit
    private func fetchInsulinHistory() async throws -> [Double] {
        let insulinDoses = try await healthKitFeatureProvider.fetchRecentInsulinDoses(hoursBack: 6.0)
        return insulinDoses.map { $0.units }
    }
    
    /// Fetch recent heart rate history from HealthKit
    private func fetchHeartRateHistory() async throws -> [Double] {
        // Get recent heart rate readings (last 30 minutes)
        let heartRate = try await healthKitFeatureProvider.fetchLatestHeartRate(minutesBack: 30.0)
        // For now, return array with repeated current heart rate
        // In a full implementation, you'd fetch historical heart rate data
        return Array(repeating: heartRate, count: 6)
    }
    
    /// Fetch cached carb history from SwiftData
    private func fetchCachedCarbHistory(modelContext: ModelContext) async throws -> [Double] {
        // Implement SwiftData carb cache fetching
        // For now, return empty array - would need to implement NightScoutCarbCache fetching
        return []
    }
    
    /// Fetch cached insulin history from SwiftData
    private func fetchCachedInsulinHistory(modelContext: ModelContext) async throws -> [Double] {
        // Implement SwiftData insulin cache fetching
        // For now, return empty array - would need to implement NightScoutInsulinCache fetching
        return []
    }
    
    /// Calculate momentum from recent glucose readings
    private func calculateMomentum(from readings: [Double]) -> Double {
        guard readings.count >= 2 else { return 0.0 }
        
        let latestReading = readings[0]
        let previousReading = readings[1]
        
        // Calculate mg/dL per minute (assuming 5-minute intervals)
        let rateOfChange = (latestReading - previousReading) / 5.0
        
        return rateOfChange
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
    
    /// Calculate next prediction count based on existing predictions
    private func calculateNextPredictionCount(modelContext: ModelContext?) -> Int {
        guard let modelContext = modelContext else {
            return 1
        }
        
        do {
            let descriptor = FetchDescriptor<Prediction>(
                sortBy: [SortDescriptor(\Prediction.predictionCount, order: .reverse)]
            )
            let predictions = try modelContext.fetch(descriptor)
            
            if let latestCount = predictions.first?.predictionCount {
                return latestCount + 1
            } else {
                return 1
            }
        } catch {
            print("⚠️ Error fetching prediction count: \(error), defaulting to count 1")
            return 1
        }
    }
}

// MARK: - Extension for BGPredictionService Integration

extension BGPredictionService {
    
    /// Add Random Forest prediction to the existing prediction suite
    /// - Returns: Random Forest prediction result
    func predictWithRandomForest() async throws -> (value: Double, timestamp: Date) {
        return try await RandomForestIntegrationService.shared.predictWithRandomForest()
    }
    
    /// Create a comprehensive prediction including Random Forest
    /// - Parameter useMgdl: Whether to use mg/dL units
    /// - Parameter modelContext: SwiftData context
    /// - Returns: Dictionary with all predictions including Random Forest
    func createComprehensivePredictionWithRandomForest(useMgdl: Bool = true, modelContext: ModelContext? = nil) async throws -> [String: Prediction] {
        var predictions: [String: Prediction] = [:]
        
        // Get standard WaveNet prediction
        let standardPrediction = try await createPredictionRecord(useMgdl: useMgdl, modelContext: modelContext)
        predictions["WaveNet"] = standardPrediction
        
        // Get Random Forest prediction
        let randomForestPrediction = try await RandomForestIntegrationService.shared.createRandomForestPrediction(useMgdl: useMgdl, modelContext: modelContext)
        predictions["RandomForest"] = randomForestPrediction
        
        // Could add WaveNetPro predictions here too
        do {
            let waveNetProResults = try await predictWithWaveNetPro()
            for (modelIndex, prediction) in waveNetProResults {
                predictions["WaveNetPro\(modelIndex)"] = Prediction(
                    timestamp: Date(),
                    predictionValue: useMgdl ? prediction * 18.0 : prediction, // Convert from mmol/L if needed
                    usedMgdlUnits: useMgdl,
                    currentBG: prediction,
                    stabilityStatus: "STABLE" // Would need proper calculation
                )
            }
        } catch {
            print("⚠️ WaveNetPro predictions failed: \(error)")
        }
        
        return predictions
    }
}
