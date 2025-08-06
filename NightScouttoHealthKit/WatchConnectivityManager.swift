//
//  WatchConnectivityManager.swift
//  NightScouttoHealthKit
//
//  Handles communication between iPhone app and Apple Watch
//

import Foundation
import WatchConnectivity
import SwiftData
import UIKit
import HealthKit
import HealthKitUI

class WatchConnectivityManager: NSObject, ObservableObject {
    static let shared = WatchConnectivityManager()
    private let healthStore = HKHealthStore()
    
    @Published var isWatchConnected = false
    @Published var isPaired = false
    @Published var isWatchAppInstalled = false
    
    // Background task management for Watch-triggered operations
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private let backgroundTaskQueue = DispatchQueue(label: "com.watchconnectivity.backgroundtask")
    
    private override init() {
        super.init()
        setupWatchConnectivity()
    }
    
    private func setupWatchConnectivity() {
        if WCSession.isSupported() {
            let session = WCSession.default
            session.delegate = self
            session.activate()
            print("🔗 iPhone WatchConnectivity session activated")
        }
    }
    
    /// Sends a blood glucose prediction to the Apple Watch
    /// - Parameters:
    ///   - prediction: Prediction value in mmol/L
    ///   - timestamp: When the prediction was made
    /// Sends a GPU prediction result to the Apple Watch
    /// - Parameters:
    ///   - prediction: GPU prediction value in mmol/L
    ///   - timestamp: When the prediction was completed
    func sendGPUPredictionToWatch(prediction: Double, timestamp: Date = Date()) {
        guard WCSession.default.activationState == .activated else {
            print("⚠️ WatchConnectivity not activated for GPU result")
            return
        }
        
        let message = [
            "type": "gpu_prediction_result",
            "prediction_mmol": prediction,
            "prediction_mgdl": prediction * 18.0,
            "timestamp": timestamp.timeIntervalSince1970
        ] as [String: Any]
        
        sendMessageToWatch(message: message, description: "GPU prediction result")
    }
    
    /// Sends GPU processing status to the Apple Watch
    /// - Parameter isProcessing: True if processing started, false if completed
    func sendGPUProcessingStatusToWatch(isProcessing: Bool) {
        let message = [
            "type": "gpu_processing_status",
            "isProcessing": isProcessing,
            "timestamp": Date().timeIntervalSince1970
        ] as [String: Any]
        
        sendMessageToWatch(message: message, description: "GPU processing status")
    }
    
    /// Sends OneSignal notification info to the Apple Watch
    /// - Parameters:
    ///   - title: Notification title
    ///   - body: Notification body
    func sendOneSignalNotificationToWatch(title: String, body: String) {
        let message = [
            "type": "onesignal_notification",
            "title": title,
            "body": body,
            "timestamp": Date().timeIntervalSince1970
        ] as [String: Any]
        
        sendMessageToWatch(message: message, description: "OneSignal notification")
    }
    
    /// Generic method to send messages to watch with proper fallback
    private func sendMessageToWatch(message: [String: Any], description: String) {
        if WCSession.default.isReachable {
            WCSession.default.sendMessage(message, replyHandler: { response in
                print("✅ Watch received \(description)")
            }) { error in
                print("❌ Error sending \(description) to watch: \(error.localizedDescription)")
                // Fallback to background transfer
                WCSession.default.transferUserInfo(message)
                print("📤 Sent \(description) via background transfer")
            }
        } else {
            // Watch not reachable, use background transfer
            WCSession.default.transferUserInfo(message)
            print("📤 Sent \(description) via background transfer")
        }
    }
    
    /// Sends a blood glucose prediction to the Apple Watch
    /// - Parameters:
    ///   - prediction: Prediction value in mmol/L
    ///   - timestamp: When the prediction was made
    func sendPredictionToWatch(prediction: Double, timestamp: Date = Date()) {
        guard WCSession.default.activationState == .activated else {
            print("⚠️ WatchConnectivity not activated")
            return
        }
        
        guard WCSession.default.isPaired else {
            print("⚠️ Apple Watch not paired")
            return
        }
        
        let message = [
            "type": "bg_prediction",
            "prediction_mmol": prediction,
            "prediction_mgdl": prediction * 18.0,
            "timestamp": timestamp.timeIntervalSince1970
        ] as [String: Any]
        
        // Try to send message if watch is reachable
        if WCSession.default.isReachable {
            WCSession.default.sendMessage(message, replyHandler: { response in
                print("✅ Watch received prediction: \(String(format: "%.1f", prediction)) mmol/L")
            }) { error in
                print("❌ Error sending prediction to watch: \(error.localizedDescription)")
                // Fallback to transferUserInfo for background delivery
                self.sendPredictionViaUserInfo(message: message)
            }
        } else {
            // Watch not reachable, use background transfer
            print("📱 Watch not reachable, using background transfer")
            sendPredictionViaUserInfo(message: message)
        }
    }
    
    private func sendPredictionViaUserInfo(message: [String: Any]) {
        WCSession.default.transferUserInfo(message)
        print("📤 Sent prediction via background transfer")
    }
    
    /// Checks if Apple Watch is available for predictions
    /// - Returns: True if watch is paired and app is installed
    func isWatchAvailable() -> Bool {
        return WCSession.default.isPaired && WCSession.default.isWatchAppInstalled
    }
    
    /// Gets watch status information
    /// - Returns: Dictionary with watch status details
    func getWatchStatus() -> [String: Any] {
        return [
            "isSupported": WCSession.isSupported(),
            "isPaired": WCSession.default.isPaired,
            "isWatchAppInstalled": WCSession.default.isWatchAppInstalled,
            "isReachable": WCSession.default.isReachable,
            "activationState": WCSession.default.activationState.rawValue
        ]
    }
}

// MARK: - WCSessionDelegate
extension WatchConnectivityManager: WCSessionDelegate {
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        DispatchQueue.main.async {
            self.isWatchConnected = activationState == .activated
            self.isPaired = session.isPaired
            self.isWatchAppInstalled = session.isWatchAppInstalled
            
            if let error = error {
                print("❌ iPhone WatchConnectivity activation error: \(error.localizedDescription)")
            } else {
                print("✅ iPhone WatchConnectivity activated")
                print("📱 Watch paired: \(session.isPaired)")
                print("⌚ Watch app installed: \(session.isWatchAppInstalled)")
                print("🔗 Watch reachable: \(session.isReachable)")
            }
        }
    }
    
    func sessionDidBecomeInactive(_ session: WCSession) {
        print("📱 WatchConnectivity session became inactive")
    }
    
    func sessionDidDeactivate(_ session: WCSession) {
        print("📱 WatchConnectivity session deactivated")
        // Reactivate the session for iOS
        session.activate()
    }
    
    func sessionWatchStateDidChange(_ session: WCSession) {
        DispatchQueue.main.async {
            self.isPaired = session.isPaired
            self.isWatchAppInstalled = session.isWatchAppInstalled
            print("⌚ Watch state changed - Paired: \(session.isPaired), App installed: \(session.isWatchAppInstalled)")
        }
    }
    
    func session(_ session: WCSession, didReceiveMessage message: [String : Any], replyHandler: @escaping ([String : Any]) -> Void) {
        print("📱 Received message from watch: \(message)")
        
        // Handle different message types from watch
        if let type = message["type"] as? String {
            switch type {
            case "trigger_gpu_prediction":
                // Extract heart rate if available
                let heartRate = message["heart_rate"] as? Double ?? 0.0
                handleGPUPredictionRequest(message: message, heartRate: heartRate, replyHandler: replyHandler)
            default:
                print("⚠️ Unknown message type from watch: \(type)")
                replyHandler(["status": "unknown_type"])
            }
        } else {
            replyHandler(["status": "received"])
        }
    }
    
    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String : Any] = [:]) {
        print("📱 Received background message from watch: \(userInfo)")
        
        // Handle background messages from watch
        if let type = userInfo["type"] as? String {
            switch type {
            case "trigger_gpu_prediction":
                // Extract heart rate if available
                let heartRate = userInfo["heart_rate"] as? Double ?? 0.0
                handleGPUPredictionRequest(message: userInfo, heartRate: heartRate)
            default:
                print("⚠️ Unknown background message type from watch: \(type)")
            }
        }
    }
    
    // MARK: - GPU Prediction Handling
    private func handleGPUPredictionRequest(message: [String: Any], heartRate: Double, replyHandler: (([String: Any]) -> Void)? = nil) {
        // Extract comprehensive health data from Watch message
        let watchInsulin = message["insulin_dose"] as? Double ?? 0.0
        let watchCarbs = message["carb_amount"] as? Double ?? 0.0
        let watchGlucose = message["glucose_value"] as? Double ?? 0.0
        let watchGlucoseTrend = message["glucose_trend"] as? Double ?? 0.0
        let source = message["source"] as? String ?? "watch_button"
        
        print("🧠 === ENHANCED WATCH-TRIGGERED GPU PREDICTION ===")
        print("📊 Received comprehensive health data from Watch:")
        print("   ❤️ Heart Rate: \(heartRate) BPM")
        print("   💉 Insulin: \(watchInsulin) units")
        print("   🍞 Carbs: \(watchCarbs) grams")
        print("   🩸 Glucose: \(watchGlucose) mg/dL")
        print("   📈 Trend: \(String(format: "%.2f", watchGlucoseTrend)) mg/dL/min")
        print("   📱 Source: \(source)")
        
        // Check app state on main thread
        Task { @MainActor in
            print("📱 App state: \(UIApplication.shared.applicationState.rawValue) (0=active, 1=inactive, 2=background)")
        }
        
        // Start background task assertion to prevent app suspension during processing
        self.startBackgroundTaskForWatchRequest()
        
        // Send immediate acknowledgment with enhanced status
        replyHandler?(["success": true, "status": "enhanced_processing_started", "data_received": true])
        
        // Send processing status to watch
        sendGPUProcessingStatusToWatch(isProcessing: true)
        
        // Trigger enhanced prediction process asynchronously
        Task { @MainActor in
            print("🚀 === ENHANCED COMPREHENSIVE WATCH-TRIGGERED PREDICTION ===")
            
            // Step 1: Enhanced sync with Watch data integration
            print("🔄 Step 1/2: Enhanced data sync with Watch integration...")
            var syncResults: (glucose: Int, insulin: Int, carbs: Int, watchDataIntegrated: Bool) = (0, 0, 0, false)
            do {
                syncResults = try await self.performEnhancedWatchDataSync(
                    watchInsulin: watchInsulin,
                    watchCarbs: watchCarbs,
                    watchGlucose: watchGlucose,
                    watchTrend: watchGlucoseTrend
                )
                print("✅ Enhanced sync completed - Glucose: \(syncResults.glucose), Insulin: \(syncResults.insulin), Carbs: \(syncResults.carbs), Watch Data: \(syncResults.watchDataIntegrated)")
            } catch {
                print("❌ Failed to perform enhanced watch data sync: \(error.localizedDescription)")
            }
            
            // Step 2: Execute GPU WaveNet prediction with comprehensive Watch data
            print("🔄 Step 2/2: Executing GPU WaveNet prediction with Watch data...")
            await BackgroundGPUWaveNetService.shared.triggerEnhancedWatchGPUPrediction(
                heartRate: heartRate,
                watchInsulin: watchInsulin,
                watchCarbs: watchCarbs, 
                watchGlucose: watchGlucose,
                watchTrend: watchGlucoseTrend
            )
            
            // Wait a moment for prediction to complete
            do {
                try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
            } catch {
                print("⚠️ Task sleep interrupted: \(error)")
            }
            
            print("✅ GPU prediction execution completed")
            
            // Get the latest prediction result after processing
            let predictionStats = BackgroundGPUWaveNetService.shared.getBackgroundPredictionStats()
            print("📊 Prediction stats after GPU execution: count=\(predictionStats.count), average=\(predictionStats.averageValue)")
            
            if predictionStats.averageValue > 0, let lastPredictionTime = predictionStats.lastPrediction {
                // Convert mg/dL back to mmol/L for watch display
                let predictionMmol = predictionStats.averageValue / 18.0
                print("✅ === COMPREHENSIVE PREDICTION COMPLETE FROM WATCH ===")
                print("📊 Summary:")
                print("   - Glucose sync: \(syncResults.glucose) readings")
                print("   - Insulin cache: \(syncResults.insulin) entries")
                print("   - Carbs cache: \(syncResults.carbs) entries")
                print("   - GPU prediction: \(String(format: "%.1f", predictionMmol)) mmol/L")
                
                // Send comprehensive result to watch
                self.sendGPUPredictionToWatch(
                    prediction: predictionMmol,
                    timestamp: lastPredictionTime
                )
                
                // Send completion status
                self.sendGPUProcessingStatusToWatch(isProcessing: false)
                
                // End background task
                self.endBackgroundTaskForWatchRequest()
            } else {
                print("❌ GPU prediction completed but no result available")
                self.sendGPUProcessingStatusToWatch(isProcessing: false)
                
                // End background task
                self.endBackgroundTaskForWatchRequest()
            }
        }
    }
    
    // MARK: - HealthKit to SwiftData Sync
    /// Sync HealthKit insulin and carb data to SwiftData for background use
    func performHealthKitToSwiftDataSync() async -> (insulin: Int, carbs: Int) {
        print("🍿 === HEALTHKIT TO SWIFTDATA SYNC ===")
        
        guard let modelContainer = await BackgroundGPUWaveNetService.shared.getModelContainer() else {
            print("❌ Model container not available for HealthKit sync")
            return (0, 0)
        }
        
        let modelContext = ModelContext(modelContainer)
        var insulinCount = 0
        var carbsCount = 0
        
        do {
            let healthStore = HKHealthStore()
            
            // Cache HealthKit insulin data to SwiftData (app must be foregrounded)
            print("💉 Caching HealthKit insulin data to SwiftData...")
            
            do {
                // Fetch insulin from HealthKit (last 4 hours)
                let insulinType = HKQuantityType.quantityType(forIdentifier: .insulinDelivery)!
                let fourHoursAgo = Date().addingTimeInterval(-4 * 3600)
                let predicate = HKQuery.predicateForSamples(withStart: fourHoursAgo, end: Date(), options: .strictStartDate)
                
                let insulinSamples: [HKQuantitySample] = try await withCheckedThrowingContinuation { continuation in
                    let query = HKSampleQuery(sampleType: insulinType, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, error in
                        if let error = error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume(returning: samples as? [HKQuantitySample] ?? [])
                        }
                    }
                    healthStore.execute(query)
                }
                
                // Cache insulin samples to SwiftData
                for sample in insulinSamples {
                    let insulinAmount = sample.quantity.doubleValue(for: HKUnit.internationalUnit())
                    let healthKitUUID = sample.uuid.uuidString
                    
                    // Check for existing insulin entry by HealthKit UUID
                    let fetchDescriptor = FetchDescriptor<NightScoutInsulinCache>(
                        predicate: #Predicate<NightScoutInsulinCache> { cache in
                            cache.nightScoutId == healthKitUUID
                        }
                    )
                    
                    let existingInsulin = try modelContext.fetch(fetchDescriptor)
                    if existingInsulin.isEmpty {
                        let insulinCache = NightScoutInsulinCache(
                            timestamp: sample.startDate,
                            insulinAmount: insulinAmount,
                            insulinType: "HealthKit",
                            nightScoutId: healthKitUUID,
                            sourceInfo: sample.sourceRevision.source.name
                        )
                        // Apply initial decay
                        insulinCache.updateDecayedAmount()
                        modelContext.insert(insulinCache)
                        insulinCount += 1
                        print("💉 Cached insulin: \(String(format: "%.2f", insulinAmount)) U at \(sample.startDate.formatted())")
                    }
                }
                
            } catch {
                print("⚠️ Failed to cache HealthKit insulin: \(error.localizedDescription)")
            }
            
            // Cache HealthKit carbohydrate data to SwiftData
            print("🍞 Caching HealthKit carb data to SwiftData...")
            
            do {
                // Fetch carbs from HealthKit (last 5 hours)
                let carbType = HKQuantityType.quantityType(forIdentifier: .dietaryCarbohydrates)!
                let fiveHoursAgo = Date().addingTimeInterval(-5 * 3600)
                let carbPredicate = HKQuery.predicateForSamples(withStart: fiveHoursAgo, end: Date(), options: .strictStartDate)
                
                let carbSamples: [HKQuantitySample] = try await withCheckedThrowingContinuation { continuation in
                    let query = HKSampleQuery(sampleType: carbType, predicate: carbPredicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, error in
                        if let error = error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume(returning: samples as? [HKQuantitySample] ?? [])
                        }
                    }
                    healthStore.execute(query)
                }
                
                // Cache carb samples to SwiftData
                for sample in carbSamples {
                    let carbAmount = sample.quantity.doubleValue(for: HKUnit.gram())
                    let healthKitUUID = sample.uuid.uuidString
                    
                    // Check for existing carb entry by HealthKit UUID
                    let fetchDescriptor = FetchDescriptor<NightScoutCarbCache>(
                        predicate: #Predicate<NightScoutCarbCache> { cache in
                            cache.nightScoutId == healthKitUUID
                        }
                    )
                    
                    let existingCarbs = try modelContext.fetch(fetchDescriptor)
                    if existingCarbs.isEmpty {
                        let carbCache = NightScoutCarbCache(
                            timestamp: sample.startDate,
                            carbAmount: carbAmount,
                            carbType: "HealthKit",
                            nightScoutId: healthKitUUID,
                            sourceInfo: sample.sourceRevision.source.name
                        )
                        // Apply initial decay
                        carbCache.updateDecayedAmount()
                        modelContext.insert(carbCache)
                        carbsCount += 1
                        print("🍞 Cached carbs: \(String(format: "%.1f", carbAmount)) g at \(sample.startDate.formatted())")
                    }
                }
                
            } catch {
                print("⚠️ Failed to cache HealthKit carbs: \(error.localizedDescription)")
            }
            
            // Save all changes
            do {
                try modelContext.save()
                print("✅ HealthKit sync completed - Insulin: \(insulinCount), Carbs: \(carbsCount)")
            } catch {
                print("❌ Failed to save HealthKit sync changes: \(error.localizedDescription)")
            }
            
        } catch {
            print("❌ HealthKit sync failed: \(error.localizedDescription)")
        }
        
        return (insulinCount, carbsCount)
    }
    
    // MARK: - Enhanced Watch Data Sync
    /// Performs enhanced sync integrating Watch data with NightScout and HealthKit data
    /// - Parameters:
    ///   - watchInsulin: Insulin dose from Watch HealthKit
    ///   - watchCarbs: Carb amount from Watch HealthKit
    ///   - watchGlucose: Glucose value from Watch HealthKit
    ///   - watchTrend: Glucose trend from Watch HealthKit
    /// - Returns: Enhanced sync results with Watch data integration status
    @MainActor
    private func performEnhancedWatchDataSync(
        watchInsulin: Double,
        watchCarbs: Double, 
        watchGlucose: Double,
        watchTrend: Double
    ) async -> (glucose: Int, insulin: Int, carbs: Int, watchDataIntegrated: Bool) {
        print("🔄 === ENHANCED WATCH DATA SYNC STARTED ===")
        
        // First, perform the standard comprehensive sync
        let standardSync = await performComprehensiveNightScoutSync()
        
        // Then, integrate Watch data if available and recent
        var watchDataIntegrated = false
        
        do {
            let modelContainer = try ModelContainer(for: HealthKitBGCache.self, NightScoutInsulinCache.self, NightScoutCarbCache.self)
            let context = ModelContext(modelContainer)
            let currentTime = Date()
            
            // Integrate Watch insulin data if significant
            if watchInsulin > 0.1 {
                let watchInsulinEntry = NightScoutInsulinCache(
                    timestamp: currentTime,
                    insulinAmount: watchInsulin,
                    insulinType: "rapid",
                    nightScoutId: "watch-\(UUID().uuidString)",
                    sourceInfo: "Watch-Enhanced"
                )
                context.insert(watchInsulinEntry)
                print("💉 Integrated Watch insulin: \(watchInsulin) units")
                watchDataIntegrated = true
            }
            
            // Integrate Watch carb data if significant
            if watchCarbs > 1.0 {
                let watchCarbEntry = NightScoutCarbCache(
                    timestamp: currentTime,
                    carbAmount: watchCarbs,
                    carbType: "meal",
                    nightScoutId: "watch-carb-\(UUID().uuidString)",
                    sourceInfo: "Watch-Enhanced"
                )
                context.insert(watchCarbEntry)
                print("🍞 Integrated Watch carbs: \(watchCarbs) grams")
                watchDataIntegrated = true
            }
            
            // Integrate Watch glucose data if significant and recent
            if watchGlucose > 50.0 {
                let watchBGEntry = HealthKitBGCache(
                    timestamp: currentTime,
                    bloodGlucose_mmol: watchGlucose / 18.0, // Convert mg/dL to mmol/L
                    healthKitUUID: "watch-bg-\(UUID().uuidString)",
                    sourceInfo: "Watch-Enhanced-BG"
                )
                context.insert(watchBGEntry)
                print("🩸 Integrated Watch glucose: \(watchGlucose) mg/dL (trend: \(String(format: "%.2f", watchTrend)))")
                watchDataIntegrated = true
            }
            
            // Save integrated Watch data
            if watchDataIntegrated {
                do {
                    try context.save()
                    print("✅ Watch data integration completed and saved")
                } catch {
                    print("❌ Failed to save Watch data integration: \(error.localizedDescription)")
                }
            } else {
                print("ℹ️ No significant Watch data to integrate")
            }
            
        } catch {
            print("❌ Error integrating Watch data: \(error)")
        }
        
        print("🔄 === ENHANCED WATCH DATA SYNC COMPLETED ===")
        return (glucose: standardSync.glucose, insulin: standardSync.insulin, carbs: standardSync.carbs, watchDataIntegrated: watchDataIntegrated)
    }
    
    // MARK: - NightScout API Integration
    /// Fetch fresh data directly from NightScout API and cache to SwiftData
    /// This provides a robust, HealthKit-independent data source for predictions
    private func performComprehensiveNightScoutSync() async -> (glucose: Int, insulin: Int, carbs: Int) {
        print("🔍 === COMPREHENSIVE NIGHTSCOUT SYNC METHOD CALLED ===")
        
        guard let modelContainer = await BackgroundGPUWaveNetService.shared.getModelContainer() else {
            print("❌ Model container not available for comprehensive sync")
            return (0, 0, 0)
        }
        
        let modelContext = ModelContext(modelContainer)
        var glucoseCount = 0
        var insulinCount = 0
        var carbsCount = 0
        
        do {
            // Create NightScout service instance
            // Read Nightscout settings using the same keys persisted from the main app SettingsView
            // Fallback to legacy snake_case keys for backward-compatibility
            let baseURLString = UserDefaults.standard.string(forKey: "nightscoutBaseURL") ??
                                UserDefaults.standard.string(forKey: "nightscout_base_url") ?? ""
            let apiSecret = UserDefaults.standard.string(forKey: "apiSecret") ??
                            UserDefaults.standard.string(forKey: "nightscout_api_secret") ?? ""
            let apiToken  = UserDefaults.standard.string(forKey: "apiToken") ??
                            UserDefaults.standard.string(forKey: "nightscout_api_token") ?? ""
            
            guard let baseURL = URL(string: baseURLString), !baseURLString.isEmpty else {
                print("❌ NightScout base URL not configured - skipping glucose sync")
                return (0, 0, 0)
            }
            
            let nightScoutService = NightscoutService(baseURL: baseURL, apiSecret: apiSecret, apiToken: apiToken)
            
                print("📱 App is active - fetching HealthKit insulin data")
                do {
                    // Fetch insulin from HealthKit (last 4 hours)
                    let insulinType = HKQuantityType.quantityType(forIdentifier: .insulinDelivery)!
                    let fourHoursAgo = Date().addingTimeInterval(-4 * 3600)
                    let predicate = HKQuery.predicateForSamples(withStart: fourHoursAgo, end: Date(), options: .strictStartDate)
                
                let insulinSamples: [HKQuantitySample] = try await withCheckedThrowingContinuation { continuation in
                    let query = HKSampleQuery(sampleType: insulinType, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, error in
                        if let error = error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume(returning: samples as? [HKQuantitySample] ?? [])
                        }
                    }
                    healthStore.execute(query)
                }
                
                // Cache insulin samples to SwiftData
                for sample in insulinSamples {
                    let insulinAmount = sample.quantity.doubleValue(for: HKUnit.internationalUnit())
                    let healthKitUUID = sample.uuid.uuidString
                    
                    // Check for existing insulin entry by HealthKit UUID
                    let fetchDescriptor = FetchDescriptor<NightScoutInsulinCache>(
                        predicate: #Predicate<NightScoutInsulinCache> { cache in
                            cache.nightScoutId == healthKitUUID
                        }
                    )
                    
                    let existingInsulin = try modelContext.fetch(fetchDescriptor)
                    if existingInsulin.isEmpty {
                        let insulinCache = NightScoutInsulinCache(
                            timestamp: sample.startDate,
                            insulinAmount: insulinAmount,
                            insulinType: "HealthKit",
                            nightScoutId: healthKitUUID, // Use HealthKit UUID as ID
                            sourceInfo: sample.sourceRevision.source.name
                        )
                        // Apply initial decay
                        insulinCache.updateDecayedAmount()
                        modelContext.insert(insulinCache)
                        insulinCount += 1
                        print("💉 Cached insulin: \(String(format: "%.2f", insulinAmount)) U at \(sample.startDate.formatted())")
                    }
                }
                
            } catch {
                print("⚠️ Failed to cache HealthKit insulin: \(error.localizedDescription)")
            }
            
            // 3. Cache HealthKit carbohydrate data to SwiftData (only when app is active)
            print("🍞 Checking HealthKit carb data availability...")
            let appState = await UIApplication.shared.applicationState
            if appState == .active {
                print("📱 App is active - fetching HealthKit carb data")
                do {
                    // Fetch carbs from HealthKit (last 5 hours)
                    let carbType = HKQuantityType.quantityType(forIdentifier: .dietaryCarbohydrates)!
                    let fiveHoursAgo = Date().addingTimeInterval(-5 * 3600)
                    let carbPredicate = HKQuery.predicateForSamples(withStart: fiveHoursAgo, end: Date(), options: .strictStartDate)
                
                let carbSamples: [HKQuantitySample] = try await withCheckedThrowingContinuation { continuation in
                    let query = HKSampleQuery(sampleType: carbType, predicate: carbPredicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, error in
                        if let error = error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume(returning: samples as? [HKQuantitySample] ?? [])
                        }
                    }
                    healthStore.execute(query)
                }
                
                // Cache carb samples to SwiftData
                for sample in carbSamples {
                    let carbAmount = sample.quantity.doubleValue(for: HKUnit.gram())
                    let healthKitUUID = sample.uuid.uuidString
                    
                    // Check for existing carb entry by HealthKit UUID
                    let fetchDescriptor = FetchDescriptor<NightScoutCarbCache>(
                        predicate: #Predicate<NightScoutCarbCache> { cache in
                            cache.nightScoutId == healthKitUUID
                        }
                    )
                    
                    let existingCarbs = try modelContext.fetch(fetchDescriptor)
                    if existingCarbs.isEmpty {
                        let carbCache = NightScoutCarbCache(
                            timestamp: sample.startDate,
                            carbAmount: carbAmount,
                            carbType: "HealthKit",
                            nightScoutId: healthKitUUID, // Use HealthKit UUID as ID
                            sourceInfo: sample.sourceRevision.source.name
                        )
                        // Apply initial decay
                        carbCache.updateDecayedAmount()
                        modelContext.insert(carbCache)
                        carbsCount += 1
                        print("🍞 Cached carbs: \(String(format: "%.1f", carbAmount)) g at \(sample.startDate.formatted())")
                    }
                }
                
                } catch {
                    print("⚠️ Failed to cache HealthKit carbs: \(error.localizedDescription)")
                }
            } else {
                print("📱 App is backgrounded - skipping HealthKit carb fetch to prevent hanging")
            }
            
            // Save all changes
            do {
                try modelContext.save()
                print("✅ Comprehensive sync completed - Glucose: \(glucoseCount), Insulin: \(insulinCount), Carbs: \(carbsCount)")
            } catch {
                print("❌ Failed to save comprehensive sync changes: \(error.localizedDescription)")
            }
            
        } catch {
            print("❌ Comprehensive sync failed: \(error.localizedDescription)")
        }
        
        return (glucoseCount, insulinCount, carbsCount)
    }
    
    private func performNightScoutToSwiftDataSync() async -> Int {
        print("🔍 === NIGHTSCOUT API SYNC METHOD CALLED ===")
        print("🌙 === STARTING NIGHTSCOUT API SYNC DEBUG ===")
        
        do {
            print("🔍 Checking model container availability...")
            guard let modelContainer = await BackgroundGPUWaveNetService.shared.getModelContainer() else {
                print("❌ Model container not available for NightScout sync")
                print("🔍 This is likely the cause of missing NightScout API sync!")
                return 0
            }
            print("✅ Model container obtained successfully")
            let modelContext = ModelContext(modelContainer)
            
            // Get NightScout API configuration with detailed logging
            let defs = UserDefaults.standard
            let baseURLString = defs.string(forKey: "nightscoutBaseURL") ?? ""
            let apiSecret = defs.string(forKey: "apiSecret") ?? ""
            let apiToken = defs.string(forKey: "apiToken") ?? ""
            
            print("🔍 NightScout Configuration:")
            print("   Base URL: \(baseURLString.isEmpty ? "MISSING" : "✅ Set")")
            print("   API Secret: \(apiSecret.isEmpty ? "MISSING" : "✅ Set")")
            print("   API Token: \(apiToken.isEmpty ? "MISSING" : "✅ Set")")
            
            guard let baseURL = URL(string: baseURLString), !baseURLString.isEmpty else {
                print("❌ NightScout base URL not configured - skipping API sync")
                return 0
            }
            
            let nightScoutService = NightscoutService(baseURL: baseURL, apiSecret: apiSecret, apiToken: apiToken)
            print("✅ NightScout service initialized")
            
            // Check app state and network availability
            await Task { @MainActor in
                let appState = UIApplication.shared.applicationState
                print("📱 Current app state: \(appState.rawValue) (0=active, 1=inactive, 2=background)")
            }.value
            
            print("📥 Fetching 24 hours of glucose data from NightScout API...")
            print("🕐 Current time: \(Date())")
            print("💡 ML models require 24×8 input window (120 minutes), fetching 24h for sufficient context")
            
            let startTime = Date()
            let entries = try await nightScoutService.fetchGlucoseData(minutes: 1440) // 24 hours = 1440 minutes
            let fetchDuration = Date().timeIntervalSince(startTime)
            
            print("⏱️ API fetch completed in \(String(format: "%.2f", fetchDuration))s")
            
            guard !entries.isEmpty else {
                print("❌ No fresh glucose data available from NightScout API")
                print("🔍 This could indicate:")
                print("   - Network connectivity issues in background")
                print("   - API authentication problems")
                print("   - No recent data on NightScout server")
                return 0
            }
            
            print("📊 Fetched \(entries.count) entries from NightScout API")
            if let firstEntry = entries.first, let lastEntry = entries.last {
                let formatter = DateFormatter()
                formatter.timeStyle = .short
                print("🕒 Earliest: \(formatter.string(from: firstEntry.date)) - \(Int(firstEntry.sgv)) mg/dL")
                print("🕒 Latest: \(formatter.string(from: lastEntry.date)) - \(Int(lastEntry.sgv)) mg/dL")
            }
            
            // Cache entries directly to SwiftData
            print("💾 Caching entries to SwiftData...")
            var savedCount = 0
            var skippedCount = 0
            
            for entry in entries {
                // Validate glucose value to prevent corrupted data
                guard isValidGlucoseValue(mgdl: entry.sgv) else {
                    print("⚠️ Skipping invalid glucose value: \(entry.sgv) mg/dL")
                    continue
                }
                
                // Check if entry already exists in cache (with timestamp tolerance)
                let timeWindow: TimeInterval = 30 // 30 seconds tolerance
                let startTime = entry.date.addingTimeInterval(-timeWindow)
                let endTime = entry.date.addingTimeInterval(timeWindow)
                
                let fetchDescriptor = FetchDescriptor<HealthKitBGCache>(
                    predicate: #Predicate<HealthKitBGCache> { cache in
                        cache.timestamp >= startTime && cache.timestamp <= endTime
                    }
                )
                
                do {
                    let existingEntries = try modelContext.fetch(fetchDescriptor)
                    
                    if existingEntries.isEmpty {
                        // Create new cache entry from NightScout data
                        let mmolValue = entry.sgv / 18.0
                        let cacheEntry = HealthKitBGCache(
                            timestamp: entry.date,
                            bloodGlucose_mmol: mmolValue,
                            healthKitUUID: "NS-Watch-\(UUID().uuidString)",
                            sourceInfo: "NightScout API (Watch-triggered)"
                        )
                        
                        modelContext.insert(cacheEntry)
                        savedCount += 1
                        print("✅ Cached: \(String(format: "%.1f", mmolValue)) mmol/L at \(entry.date)")
                    } else {
                        skippedCount += 1
                        print("⏭️ Skipped duplicate within \(Int(timeWindow))s: \(String(format: "%.1f", entry.sgv)) mg/dL")
                    }
                } catch {
                    print("⚠️ Error checking/saving entry: \(error)")
                }
            }
            
            // Save all changes
            try modelContext.save()
            
            print("✅ NightScout API sync complete: \(savedCount) new, \(skippedCount) existing")
            return savedCount
            
        } catch {
            print("❌ === NIGHTSCOUT API SYNC FAILED ===")
            print("❌ Error: \(error.localizedDescription)")
            print("❌ Full error: \(error)")
            
            // Specific error analysis
            if let urlError = error as? URLError {
                print("🌐 Network Error Code: \(urlError.code.rawValue)")
                switch urlError.code {
                case .notConnectedToInternet:
                    print("🔍 Cause: Device not connected to internet")
                case .networkConnectionLost:
                    print("🔍 Cause: Network connection lost during request")
                case .timedOut:
                    print("🔍 Cause: Request timed out (common in background)")
                case .cannotConnectToHost:
                    print("🔍 Cause: Cannot connect to NightScout server")
                default:
                    print("🔍 Cause: Other network error - \(urlError.localizedDescription)")
                }
            }
            
            return 0
        }
    }
    
    /// Validates glucose values to prevent corrupted data
    private func isValidGlucoseValue(mgdl: Double) -> Bool {
        // Valid glucose range: 20-600 mg/dL (1.1-33.3 mmol/L)
        // Most CGM readings are between 40-400 mg/dL (2.2-22.2 mmol/L)
        let minValue: Double = 20
        let maxValue: Double = 600
        
        guard mgdl >= minValue && mgdl <= maxValue else {
            print("❌ Glucose value out of range: \(mgdl) mg/dL (valid: \(minValue)-\(maxValue) mg/dL)")
            return false
        }
        
        guard !mgdl.isNaN && !mgdl.isInfinite else {
            print("❌ Invalid glucose value: NaN or Infinite")
            return false
        }
        
        return true
    }
}

// MARK: - Background Task Management & App State
extension WatchConnectivityManager {
    
    func startBackgroundTaskForWatchRequest() {
        backgroundTaskQueue.async {
            DispatchQueue.main.async {
                // End any existing background task
                self.endBackgroundTaskForWatchRequest()
                
                // Start new background task
                self.backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "WatchGPUPrediction") {
                    print("⏰ Background task for Watch GPU prediction expired - ending task")
                    self.endBackgroundTaskForWatchRequest()
                }
                
                if self.backgroundTaskID != .invalid {
                    print("✅ Started background task for Watch GPU prediction (ID: \(self.backgroundTaskID.rawValue))")
                } else {
                    print("❌ Failed to start background task for Watch GPU prediction")
                }
            }
        }
    }
    
    func endBackgroundTaskForWatchRequest() {
        backgroundTaskQueue.async {
            DispatchQueue.main.async {
                if self.backgroundTaskID != .invalid {
                    print("🏁 Ending background task for Watch GPU prediction (ID: \(self.backgroundTaskID.rawValue))")
                    UIApplication.shared.endBackgroundTask(self.backgroundTaskID)
                    self.backgroundTaskID = .invalid
                } else {
                    print("ℹ️ No background task to end for Watch GPU prediction")
                }
            }
        }
    }
    
    // MARK: - App State Monitoring
    func checkAppSuspendedState() -> Bool {
        let appState = UIApplication.shared.applicationState
        switch appState {
        case .active:
            print("📱 App state: Active - full processing available")
            return false
        case .inactive:
            print("📱 App state: Inactive - transitioning, processing available")
            return false
        case .background:
            print("📱 App state: Background - limited processing time")
            return false
        @unknown default:
            print("📱 App state: Unknown - treating as suspended")
            return true
        }
    }
}

