import Foundation
import SwiftData
import HealthKit
import Combine

/// Service for caching Random Forest predictions in SwiftData
@MainActor
class RandomForestCachingService: ObservableObject {
    static let shared = RandomForestCachingService()
    
    private let healthKitFeatureProvider = HealthKitFeatureProvider()
    private let healthKitManager = HealthKitManager()
    private let randomForestService = RandomForestIntegrationService.shared
    
    @Published var isCaching: Bool = false
    @Published var lastCacheResult: String?
    @Published var cachedPredictionCount: Int = 0
    
    private init() {}
    
    /// Cache Random Forest predictions from recent data
    /// - Parameters:
    ///   - modelContext: SwiftData model context
    ///   - hoursBack: How many hours back to generate predictions for (default: 24)
    /// - Returns: Number of predictions cached
    @discardableResult
    func cacheRandomForestPredictions(modelContext: ModelContext, hoursBack: Double = 24.0) async throws -> Int {
        isCaching = true
        defer { isCaching = false }
        
        print("🌲 Starting Random Forest caching process for last \(hoursBack) hours...")
        
        do {
            // Get the time range for caching
            let endTime = Date()
            let startTime = endTime.addingTimeInterval(-hoursBack * 3600)
            
            print("📅 Caching timeframe: \(startTime.formatted()) to \(endTime.formatted())")
            
            // Fetch existing Random Forest predictions to avoid duplicates
            let existingPredictions = try fetchExistingRandomForestPredictions(modelContext: modelContext, startTime: startTime, endTime: endTime)
            print("📊 Found \(existingPredictions.count) existing Random Forest predictions in timeframe")
            
            // Get glucose readings from the time period to use as prediction timestamps
            let glucoseReadings = try await healthKitManager.fetchGlucoseForTimeRange(startDate: startTime, endDate: endTime)
            print("🩸 Found \(glucoseReadings.count) glucose readings for potential predictions")
            
            var cachedCount = 0
            let targetInterval: TimeInterval = 20 * 60 // 20 minutes between predictions
            
            // Filter glucose readings to create predictions at reasonable intervals
            var lastPredictionTime: Date? = nil
            
            for sample in glucoseReadings.sorted(by: { $0.startDate < $1.startDate }) {
                let sampleTime = sample.startDate
                
                // Skip if too close to last prediction
                if let lastTime = lastPredictionTime, sampleTime.timeIntervalSince(lastTime) < targetInterval {
                    continue
                }
                
                // Skip if we already have a prediction near this time (within 10 minutes)
                let hasNearbyPrediction = existingPredictions.contains { prediction in
                    abs(prediction.timestamp.timeIntervalSince(sampleTime)) < 10 * 60
                }
                
                if hasNearbyPrediction {
                    continue
                }
                
                // Create a Random Forest prediction for this timestamp
                do {
                    let cachedPrediction = try await createRandomForestPredictionForTime(sampleTime, modelContext: modelContext)
                    
                    if let prediction = cachedPrediction {
                        modelContext.insert(prediction)
                        cachedCount += 1
                        lastPredictionTime = sampleTime
                        
                        print("✅ Cached Random Forest prediction for \(sampleTime.formatted()): \(String(format: "%.1f", prediction.prediction_mmol)) mmol/L")
                    }
                } catch {
                    print("⚠️ Failed to create Random Forest prediction for \(sampleTime.formatted()): \(error)")
                }
            }
            
            // Save all cached predictions
            try modelContext.save()
            
            // Update published properties
            cachedPredictionCount = try fetchRandomForestPredictionCount(modelContext: modelContext)
            lastCacheResult = "Cached \(cachedCount) new Random Forest predictions. Total: \(cachedPredictionCount)"
            
            print("✅ Random Forest caching complete: \(cachedCount) new predictions cached")
            return cachedCount
            
        } catch {
            lastCacheResult = "Caching failed: \(error.localizedDescription)"
            print("❌ Random Forest caching failed: \(error)")
            throw error
        }
    }
    
    /// Create a Random Forest prediction for a specific timestamp using historical data
    private func createRandomForestPredictionForTime(_ timestamp: Date, modelContext: ModelContext) async throws -> RandomForestPrediction? {
        // Fetch historical data up to the prediction time
        let glucoseHistory = try await fetchHistoricalGlucoseData(upTo: timestamp, limit: 24)
        let carbHistory = try await fetchHistoricalCarbData(upTo: timestamp, hoursBack: 6.0)
        let insulinHistory = try await fetchHistoricalInsulinData(upTo: timestamp, hoursBack: 6.0)
        
        guard !glucoseHistory.isEmpty else {
            print("⚠️ No glucose data available for \(timestamp.formatted())")
            return nil
        }
        
        // Use the UpdatedGlucosePredictorService to make a prediction
        let heartRateHistory = try await fetchHistoricalHeartRateData(upTo: timestamp, minutesBack: 30.0)
        
        let predictionResult = UpdatedGlucosePredictorService().predictAbsoluteGlucose(
            glucoseHistory: glucoseHistory,
            carbsHistory: carbHistory,
            insulinHistory: insulinHistory,
            heartRateHistory: heartRateHistory,
            currentTime: timestamp
        )
        
        guard let result = predictionResult, let predictedValue = result.absolutePrediction else {
            print("⚠️ Random Forest prediction failed for \(timestamp.formatted())")
            return nil
        }
        
        // Convert predicted value from mg/dL to mmol/L
        let predictionMmol = predictedValue / 18.0
        
        // Calculate prediction count
        let predictionCount = try calculateNextPredictionCount(modelContext: modelContext)
        
        // Create the RandomForestPrediction object
        let prediction = RandomForestPrediction(
            timestamp: timestamp,
            predictionValue_mmol: predictionMmol,
            predictionCount: predictionCount
        )
        
        // Set carb and insulin timing information
        let lastCarbTimestamp = try await fetchLastCarbTimestamp(before: timestamp, hoursBack: 5.0)
        let lastInsulinTimestamp = try await fetchLastInsulinTimestamp(before: timestamp, hoursBack: 4.0)
        
        prediction.setCarbTiming(lastCarbTimestamp: lastCarbTimestamp, predictionTimestamp: timestamp)
        prediction.setInsulinTiming(lastInsulinTimestamp: lastInsulinTimestamp, predictionTimestamp: timestamp)
        
        return prediction
    }
    
    // MARK: - Helper Methods
    
    private func fetchExistingRandomForestPredictions(modelContext: ModelContext, startTime: Date, endTime: Date) throws -> [RandomForestPrediction] {
        let descriptor = FetchDescriptor<RandomForestPrediction>(
            predicate: #Predicate<RandomForestPrediction> { prediction in
                prediction.timestamp >= startTime && prediction.timestamp <= endTime
            },
            sortBy: [SortDescriptor(\RandomForestPrediction.timestamp, order: .forward)]
        )
        return try modelContext.fetch(descriptor)
    }
    
    private func fetchRandomForestPredictionCount(modelContext: ModelContext) throws -> Int {
        let descriptor = FetchDescriptor<RandomForestPrediction>()
        return try modelContext.fetchCount(descriptor)
    }
    
    private func calculateNextPredictionCount(modelContext: ModelContext) throws -> Int {
        let descriptor = FetchDescriptor<RandomForestPrediction>(
            sortBy: [SortDescriptor(\RandomForestPrediction.predictionCount, order: .reverse)]
        )
        let predictions = try modelContext.fetch(descriptor)
        
        if let latestCount = predictions.first?.predictionCount {
            return latestCount + 1
        } else {
            return 1
        }
    }
    
    private func fetchHistoricalGlucoseData(upTo timestamp: Date, limit: Int) async throws -> [Double] {
        let endTime = timestamp
        let startTime = timestamp.addingTimeInterval(-2 * 3600) // 2 hours back
        
        let samples = try await healthKitManager.fetchGlucoseForTimeRange(startDate: startTime, endDate: endTime)
        let sortedSamples = samples.sorted { $0.startDate > $1.startDate } // Most recent first
        let limitedSamples = Array(sortedSamples.prefix(limit))
        
        return limitedSamples.map { sample in
            let unit = HKUnit(from: "mg/dL")
            return sample.quantity.doubleValue(for: unit)
        }
    }
    
    private func fetchHistoricalCarbData(upTo timestamp: Date, hoursBack: Double) async throws -> [Double] {
        let endTime = timestamp
        let startTime = timestamp.addingTimeInterval(-hoursBack * 3600)
        
        let carbIntakes = try await healthKitFeatureProvider.fetchRecentCarbIntake(hoursBack: hoursBack)
        return carbIntakes.map { $0.grams }
    }
    
    private func fetchHistoricalInsulinData(upTo timestamp: Date, hoursBack: Double) async throws -> [Double] {
        let endTime = timestamp
        let startTime = timestamp.addingTimeInterval(-hoursBack * 3600)
        
        let insulinDoses = try await healthKitFeatureProvider.fetchRecentInsulinDoses(hoursBack: hoursBack)
        return insulinDoses.map { $0.units }
    }
    
    private func fetchHistoricalHeartRateData(upTo timestamp: Date, minutesBack: Double) async throws -> [Double] {
        // For now, return a default heart rate array
        // In a full implementation, you'd fetch actual historical heart rate data
        return Array(repeating: 70.0, count: 6)
    }
    
    private func fetchLastCarbTimestamp(before timestamp: Date, hoursBack: Double) async throws -> Date? {
        return try await healthKitFeatureProvider.fetchLastCarbEntryTimestamp(hoursBack: hoursBack)
    }
    
    private func fetchLastInsulinTimestamp(before timestamp: Date, hoursBack: Double) async throws -> Date? {
        return try await healthKitFeatureProvider.fetchLastInsulinEntryTimestamp(hoursBack: hoursBack)
    }
    
    /// Get the count of cached Random Forest predictions
    func getCachedPredictionCount(modelContext: ModelContext) -> Int {
        do {
            return try fetchRandomForestPredictionCount(modelContext: modelContext)
        } catch {
            print("⚠️ Error fetching Random Forest prediction count: \(error)")
            return 0
        }
    }
}
