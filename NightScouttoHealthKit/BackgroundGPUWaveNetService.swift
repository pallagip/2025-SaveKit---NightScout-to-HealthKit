//
//  BackgroundGPUWaveNetService.swift
//  NightScouttoHealthKit
//
//  Created for PatrickPallagi on 2025-08-03
//  Background GPU-accelerated WaveNet prediction service triggered by OneSignal notifications
//

import Foundation
import CoreML
import SwiftData
import BackgroundTasks
import UserNotifications
import OneSignalFramework

@MainActor
class BackgroundGPUWaveNetService: NSObject, ObservableObject {
    static let shared = BackgroundGPUWaveNetService()
    
    // Published properties for UI updates
    @Published var isProcessing: Bool = false
    @Published var lastBackgroundPrediction: Date?
    @Published var backgroundPredictionCount: Int = 0
    @Published var averagePredictionValue: Double = 0.0
    @Published var lastError: String?
    
    // Background task identifiers
    private let backgroundTaskID = "com.ProDiabeticsTeam.NightScouttoHealthKit.gpu-wavenet"
    
    // Model container reference
    private var modelContainer: ModelContainer?
    
    // GPU configuration for Core ML
    private let gpuConfiguration: MLModelConfiguration = {
        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndGPU // Use both CPU and GPU for optimal performance
        config.allowLowPrecisionAccumulationOnGPU = true // Enable GPU optimizations
        return config
    }()
    
    // WaveNet services with GPU configuration
    private lazy var gpuWaveNet1: WaveNet1Service = {
        return WaveNet1Service.shared
    }()
    
    private lazy var gpuWaveNet2: WaveNet2Service = {
        return WaveNet2Service.shared
    }()
    
    private lazy var gpuWaveNet3: WaveNet3Service = {
        return WaveNet3Service.shared
    }()
    
    private lazy var gpuWaveNet4: WaveNet4Service = {
        return WaveNet4Service.shared
    }()
    
    private lazy var gpuWaveNet5: WaveNet5Service = {
        return WaveNet5Service.shared
    }()
    
    override init() {
        super.init()
        registerBackgroundTasks()
    }
    
    // MARK: - Model Container Setup
    func setModelContainer(_ container: ModelContainer) {
        self.modelContainer = container
        print("🔧 BackgroundGPUWaveNetService: Model container set")
    }
    
    /// Public getter for model container
    func getModelContainer() -> ModelContainer? {
        return modelContainer
    }
    

    
    // MARK: - Background Task Registration
    private func registerBackgroundTasks() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: backgroundTaskID, using: nil) { task in
            print("🔄 Background GPU WaveNet task started")
            self.handleBackgroundGPUWaveNetTask(task as! BGProcessingTask)
        }
        print("✅ Background GPU WaveNet task registered: \(backgroundTaskID)")
    }
    

    
    // MARK: - Background Task Scheduling
    @MainActor
    private func scheduleBackgroundGPUProcessing() async {
        let request = BGProcessingTaskRequest(identifier: backgroundTaskID)
        request.requiresNetworkConnectivity = false
        request.requiresExternalPower = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: 1) // Start in 1 second
        
        do {
            try BGTaskScheduler.shared.submit(request)
            print("✅ Background GPU WaveNet task scheduled successfully")
        } catch {
            print("❌ Failed to schedule background GPU WaveNet task: \(error)")
            self.lastError = "Failed to schedule background task: \(error.localizedDescription)"
        }
    }
    
    // MARK: - Background Task Handler
    private func handleBackgroundGPUWaveNetTask(_ task: BGProcessingTask) {
        print("🔄 === BACKGROUND GPU WAVENET TASK EXECUTING ===")
        
        task.expirationHandler = {
            print("⏰ Background GPU WaveNet task expired")
            task.setTaskCompleted(success: false)
        }
        
        Task { @MainActor in
            let success = await self.runBackgroundGPUWaveNetPrediction()
            task.setTaskCompleted(success: success)
            
            // Schedule next background task
            await self.scheduleBackgroundGPUProcessing()
        }
    }
    
    // MARK: - GPU WaveNet Prediction Execution
    @MainActor
    private func runImmediateGPUWaveNetPrediction(heartRate: Double) async {
        guard !isProcessing else {
            print("⚠️ GPU WaveNet prediction already in progress, skipping")
            return
        }
        
        print("🚀 === IMMEDIATE GPU WAVENET PREDICTION STARTED ===")
        _ = await executeGPUWaveNetPrediction(isBackground: false, heartRate: heartRate)
    }
    
    @MainActor
    private func runBackgroundGPUWaveNetPrediction() async -> Bool {
        print("🚀 === BACKGROUND GPU WAVENET PREDICTION STARTED ===")
        return await executeGPUWaveNetPrediction(isBackground: true, heartRate: 0.0)
    }
    
    @MainActor
    private func executeGPUWaveNetPrediction(isBackground: Bool, heartRate: Double) async -> Bool {
        isProcessing = true
        defer { isProcessing = false }
        
        guard let modelContainer = self.modelContainer else {
            print("❌ Model container not available")
            self.lastError = "Model container not available"
            return false
        }
        
        do {
            let context = ModelContext(modelContainer)
            
            print("🧠 Building input tensor for GPU WaveNet prediction...")
            print("❤️ Using Watch heart rate: \(heartRate) BPM for enhanced prediction")
            
            // Build input tensor using HealthKit data or SwiftData cache
            let healthKitProvider = HealthKitFeatureProvider()
            var inputTensor: MLMultiArray
            var currentBG: Double
            var effectiveHeartRate = heartRate
            
            do {
                // Try to use HealthKit data first
                inputTensor = try await healthKitProvider.buildWindow()
                currentBG = try await healthKitProvider.fetchLatestGlucoseValue()
                
                // If no heart rate from Watch, try to get from HealthKit
                if effectiveHeartRate <= 0 {
                    effectiveHeartRate = try await healthKitProvider.fetchLatestHeartRate(minutesBack: 30.0)
                    print("💓 Using HealthKit heart rate: \(effectiveHeartRate) BPM")
                } else {
                    print("⌚ Using Watch heart rate: \(effectiveHeartRate) BPM")
                }
                
                print("✅ Using HealthKit data for GPU prediction")
            } catch {
                // Fallback to SwiftData cache
                print("⚠️ HealthKit unavailable, using SwiftData cache")
                print("🔨 Building input window from SwiftData cache...")
                
                // For background mode, we need to enhance the input tensor with Watch data
                inputTensor = try await buildEnhancedBackgroundInputTensor(
                    healthKitProvider: healthKitProvider,
                    context: context,
                    watchHeartRate: effectiveHeartRate
                )
                
                // Get current glucose from cache
                let glucoseData = try await healthKitProvider.fetchGlucoseFromSwiftDataCache(modelContext: context, limit: 1)
                guard let latestReading = glucoseData.first else {
                    throw NSError(domain: "SwiftData", code: 3, userInfo: [NSLocalizedDescriptionKey: "No glucose data in cache"])
                }
                
                currentBG = latestReading.value
                
                // If no heart rate from Watch, use a default reasonable value for background
                if effectiveHeartRate <= 0 {
                    effectiveHeartRate = 75.0 // Default resting heart rate
                    print("💔 No heart rate available, using default: \(effectiveHeartRate) BPM")
                }
                
                print("✅ Using SwiftData cache for GPU prediction with Watch enhancement")
            }
            
            print("🎯 Current BG: \(String(format: "%.1f", currentBG)) mg/dL")
            
            // Calculate prediction count
            let predictionCount = calculateNextPredictionCount(context: context)
            
            // Run all 5 WaveNet models in parallel on GPU with enhanced configuration
            let predictions = await runParallelGPUWaveNetPredictions(
                window: inputTensor,
                currentBG: currentBG,
                usedMgdl: true,
                predictionCount: predictionCount,
                context: context,
                heartRate: effectiveHeartRate
            )
            
            // Calculate average prediction by averaging INDIVIDUAL MODEL PREDICTIONS (not deltas)
            // Collect absolute predictions (mg/dL) from each model
            let individualPredictions = predictions.values.map { $0.predictionValue }
            guard !individualPredictions.isEmpty else {
                print("❌ No valid predictions from GPU WaveNet models")
                self.lastError = "No valid predictions generated"
                return false
            }
            
            // Average the individual model predictions
            // Average the absolute predictions to get final glucose prediction
            let finalPredictionMgdl = individualPredictions.reduce(0.0, +) / Double(individualPredictions.count)
            let changeInMgdl = finalPredictionMgdl - currentBG
            let averageChange = changeInMgdl / 18.0 // mmol/L change
            
            
            
            print("🔮 GPU Prediction Calculation:")
            print("   Current BG: \(String(format: "%.1f", currentBG)) mg/dL")
            print("   Individual predictions: \(individualPredictions.map { String(format: "%.1f", $0) }.joined(separator: ", ")) mg/dL")
            print("   Final predicted BG (average): \(String(format: "%.1f", finalPredictionMgdl)) mg/dL")
            print("   Equivalent change: \(String(format: "%.2f", averageChange)) mmol/L = \(String(format: "%.1f", changeInMgdl)) mg/dL")
            
            // Create and save average prediction
            let timestamp = Date()
            let averagePrediction = Prediction(
                timestamp: timestamp,
                predictionValue: finalPredictionMgdl,
                usedMgdlUnits: true,
                currentBG: currentBG / 18.0, // Store in mmol/L
                stabilityStatus: "GPU_BACKGROUND",
                modelOutput: averageChange, // average change mmol/L
                modelPredictedChange: changeInMgdl, // change mg/dL
                observedTrend: 0,
                modelWeight: 1.0,
                trendWeight: 0.0,
                finalPredictedChange: changeInMgdl,
                actualBG: 0,
                actualBGTimestamp: nil,
                modelIndex: 0, // 0 indicates average prediction
                isAveragePrediction: true,
                note: "Average of \(predictions.count) GPU models.",
                predictionCount: predictionCount,
                heartRate: heartRate
            )
            
            // Create MultiModelPrediction record mirroring GPU results for CSV export
            let multiPrediction = MultiModelPrediction(
                timestamp: timestamp,
                currentBG_mmol: currentBG / 18.0,
                predictionCount: predictionCount
            )
            // Populate individual model predictions in mmol/L
            for (modelIndex, pred) in predictions {
                multiPrediction.setPrediction(model: modelIndex, mmol: pred.modelOutput)
            }
            // Set the average prediction fields
            multiPrediction.avg_pred_mmol = finalPredictionMgdl / 18.0
            multiPrediction.avg_pred_mgdl = Int(round(finalPredictionMgdl))
            // Set carb timing if available
            do {
                let lastCarbTimestamp = try await healthKitProvider.fetchLastCarbEntryTimestamp()
                multiPrediction.setCarbTiming(lastCarbTimestamp: lastCarbTimestamp, predictionTimestamp: timestamp)
            } catch {
                multiPrediction.setCarbTiming(lastCarbTimestamp: nil, predictionTimestamp: timestamp)
            }
            // Fallback: use SwiftData carb cache (5h window) if HK provided none
            if multiPrediction.timeSinceLastCarb_minutes < 0 {
                let carbWindowStart = timestamp.addingTimeInterval(-5 * 3600)
                let carbFetch = FetchDescriptor<NightScoutCarbCache>(
                    predicate: #Predicate<NightScoutCarbCache> { cache in
                        cache.timestamp >= carbWindowStart && cache.timestamp <= timestamp
                    },
                    sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
                )
                if let results = try? context.fetch(carbFetch), let cache = results.first {
                    multiPrediction.setCarbTiming(lastCarbTimestamp: cache.timestamp, predictionTimestamp: timestamp)
                }
            }
            // Set insulin timing if available
            do {
                let lastInsulinTimestamp = try await healthKitProvider.fetchLastInsulinEntryTimestamp()
                multiPrediction.setInsulinTiming(lastInsulinTimestamp: lastInsulinTimestamp, predictionTimestamp: timestamp)
            } catch {
                multiPrediction.setInsulinTiming(lastInsulinTimestamp: nil, predictionTimestamp: timestamp)
            }
            // Fallback: use SwiftData insulin cache (4h window) if HK provided none
            if multiPrediction.timeSinceLastInsulin_minutes < 0 {
                let insulinWindowStart = timestamp.addingTimeInterval(-4 * 3600)
                let insulinFetch = FetchDescriptor<NightScoutInsulinCache>(
                    predicate: #Predicate<NightScoutInsulinCache> { cache in
                        cache.timestamp >= insulinWindowStart && cache.timestamp <= timestamp
                    },
                    sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
                )
                if let results = try? context.fetch(insulinFetch), let cache = results.first {
                    multiPrediction.setInsulinTiming(lastInsulinTimestamp: cache.timestamp, predictionTimestamp: timestamp)
                }
            }
            
            // Save to SwiftData
            context.insert(averagePrediction)
            
            // Save individual model predictions
            for (modelIndex, prediction) in predictions {
                context.insert(prediction)
            }
            // Save MultiModelPrediction record used by SettingsView export
            context.insert(multiPrediction)
            
            // Persist all records
            
            try context.save()
            
            // Update published properties
            self.lastBackgroundPrediction = timestamp
            self.backgroundPredictionCount += 1
            self.averagePredictionValue = finalPredictionMgdl
            self.lastError = nil
            
            print("✅ === GPU WAVENET BACKGROUND PREDICTION COMPLETE ===")
            print("📊 Average Prediction: \(String(format: "%.1f", finalPredictionMgdl)) mg/dL")
            print("🔢 Total Background Predictions: \(backgroundPredictionCount)")
            print("💾 Saved \(predictions.count + 1) predictions to SwiftData")
            
            // Send local notification about completion
            await sendCompletionNotification(averagePrediction: finalPredictionMgdl, modelCount: predictions.count)
            
            return true
            
        } catch {
            print("❌ GPU WaveNet prediction failed: \(error)")
            self.lastError = "GPU prediction failed: \(error.localizedDescription)"
            return false
        }
    }
    
    // MARK: - Parallel GPU WaveNet Prediction
    private func runParallelGPUWaveNetPredictions(
        window: MLMultiArray,
        currentBG: Double,
        usedMgdl: Bool,
        predictionCount: Int,
        context: ModelContext,
        heartRate: Double
    ) async -> [Int: Prediction] {
        
        print("🚀 === RUNNING PARALLEL GPU WAVENET PREDICTIONS ===")
        
        // Helper function to copy MLMultiArray - nonisolated to work in parallel tasks
        nonisolated func copyMLMultiArray(_ original: MLMultiArray) -> MLMultiArray {
            guard let copy = try? MLMultiArray(shape: original.shape, dataType: original.dataType) else {
                fatalError("Failed to create MLMultiArray copy")
            }
            
            let originalPtr = original.dataPointer.bindMemory(to: Float32.self, capacity: original.count)
            let copyPtr = copy.dataPointer.bindMemory(to: Float32.self, capacity: copy.count)
            
            for i in 0..<original.count {
                copyPtr[i] = originalPtr[i]
            }
            
            return copy
        }
        
        // Run all 5 WaveNet models concurrently using TaskGroup for better actor isolation
        let results = await withTaskGroup(of: (Int, Prediction?).self) { group in
            
            // WaveNet 1
            group.addTask {
                do {
                    await MainActor.run { print("🚀 Starting WaveNet1 on GPU...") }
                    let windowCopy1 = copyMLMultiArray(window)
                    let service1 = await MainActor.run { self.gpuWaveNet1 }
                    var prediction1 = try service1.predict(window: windowCopy1, currentBG: currentBG, usedMgdl: usedMgdl, predictionCount: predictionCount)
                    prediction1.heartRate = heartRate
                    await MainActor.run { 
                        print("✅ GPU WaveNet1: \(String(format: "%.2f", prediction1.modelOutput)) mmol/L = \(String(format: "%.1f", prediction1.modelOutput * 18.0)) mg/dL") 
                    }
                    return (1, prediction1)
                } catch {
                    await MainActor.run { print("❌ GPU WaveNet1 failed: \(error.localizedDescription)") }
                    return (1, nil)
                }
            }
            
            // WaveNet 2
            group.addTask {
                do {
                    await MainActor.run { print("🚀 Starting WaveNet2 on GPU...") }
                    let windowCopy2 = copyMLMultiArray(window)
                    let service2 = await MainActor.run { self.gpuWaveNet2 }
                    var prediction2 = try service2.predict(window: windowCopy2, currentBG: currentBG, usedMgdl: usedMgdl, predictionCount: predictionCount)
                    prediction2.heartRate = heartRate
                    await MainActor.run { 
                        print("✅ GPU WaveNet2: \(String(format: "%.2f", prediction2.modelOutput)) mmol/L = \(String(format: "%.1f", prediction2.modelOutput * 18.0)) mg/dL") 
                    }
                    return (2, prediction2)
                } catch {
                    await MainActor.run { print("❌ GPU WaveNet2 failed: \(error.localizedDescription)") }
                    return (2, nil)
                }
            }
            
            // WaveNet 3
            group.addTask {
                do {
                    await MainActor.run { print("🚀 Starting WaveNet3 on GPU...") }
                    let windowCopy3 = copyMLMultiArray(window)
                    let service3 = await MainActor.run { self.gpuWaveNet3 }
                    var prediction3 = try service3.predict(window: windowCopy3, currentBG: currentBG, usedMgdl: usedMgdl, predictionCount: predictionCount)
                    prediction3.heartRate = heartRate
                    await MainActor.run { 
                        print("✅ GPU WaveNet3: \(String(format: "%.2f", prediction3.modelOutput)) mmol/L = \(String(format: "%.1f", prediction3.modelOutput * 18.0)) mg/dL") 
                    }
                    return (3, prediction3)
                } catch {
                    await MainActor.run { print("❌ GPU WaveNet3 failed: \(error.localizedDescription)") }
                    return (3, nil)
                }
            }
            
            // WaveNet 4
            group.addTask {
                do {
                    await MainActor.run { print("🚀 Starting WaveNet4 on GPU...") }
                    let windowCopy4 = copyMLMultiArray(window)
                    let service4 = await MainActor.run { self.gpuWaveNet4 }
                    var prediction4 = try service4.predict(window: windowCopy4, currentBG: currentBG, usedMgdl: usedMgdl, predictionCount: predictionCount)
                    prediction4.heartRate = heartRate
                    await MainActor.run { 
                        print("✅ GPU WaveNet4: \(String(format: "%.2f", prediction4.modelOutput)) mmol/L = \(String(format: "%.1f", prediction4.modelOutput * 18.0)) mg/dL") 
                    }
                    return (4, prediction4)
                } catch {
                    await MainActor.run { print("❌ GPU WaveNet4 failed: \(error.localizedDescription)") }
                    return (4, nil)
                }
            }
            
            // WaveNet 5
            group.addTask {
                do {
                    await MainActor.run { print("🚀 Starting WaveNet5 on GPU...") }
                    let windowCopy5 = copyMLMultiArray(window)
                    let service5 = await MainActor.run { self.gpuWaveNet5 }
                    var prediction5 = try service5.predict(window: windowCopy5, currentBG: currentBG, usedMgdl: usedMgdl, predictionCount: predictionCount)
                    prediction5.heartRate = heartRate
                    await MainActor.run { 
                        print("✅ GPU WaveNet5: \(String(format: "%.2f", prediction5.modelOutput)) mmol/L = \(String(format: "%.1f", prediction5.modelOutput * 18.0)) mg/dL") 
                    }
                    return (5, prediction5)
                } catch {
                    await MainActor.run { print("❌ GPU WaveNet5 failed: \(error.localizedDescription)") }
                    return (5, nil)
                }
            }
            
            // Collect all results
            var allResults: [(Int, Prediction?)] = []
            for await result in group {
                allResults.append(result)
            }
            return allResults
        }
        
        // Collect successful predictions
        var modelPredictions: [Int: Prediction] = [:]
        var successCount = 0
        
        for (modelIndex, prediction) in results {
            if let prediction = prediction {
                modelPredictions[modelIndex] = prediction
                successCount += 1
            }
        }
        
        print("🚀 === PARALLEL GPU WAVENET COMPLETE: \(successCount)/5 models succeeded ===")
        return modelPredictions
    }
    
    // MARK: - Helper Functions
    private func calculateNextPredictionCount(context: ModelContext) -> Int {
        let descriptor = FetchDescriptor<Prediction>(
            sortBy: [SortDescriptor(\.predictionCount, order: .reverse)]
        )
        
        do {
            let predictions = try context.fetch(descriptor)
            if let lastPrediction = predictions.first, lastPrediction.predictionCount > 0 {
                return lastPrediction.predictionCount + 1
            }
        } catch {
            print("⚠️ Error fetching prediction count: \(error)")
        }
        
        return 1
    }
    
    /// Build enhanced input tensor for background mode using ONLY Watch data and SwiftData cache
    /// This method is completely background-safe and makes NO HealthKit calls
    private func buildEnhancedBackgroundInputTensor(
        healthKitProvider: HealthKitFeatureProvider,
        context: ModelContext,
        watchHeartRate: Double
    ) async throws -> MLMultiArray {
        print("🔧 Building enhanced background input tensor with Watch data")
        print("🚀 BACKGROUND-SAFE MODE: Using only SwiftData cache + Watch data")
        
        // Get glucose data from SwiftData cache only
        let glucoseData = try await healthKitProvider.fetchGlucoseFromSwiftDataCache(modelContext: context, limit: 24)
        
        guard !glucoseData.isEmpty else {
            throw NSError(domain: "SwiftData", code: 3, userInfo: [NSLocalizedDescriptionKey: "No glucose data in SwiftData cache"])
        }
        
        print("📊 Cache data: \(glucoseData.count) glucose readings from SwiftData")
        
        // Build tensor manually using only cached data and Watch heart rate
        // WaveNet models expect [batch_size, timesteps, features] = [1, 24, 8]
        let tensor = try MLMultiArray(shape: [1, 24, 8], dataType: .float32)
        
        let now = Date()
        let step = 5.0 * 60  // 5 min in seconds
        
        // Calculate IOB and COB from SwiftData cache only (no HealthKit calls)
        let (cachedIOB, cachedCOB) = HealthKitFeatureProvider.calculateActiveIOBandCOBFromCaches(
            modelContext: context, 
            now: now
        )
        
        print("💉 Background IOB from cache: \(String(format: "%.2f", cachedIOB)) U")
        print("🍞 Background COB from cache: \(String(format: "%.1f", cachedCOB)) g")
        
        // Create 24 timesteps going backward from now
        for timestep in 0..<24 {
            let timestepTime = now.addingTimeInterval(-Double(23 - timestep) * step)
            
            // Find closest glucose value to this timestep
            var glucoseValue = 100.0 // Default
            var minTimeDiff = Double.infinity
            
            for reading in glucoseData {
                let timeDiff = abs(reading.date.timeIntervalSince(timestepTime))
                if timeDiff < minTimeDiff {
                    minTimeDiff = timeDiff
                    glucoseValue = reading.value
                }
            }
            
            // Calculate trends
            let bgTrend: Double
            let hrTrend: Double = 0.0 // No Watch HR trend in background
            
            if timestep > 0 {
                // Get previous glucose for trend calculation
                let prevTimestepTime = now.addingTimeInterval(-Double(24 - timestep) * step)
                var prevGlucoseValue = glucoseValue
                var prevMinTimeDiff = Double.infinity
                
                for reading in glucoseData {
                    let timeDiff = abs(reading.date.timeIntervalSince(prevTimestepTime))
                    if timeDiff < prevMinTimeDiff {
                        prevMinTimeDiff = timeDiff
                        prevGlucoseValue = reading.value
                    }
                }
                
                bgTrend = (glucoseValue - prevGlucoseValue) / 18.0 / 5.0 // Convert to mmol/L per minute
            } else {
                bgTrend = 0.0
            }
            
            // Calculate circadian features
            let calendar = Calendar.current
            let hour = Double(calendar.component(.hour, from: timestepTime))
            let minute = Double(calendar.component(.minute, from: timestepTime))
            let hourFraction = hour + minute / 60.0
            let hourSin = sin(2.0 * .pi * hourFraction / 24.0)
            let hourCos = cos(2.0 * .pi * hourFraction / 24.0)
            
            // Fill tensor features for this timestep
            let baseIndex = timestep * 8
            
            // Feature 0: blood_glucose (convert mg/dL to mmol/L)
            tensor[baseIndex] = NSNumber(value: glucoseValue / 18.0)
            
            // Feature 1: insulin_dose (distributed IOB)
            tensor[baseIndex + 1] = NSNumber(value: cachedIOB / 24.0)
            
            // Feature 2: dietary_carbohydrates (distributed COB)
            tensor[baseIndex + 2] = NSNumber(value: cachedCOB / 24.0)
            
            // Feature 3: heart_rate (from Watch, normalized)
            let normalizedHR = (watchHeartRate - 70.0) / 30.0
            tensor[baseIndex + 3] = NSNumber(value: normalizedHR)
            
            // Feature 4: bg_trend
            tensor[baseIndex + 4] = NSNumber(value: bgTrend)
            
            // Feature 5: hr_trend (no trend available in background)
            tensor[baseIndex + 5] = NSNumber(value: hrTrend)
            
            // Feature 6: hour_sin (circadian)
            tensor[baseIndex + 6] = NSNumber(value: hourSin)
            
            // Feature 7: hour_cos (circadian)
            tensor[baseIndex + 7] = NSNumber(value: hourCos)
        }
        
        print("✅ Enhanced background tensor built with Watch HR: \(watchHeartRate) BPM")
        print("🎯 Background tensor features: glucose, IOB=\(String(format: "%.2f", cachedIOB)), COB=\(String(format: "%.1f", cachedCOB)), HR=\(watchHeartRate)")
        
        return tensor
    }
    
    /// Helper function to copy MLMultiArray data
    private func copyMLMultiArrayData(_ original: MLMultiArray) -> MLMultiArray {
        guard let copy = try? MLMultiArray(shape: original.shape, dataType: original.dataType) else {
            fatalError("Failed to create MLMultiArray copy")
        }
        
        let originalPtr = original.dataPointer.bindMemory(to: Float32.self, capacity: original.count)
        let copyPtr = copy.dataPointer.bindMemory(to: Float32.self, capacity: copy.count)
        
        for i in 0..<original.count {
            copyPtr[i] = originalPtr[i]
        }
        
        return copy
    }
    
    /// Enhance insulin and carb features in the tensor with fresh HealthKit data
    private func enhanceInsulinCarbFeatures(
        tensor: MLMultiArray,
        insulinData: [HealthKitFeatureProvider.InsulinDose],
        carbData: [HealthKitFeatureProvider.CarbIntake]
    ) async {
        let timeSteps = tensor.shape[0].intValue
        let currentTime = Date()
        
        // For each timestep, calculate insulin and carb values based on timing
        for timestep in 0..<timeSteps {
            let timestepTime = currentTime.addingTimeInterval(-Double(timeSteps - timestep) * 60 * 5) // 5-min intervals
            
            // Calculate insulin dose for this timestep (within 1 hour)
            var insulinDose = 0.0
            for insulin in insulinData {
                let timeDiff = abs(insulin.timestamp.timeIntervalSince(timestepTime))
                if timeDiff <= 3600 { // Within 1 hour
                    let decayFactor = max(0, 1.0 - (timeDiff / 3600)) // Linear decay
                    insulinDose += insulin.units * decayFactor
                }
            }
            
            // Calculate carb amount for this timestep (within 2 hours)
            var carbAmount = 0.0
            for carb in carbData {
                let timeDiff = abs(carb.timestamp.timeIntervalSince(timestepTime))
                if timeDiff <= 7200 { // Within 2 hours
                    let decayFactor = max(0, 1.0 - (timeDiff / 7200)) // Linear decay
                    carbAmount += carb.grams * decayFactor
                }
            }
            
            // Update tensor features
            let insulinFeatureIndex = 1 // insulin_dose is feature index 1
            let carbFeatureIndex = 2    // dietary_carbohydrates is feature index 2
            
            let insulinIndex = [timestep as NSNumber, insulinFeatureIndex as NSNumber]
            let carbIndex = [timestep as NSNumber, carbFeatureIndex as NSNumber]
            
            tensor[insulinIndex] = NSNumber(value: insulinDose)
            tensor[carbIndex] = NSNumber(value: carbAmount)
        }
        
        print("🔧 Enhanced tensor with fresh insulin/carb data from HealthKit")
    }
    
    // MARK: - Completion Notification
    private func sendCompletionNotification(averagePrediction: Double, modelCount: Int) async {
        let content = UNMutableNotificationContent()
        content.title = "🔥 GPU WaveNet Prediction Complete"
        content.body = "Average: \(String(format: "%.1f", averagePrediction)) mg/dL from \(modelCount) models"
        content.sound = .default
        content.badge = NSNumber(value: backgroundPredictionCount)
        
        let request = UNNotificationRequest(
            identifier: "gpu-wavenet-complete-\(Date().timeIntervalSince1970)",
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        )
        
        do {
            try await UNUserNotificationCenter.current().add(request)
            print("📱 GPU WaveNet completion notification sent")
        } catch {
            print("❌ Failed to send completion notification: \(error)")
        }
    }
    
    // MARK: - Public Interface
    func triggerManualGPUPrediction(heartRate: Double = 0.0) async {
        print("🎯 Manual GPU WaveNet prediction triggered with Heart Rate: \(heartRate) BPM")
        await runImmediateGPUWaveNetPrediction(heartRate: heartRate)
    }
    
    /// Trigger enhanced GPU prediction with comprehensive Watch-collected health data
    /// This method integrates Watch data into the background-safe prediction pipeline
    func triggerEnhancedWatchGPUPrediction(
        heartRate: Double,
        watchInsulin: Double,
        watchInsulinTimestamp: Date?,
        watchCarbs: Double,
        watchCarbTimestamp: Date?,
        watchGlucose: Double,
        watchTrend: Double
    ) async {
        print("🎯 Enhanced Watch GPU WaveNet prediction triggered")
        print("⌚ Watch Data - HR: \(heartRate), Insulin: \(watchInsulin) (ts: \(watchInsulinTimestamp?.formatted() ?? "nil")), Carbs: \(watchCarbs) (ts: \(watchCarbTimestamp?.formatted() ?? "nil")), Glucose: \(watchGlucose), Trend: \(watchTrend)")
        
        // Store Watch data for background prediction use
        await storeWatchDataForBackgroundUse(
            insulin: watchInsulin,
            insulinTimestamp: watchInsulinTimestamp,
            carbs: watchCarbs,
            carbTimestamp: watchCarbTimestamp,
            glucose: watchGlucose,
            trend: watchTrend
        )
        
        // Trigger GPU prediction with Watch heart rate
        await runImmediateGPUWaveNetPrediction(heartRate: heartRate)
    }
    
    /// Store Watch-collected health data in SwiftData for background prediction use
    /// This ensures fresh data is available even when HealthKit is inaccessible
    private func storeWatchDataForBackgroundUse(
        insulin: Double,
        insulinTimestamp: Date?,
        carbs: Double,
        carbTimestamp: Date?,
        glucose: Double,
        trend: Double
    ) async {
        guard let modelContainer = self.modelContainer else {
            print("❌ Model container not available for Watch data storage")
            return
        }
        
        let context = ModelContext(modelContainer)
        let now = Date()
        
        do {
            // Cache insulin if trusted timestamp is available
            if insulin > 0.1, let ts = insulinTimestamp {
                let ins = NightScoutInsulinCache(
                    timestamp: ts,
                    insulinAmount: insulin,
                    insulinType: nil,
                    nightScoutId: "watch-ins-\(UUID().uuidString)",
                    sourceInfo: "Apple Watch HealthKit"
                )
                context.insert(ins)
                print("💉 Stored Watch insulin with trusted timestamp: \(String(format: "%.2f", insulin)) U at \(ts.formatted()))")
            } else if insulin > 0.1 {
                print("⏭️ Skipping Watch insulin cache: missing trusted timestamp (dose=\(String(format: "%.2f", insulin)))")
            }
            
            // Cache carbs if trusted timestamp is available
            if carbs > 1.0, let ts = carbTimestamp {
                let carb = NightScoutCarbCache(
                    timestamp: ts,
                    carbAmount: carbs,
                    carbType: nil,
                    nightScoutId: "watch-carb-\(UUID().uuidString)",
                    sourceInfo: "Apple Watch HealthKit"
                )
                context.insert(carb)
                print("🍞 Stored Watch carbs with trusted timestamp: \(String(format: "%.1f", carbs)) g at \(ts.formatted()))")
            } else if carbs > 1.0 {
                print("⏭️ Skipping Watch carb cache: missing trusted timestamp (carbs=\(String(format: "%.1f", carbs)))")
            }
            
            // Store Watch glucose data if valid and recent (BG is time-sensitive to 'now' and used for current state)
            if glucose > 50.0 && glucose < 500.0 {
                let watchBGEntry = HealthKitBGCache(
                    timestamp: now,
                    bloodGlucose_mmol: glucose / 18.0, // Convert mg/dL to mmol/L
                    healthKitUUID: "watch-bg-\(UUID().uuidString)",
                    sourceInfo: "Apple Watch CGM (trend: \(String(format: "%.2f", trend)))"
                )
                context.insert(watchBGEntry)
                print("🩸 Stored Watch glucose: \(String(format: "%.0f", glucose)) mg/dL (trend: \(String(format: "%.2f", trend)))")
            }
            
            // Save all Watch data to SwiftData
            try context.save()
            print("✅ Watch health data successfully stored for background prediction use")
            
        } catch {
            print("❌ Failed to store Watch data for background use: \(error.localizedDescription)")
        }
    }
    
    func getBackgroundPredictionStats() -> (count: Int, lastPrediction: Date?, averageValue: Double) {
        return (backgroundPredictionCount, lastBackgroundPrediction, averagePredictionValue)
    }
}
