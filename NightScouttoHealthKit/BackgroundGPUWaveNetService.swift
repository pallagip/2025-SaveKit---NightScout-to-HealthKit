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
            
            // Build input tensor using HealthKit data or SwiftData cache
            let healthKitProvider = HealthKitFeatureProvider()
            var inputTensor: MLMultiArray
            var currentBG: Double
            
            do {
                // Try HealthKit first
                inputTensor = try await healthKitProvider.buildWindow()
                currentBG = try await healthKitProvider.fetchLatestGlucoseValue()
                print("✅ Using HealthKit data for GPU prediction")
            } catch {
                // Fallback to SwiftData cache
                print("⚠️ HealthKit unavailable, using SwiftData cache")
                print("🔨 Building input window from SwiftData cache...")
                inputTensor = try await healthKitProvider.buildWindowFromSwiftDataCache(modelContext: context)
                
                // Fetch ALL available glucose data from SwiftData cache (not just 1 reading)
                let glucoseData = try await healthKitProvider.fetchGlucoseFromSwiftDataCache(modelContext: context, limit: 50)
                print("✅ Found \(glucoseData.count) cached glucose readings")
                
                guard let latestReading = glucoseData.first else {
                    throw NSError(domain: "BackgroundGPU", code: 1, userInfo: [NSLocalizedDescriptionKey: "No glucose data available"])
                }
                
                // Log glucose data range for debugging
                if let oldestReading = glucoseData.last {
                    print("📈 Latest: \(Int(latestReading.value)) mg/dL at \(latestReading.date)")
                    print("📉 Oldest: \(Int(oldestReading.value)) mg/dL at \(oldestReading.date)")
                }
                
                currentBG = latestReading.value
                print("✅ Using SwiftData cache for GPU prediction")
            }
            
            print("🎯 Current BG: \(String(format: "%.1f", currentBG)) mg/dL")
            
            // Calculate prediction count
            let predictionCount = calculateNextPredictionCount(context: context)
            
            // Run all WaveNet models in parallel using GPU acceleration
            let predictions = await runParallelGPUWaveNetPredictions(
                window: inputTensor,
                currentBG: currentBG,
                usedMgdl: true,
                predictionCount: predictionCount,
                context: context,
                heartRate: heartRate
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
            
            // Save to SwiftData
            context.insert(averagePrediction)
            
            // Save individual model predictions
            for (modelIndex, prediction) in predictions {
                context.insert(prediction)
            }
            
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
    
    func getBackgroundPredictionStats() -> (count: Int, lastPrediction: Date?, averageValue: Double) {
        return (backgroundPredictionCount, lastBackgroundPrediction, averagePredictionValue)
    }
}
