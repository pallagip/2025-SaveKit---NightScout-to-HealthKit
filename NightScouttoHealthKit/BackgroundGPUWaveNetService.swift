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
    private func runImmediateGPUWaveNetPrediction() async {
        guard !isProcessing else {
            print("⚠️ GPU WaveNet prediction already in progress, skipping")
            return
        }
        
        print("🚀 === IMMEDIATE GPU WAVENET PREDICTION STARTED ===")
        await executeGPUWaveNetPrediction(isBackground: false)
    }
    
    @MainActor
    private func runBackgroundGPUWaveNetPrediction() async -> Bool {
        print("🚀 === BACKGROUND GPU WAVENET PREDICTION STARTED ===")
        return await executeGPUWaveNetPrediction(isBackground: true)
    }
    
    @MainActor
    private func executeGPUWaveNetPrediction(isBackground: Bool) async -> Bool {
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
                inputTensor = try await healthKitProvider.buildWindowFromSwiftDataCache(modelContext: context)
                let glucoseData = try await healthKitProvider.fetchGlucoseFromSwiftDataCache(modelContext: context, limit: 1)
                guard let latestReading = glucoseData.first else {
                    throw NSError(domain: "BackgroundGPU", code: 1, userInfo: [NSLocalizedDescriptionKey: "No glucose data available"])
                }
                currentBG = latestReading.value
                print("✅ Using SwiftData cache for GPU prediction")
            }
            
            print("🎯 Current BG: \(String(format: "%.1f", currentBG)) mg/dL")
            
            // Calculate prediction count
            let predictionCount = calculateNextPredictionCount(context: context)
            
            // Run all WaveNet models in series using GPU acceleration
            let predictions = await runSeriesGPUWaveNetPredictions(
                window: inputTensor,
                currentBG: currentBG,
                usedMgdl: true,
                predictionCount: predictionCount,
                context: context
            )
            
            // Calculate average prediction by averaging INDIVIDUAL MODEL PREDICTIONS (not deltas)
            let individualPredictions = predictions.values.compactMap { $0.predictionValue }
            guard !individualPredictions.isEmpty else {
                print("❌ No valid predictions from GPU WaveNet models")
                self.lastError = "No valid predictions generated"
                return false
            }
            
            // Average the individual model predictions (each is current BG + model delta)
            let finalPredictionMgdl = individualPredictions.reduce(0.0, +) / Double(individualPredictions.count)
            
            // Calculate the overall average change for logging
            let averageChange = (finalPredictionMgdl - currentBG) / 18.0 // Convert back to mmol/L
            let changeInMgdl = finalPredictionMgdl - currentBG
            
            print("🔮 GPU Prediction Calculation:")
            print("   Current BG: \(String(format: "%.1f", currentBG)) mg/dL")
            print("   Individual predictions: \(individualPredictions.map { String(format: "%.1f", $0) }.joined(separator: ", ")) mg/dL")
            print("   Average prediction: \(String(format: "%.1f", finalPredictionMgdl)) mg/dL")
            print("   Equivalent change: \(String(format: "%.2f", averageChange)) mmol/L = \(String(format: "%.1f", changeInMgdl)) mg/dL")
            
            // Create and save average prediction
            let timestamp = Date()
            let averagePrediction = Prediction(
                timestamp: timestamp,
                predictionValue: finalPredictionMgdl,
                usedMgdlUnits: true,
                currentBG: currentBG / 18.0, // Store in mmol/L
                stabilityStatus: "GPU_BACKGROUND",
                modelOutput: averageChange, // Store the average change in mmol/L
                modelPredictedChange: changeInMgdl, // Store the change in mg/dL
                observedTrend: 0,
                modelWeight: 1.0,
                trendWeight: 0.0,
                finalPredictedChange: changeInMgdl,
                actualBG: 0,
                actualBGTimestamp: nil,
                modelIndex: 0, // 0 indicates average prediction
                isAveragePrediction: true,
                note: "GPU Background: Average of \(predictions.count) WaveNet models",
                predictionCount: predictionCount
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
    
    // MARK: - Series GPU WaveNet Prediction
    private func runSeriesGPUWaveNetPredictions(
        window: MLMultiArray,
        currentBG: Double,
        usedMgdl: Bool,
        predictionCount: Int,
        context: ModelContext
    ) async -> [Int: Prediction] {
        
        print("🔥 === RUNNING SERIES GPU WAVENET PREDICTIONS ===")
        
        var modelPredictions: [Int: Prediction] = [:]
        
        // Helper function to copy MLMultiArray for each model
        func copyMLMultiArray(_ original: MLMultiArray) -> MLMultiArray {
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
        
        do {
            // WaveNet 1 - GPU Accelerated
            print("🔥 Running WaveNet1 on GPU...")
            let windowCopy1 = copyMLMultiArray(window)
            let prediction1 = try gpuWaveNet1.predict(window: windowCopy1, currentBG: currentBG, usedMgdl: usedMgdl, predictionCount: predictionCount)
            modelPredictions[1] = prediction1
            print("✅ GPU WaveNet1: \(String(format: "%.2f", prediction1.modelOutput)) mmol/L = \(String(format: "%.1f", prediction1.modelOutput * 18.0)) mg/dL")
            
            // WaveNet 2 - GPU Accelerated
            print("🔥 Running WaveNet2 on GPU...")
            let windowCopy2 = copyMLMultiArray(window)
            let prediction2 = try gpuWaveNet2.predict(window: windowCopy2, currentBG: currentBG, usedMgdl: usedMgdl, predictionCount: predictionCount)
            modelPredictions[2] = prediction2
            print("✅ GPU WaveNet2: \(String(format: "%.2f", prediction2.modelOutput)) mmol/L = \(String(format: "%.1f", prediction2.modelOutput * 18.0)) mg/dL")
            
            // WaveNet 3 - GPU Accelerated
            print("🔥 Running WaveNet3 on GPU...")
            let windowCopy3 = copyMLMultiArray(window)
            let prediction3 = try gpuWaveNet3.predict(window: windowCopy3, currentBG: currentBG, usedMgdl: usedMgdl, predictionCount: predictionCount)
            modelPredictions[3] = prediction3
            print("✅ GPU WaveNet3: \(String(format: "%.2f", prediction3.modelOutput)) mmol/L = \(String(format: "%.1f", prediction3.modelOutput * 18.0)) mg/dL")
            
            // WaveNet 4 - GPU Accelerated
            print("🔥 Running WaveNet4 on GPU...")
            let windowCopy4 = copyMLMultiArray(window)
            let prediction4 = try gpuWaveNet4.predict(window: windowCopy4, currentBG: currentBG, usedMgdl: usedMgdl, predictionCount: predictionCount)
            modelPredictions[4] = prediction4
            print("✅ GPU WaveNet4: \(String(format: "%.2f", prediction4.modelOutput)) mmol/L = \(String(format: "%.1f", prediction4.modelOutput * 18.0)) mg/dL")
            
            // WaveNet 5 - GPU Accelerated
            print("🔥 Running WaveNet5 on GPU...")
            let windowCopy5 = copyMLMultiArray(window)
            let prediction5 = try gpuWaveNet5.predict(window: windowCopy5, currentBG: currentBG, usedMgdl: usedMgdl, predictionCount: predictionCount)
            modelPredictions[5] = prediction5
            print("✅ GPU WaveNet5: \(String(format: "%.2f", prediction5.modelOutput)) mmol/L = \(String(format: "%.1f", prediction5.modelOutput * 18.0)) mg/dL")
            
        } catch {
            print("❌ GPU Series Prediction Error: \(error)")
        }
        
        print("🔥 === GPU WAVENET SERIES COMPLETE: \(modelPredictions.count) models ===")
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
    func triggerManualGPUPrediction() async {
        print("🎯 Manual GPU WaveNet prediction triggered")
        await runImmediateGPUWaveNetPrediction()
    }
    
    func getBackgroundPredictionStats() -> (count: Int, lastPrediction: Date?, averageValue: Double) {
        return (backgroundPredictionCount, lastBackgroundPrediction, averagePredictionValue)
    }
}
