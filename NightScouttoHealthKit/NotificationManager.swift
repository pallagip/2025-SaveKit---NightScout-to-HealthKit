import Foundation
import UserNotifications
import SwiftData
import BackgroundTasks

class NotificationManager: ObservableObject {
    static let shared = NotificationManager()
    
    private init() {}
    
    // Initialize background automation without notifications
    func initializeBackgroundAutomation() {
        print("⚙️ Initializing background automation (no notifications required)")
        
        // Start background task scheduling immediately
        scheduleBackgroundTasks()
        
        print("✅ Background automation initialized - predictions will run automatically every 15 minutes")
        print("🔄 Schedule: 9:00-23:45 CET (68 prediction cycles daily)")
        print("🦖 Process: Fetch → Cache → Predict (all automatic, no user interaction needed)")
    }
    
    // Schedule all notifications for the specified times
    func scheduleHourlyNotifications() {
        // Clear existing notifications first
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        
        // Define the hours (9 AM to 11:45 PM = 23:45)
        let hours = Array(9...23)
        
        // Define the minutes (:00, :15, :30, :45)
        let minutes = [0, 15, 30, 45]
        
        var notificationCount = 0
        
        for hour in hours {
            for minute in minutes {
                scheduleNotification(hour: hour, minute: minute)
                notificationCount += 1
            }
        }
        
        print("📅 Scheduled \(notificationCount) notifications from 9:00 to 23:45 every 15 minutes")
    }
    
    // Schedule a single silent background trigger for a specific time
    private func scheduleNotification(hour: Int, minute: Int) {
        let content = UNMutableNotificationContent()
        content.title = "Background Prediction Trigger"
        content.body = "Silent trigger for background prediction"
        content.sound = nil // No sound
        content.badge = 0 // No badge
        
        // Make this a silent background trigger
        content.categoryIdentifier = "BACKGROUND_PREDICTION"
        
        // Create date components for Central European Time
        var dateComponents = DateComponents()
        dateComponents.timeZone = TimeZone(identifier: "Europe/Berlin") // Central European Time
        dateComponents.hour = hour
        dateComponents.minute = minute
        dateComponents.second = 0
        
        // Create trigger that repeats daily at the specified time
        let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: true)
        
        // Create unique identifier for each notification
        let identifier = "prediction_trigger_\(hour)_\(minute)"
        
        // Create the request
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        
        // Add the request to the notification center
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("❌ Error scheduling background trigger for \(hour):\(String(format: "%02d", minute)): \(error.localizedDescription)")
            } else {
                print("✅ Scheduled background prediction trigger for \(hour):\(String(format: "%02d", minute)) CET")
            }
        }
    }
    
    // MARK: - Background Prediction Process
    
    /// Performs the complete prediction process: sync data, cache, and predict
    /// This method is designed to be called from background notification triggers
    /// - Parameter modelContext: SwiftData model context for data operations
    /// - Returns: Average prediction value in mmol/L, or nil if process failed
    @MainActor
    func performBackgroundPredictionProcess(modelContext: ModelContext) async -> Double? {
        print("🔔 === BACKGROUND PREDICTION PROCESS STARTED ===")
        let startTime = Date()
        
        do {
            // Step 1: Sync Data for 24 hours (max 12 seconds)
            print("📥 Step 1: Starting data sync for 24 hours...")
            let syncStartTime = Date()
            
            let syncResult = await withTimeout(seconds: 12) {
                return await SyncManager.shared.performSync(isBackground: true, extended: false, minutes: 1440) // 24 hours = 1440 minutes
            }
            
            let syncDuration = Date().timeIntervalSince(syncStartTime)
            print("📥 Data sync completed in \(String(format: "%.1f", syncDuration))s")
            
            guard let syncedCount = syncResult else {
                print("❌ Data sync timed out after 12 seconds")
                return nil
            }
            
            print("✅ Synced \(syncedCount) new entries from NightScout")
            
            // Step 2: Convert HealthKit Values to SwiftData Cache (max 4 seconds)
            print("🔄 Step 2: Converting HealthKit values to SwiftData cache...")
            let cacheStartTime = Date()
            
            let cacheResult = await withTimeout(seconds: 4) {
                do {
                    return try await HealthKitBGSyncService.shared.syncHealthKitBGToCache(
                        modelContext: modelContext,
                        hoursBack: 24.0
                    )
                } catch {
                    print("❌ Cache sync error: \(error.localizedDescription)")
                    return nil
                }
            }
            
            let cacheDuration = Date().timeIntervalSince(cacheStartTime)
            print("🔄 Cache sync completed in \(String(format: "%.1f", cacheDuration))s")
            
            guard let cachedCount = cacheResult else {
                print("❌ Cache sync timed out after 4 seconds")
                return nil
            }
            
            print("✅ Cached \(cachedCount) new BG readings")
            
            // Step 3: Run Predictions with all WaveNet models (max 5 seconds)
            print("🔮 Step 3: Running predictions with all WaveNet models...")
            let predictionStartTime = Date()
            
            let predictionResult = await withTimeout(seconds: 5) {
                do {
                    let bgService = BGPredictionService()
                    let (_, modelPredictions) = try await bgService.createPredictionWithModelResults(
                        useMgdl: false, // Use mmol/L for consistency
                        modelContext: modelContext
                    )
                    return modelPredictions
                } catch {
                    print("❌ Prediction error: \(error.localizedDescription)")
                    return nil
                }
            }
            
            let predictionDuration = Date().timeIntervalSince(predictionStartTime)
            print("🔮 Predictions completed in \(String(format: "%.1f", predictionDuration))s")
            
            guard let modelPredictions = predictionResult else {
                print("❌ Predictions timed out after 5 seconds")
                return nil
            }
            
            // Calculate average prediction from all 5 WaveNet models
            let validPredictions = modelPredictions.values.compactMap { prediction in
                prediction.modelOutput // Always in mmol/L
            }
            
            guard !validPredictions.isEmpty else {
                print("❌ No valid predictions received from models")
                return nil
            }
            
            let averagePrediction = validPredictions.reduce(0, +) / Double(validPredictions.count)
            
            // Save the average prediction to SwiftData for Prediction History and CSV export
            await saveAveragePredictionToSwiftData(
                averagePrediction: averagePrediction,
                modelPredictions: modelPredictions,
                modelContext: modelContext
            )
            
            let totalDuration = Date().timeIntervalSince(startTime)
            print("🔔 === BACKGROUND PREDICTION PROCESS COMPLETED ===")
            print("📊 Total process time: \(String(format: "%.1f", totalDuration))s")
            print("📊 Models used: \(validPredictions.count)")
            print("📊 Average prediction: \(String(format: "%.1f", averagePrediction)) mmol/L")
            
            return averagePrediction
            
        } catch {
            print("❌ Background prediction process failed: \(error.localizedDescription)")
            return nil
        }
    }
    
    /// Saves the average prediction to SwiftData for Prediction History and CSV export
    /// - Parameters:
    ///   - averagePrediction: Average prediction value in mmol/L
    ///   - modelPredictions: Dictionary of individual model predictions
    ///   - modelContext: SwiftData model context
    @MainActor
    private func saveAveragePredictionToSwiftData(
        averagePrediction: Double,
        modelPredictions: [Int: Prediction],
        modelContext: ModelContext
    ) async {
        do {
            // Get current blood glucose for context (we need this for the Prediction record)
            let hk = HealthKitFeatureProvider()
            let currentBG = try await hk.fetchLatestGlucoseValue() // Always in mg/dL from HealthKit
            
            // Calculate stability status (simplified for background process)
            let recentReadings = try await hk.fetchRecentGlucoseValues(limit: 3)
            let momentum = calculateMomentum(from: recentReadings)
            let stabilityStatus = determineStabilityStatus(momentum: momentum)
            
            // Calculate the next prediction count for the new prediction
            let bgService = BGPredictionService()
            let nextPredictionCount = bgService.calculateNextPredictionCount(modelContext: modelContext)
            
            // Create and save the average prediction as a SwiftData object
            let timestamp = Date()
            let predictionRecord = Prediction(
                timestamp: timestamp,
                predictionValue: averagePrediction, // Always store in mmol/L
                usedMgdlUnits: false, // Background predictions always use mmol/L internally
                currentBG: currentBG / 18.0, // Always store currentBG in mmol/L
                stabilityStatus: stabilityStatus,
                modelOutput: averagePrediction, // Always store modelOutput in mmol/L
                modelPredictedChange: 0.0,
                observedTrend: 0.0,
                modelWeight: 0.0,
                trendWeight: 0.0,
                finalPredictedChange: 0.0,
                actualBG: 0.0,
                actualBGTimestamp: nil,
                modelIndex: 0, // 0 indicates this is an average prediction
                isAveragePrediction: true,
                note: "Background notification: Average of \(modelPredictions.count) WaveNet models",
                predictionCount: nextPredictionCount
            )
            
            // Save to SwiftData
            modelContext.insert(predictionRecord)
            
            // Try to save the context to ensure data persistence
            try modelContext.save()
            print("✅ Successfully saved background prediction to SwiftData (ID: \(predictionRecord.id), Count: \(nextPredictionCount))")
            
        } catch {
            print("❌ Failed to save background prediction to SwiftData: \(error.localizedDescription)")
        }
    }
    
    /// Helper method to calculate glucose momentum (trend) for background predictions
    private func calculateMomentum(from readings: [Double]) -> Double {
        guard readings.count >= 2 else { return 0.0 }
        
        // Calculate the rate of change between the most recent readings
        let recent = readings[0]
        let previous = readings[1]
        
        // Return change in mg/dL per minute (approximate)
        return (recent - previous) / 5.0 // Assuming 5-minute intervals
    }
    
    /// Helper method to determine stability status based on momentum for background predictions
    private func determineStabilityStatus(momentum: Double) -> String {
        let threshold = 1.0 // mg/dL per minute
        
        if abs(momentum) < threshold {
            return "STABLE"
        } else if momentum > 0 {
            return "RISING"
        } else {
            return "FALLING"
        }
    }
    
    /// Sends a notification with the average prediction result
    /// - Parameters:
    ///   - averagePrediction: Average prediction value in mmol/L
    ///   - identifier: Notification identifier to update
    func sendPredictionNotification(averagePrediction: Double, identifier: String) {
        let content = UNMutableNotificationContent()
        content.title = "Blood Glucose Prediction"
        
        // Format prediction in both units
        let predictionMgdl = averagePrediction * 18.0
        content.body = "Average: \(String(format: "%.1f", averagePrediction)) mmol/L (\(String(format: "%.0f", predictionMgdl)) mg/dL)"
        
        content.sound = nil // No sound as requested
        content.badge = 0
        
        // Create immediate trigger
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        
        // Create the request with updated identifier
        let request = UNNotificationRequest(identifier: "\(identifier)_result", content: content, trigger: trigger)
        
        // Send the notification
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("❌ Error sending prediction notification: \(error.localizedDescription)")
            } else {
                print("✅ Sent prediction notification: \(String(format: "%.1f", averagePrediction)) mmol/L")
            }
        }
    }
    
    /// Sends a failure notification when the prediction process fails
    /// - Parameter identifier: Notification identifier to update
    func sendFailureNotification(identifier: String) {
        let content = UNMutableNotificationContent()
        content.title = "Blood Glucose Prediction"
        content.body = "Prediction unavailable - please check app"
        content.sound = nil // No sound as requested
        content.badge = 0
        
        // Create immediate trigger
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        
        // Create the request with updated identifier
        let request = UNNotificationRequest(identifier: "\(identifier)_failure", content: content, trigger: trigger)
        
        // Send the notification
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("❌ Error sending failure notification: \(error.localizedDescription)")
            } else {
                print("⚠️ Sent failure notification")
            }
        }
    }
    
    // MARK: - Utility Functions
    
    /// Executes an async operation with a timeout
    /// - Parameters:
    ///   - seconds: Timeout duration in seconds
    ///   - operation: The async operation to execute
    /// - Returns: The result of the operation, or nil if timeout occurred
    private func withTimeout<T>(seconds: Double, operation: @escaping () async -> T?) async -> T? {
        return await withTaskGroup(of: T?.self) { group in
            // Add the main operation
            group.addTask {
                return await operation()
            }
            
            // Add the timeout task
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            
            // Return the first result (either completion or timeout)
            let result = await group.next()
            group.cancelAll()
            return result ?? nil
        }
    }
    
    // Check current notification status
    func checkNotificationStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async {
                switch settings.authorizationStatus {
                case .authorized:
                    print("📱 Notifications are authorized")
                case .denied:
                    print("🚫 Notifications are denied")
                case .notDetermined:
                    print("❓ Notification permission not determined")
                case .provisional:
                    print("⚠️ Notifications are provisional")
                case .ephemeral:
                    print("⏰ Notifications are ephemeral")
                @unknown default:
                    print("❓ Unknown notification status")
                }
            }
        }
    }
    
    // Get count of pending notifications
    func getPendingNotificationCount() {
        UNUserNotificationCenter.current().getPendingNotificationRequests { requests in
            print("📊 Pending notifications: \(requests.count)")
            
            // Debug: Print all scheduled times
            let sortedRequests = requests.sorted { req1, req2 in
                guard let trigger1 = req1.trigger as? UNCalendarNotificationTrigger,
                      let trigger2 = req2.trigger as? UNCalendarNotificationTrigger,
                      let hour1 = trigger1.dateComponents.hour,
                      let minute1 = trigger1.dateComponents.minute,
                      let hour2 = trigger2.dateComponents.hour,
                      let minute2 = trigger2.dateComponents.minute else {
                    return false
                }
                
                if hour1 != hour2 {
                    return hour1 < hour2
                }
                return minute1 < minute2
            }
            
            for request in sortedRequests {
                if let trigger = request.trigger as? UNCalendarNotificationTrigger,
                   let hour = trigger.dateComponents.hour,
                   let minute = trigger.dateComponents.minute {
                    print("⏰ Scheduled: \(hour):\(String(format: "%02d", minute)) CET")
                }
            }
        }
    }
    
    // Cancel all notifications
    func cancelAllNotifications() {
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        print("🗑️ All notifications cancelled")
    }
    
    // MARK: - Background Task Scheduling
    
    /// Schedules background app refresh tasks for automatic predictions
    /// Runs 24 hours a day at each quarter of the hour (:00, :15, :30, :45)
    func scheduleBackgroundTasks() {
        // Calculate next quarter-hour mark (:00, :15, :30, :45) - runs 24/7
        let now = Date()
        let calendar = Calendar.current
        let currentMinute = calendar.component(.minute, from: now)
        let currentSecond = calendar.component(.second, from: now)
        
        // Find next quarter-hour
        let minutesToNextQuarter = (15 - (currentMinute % 15)) % 15
        let secondsToNextQuarter = (minutesToNextQuarter * 60) - currentSecond
        let nextQuarterHour = now.addingTimeInterval(TimeInterval(max(60, secondsToNextQuarter))) // At least 1 minute from now
        
        // Schedule app refresh task for next quarter-hour
        let refreshRequest = BGAppRefreshTaskRequest(identifier: "com.ProDiabeticsTeam.NightScouttoHealthKitv1")
        refreshRequest.earliestBeginDate = nextQuarterHour
        
        do {
            try BGTaskScheduler.shared.submit(refreshRequest)
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss"
            print("✅ Scheduled background app refresh for \(formatter.string(from: nextQuarterHour))")
        } catch {
            print("❌ Failed to schedule background app refresh: \(error.localizedDescription)")
        }
        
        // Schedule processing task for hourly extended sync
        let minutesToNextHour = 60 - currentMinute
        let secondsToNextHour = (minutesToNextHour * 60) - currentSecond
        let nextHour = now.addingTimeInterval(TimeInterval(secondsToNextHour))
        
        let processingRequest = BGProcessingTaskRequest(identifier: "com.ProDiabeticsTeam.NightScouttoHealthKit.processing")
        processingRequest.earliestBeginDate = nextHour
        processingRequest.requiresNetworkConnectivity = true
        processingRequest.requiresExternalPower = false
        
        do {
            try BGTaskScheduler.shared.submit(processingRequest)
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss"
            print("✅ Scheduled background processing for \(formatter.string(from: nextHour))")
        } catch {
            print("❌ Failed to schedule background processing: \(error.localizedDescription)")
        }
    }
    
    /// Handles background app refresh task execution
    /// This is called by the system when the background task fires
    func handleBackgroundAppRefresh(task: BGAppRefreshTask, modelContainer: ModelContainer) {
        print("🔄 === BACKGROUND APP REFRESH TASK STARTED ===")
        
        // Schedule the next background task
        scheduleBackgroundTasks()
        
        // Set expiration handler
        task.expirationHandler = {
            print("⏰ Background app refresh task expired")
            task.setTaskCompleted(success: false)
        }
        
        // Check if we should run predictions based on current time
        let calendar = Calendar.current
        let now = Date()
        let hour = calendar.component(.hour, from: now)
        let minute = calendar.component(.minute, from: now)
        
        // Only run during prediction hours (9-23) and near quarter-hour intervals
        guard hour >= 9 && hour <= 23 else {
            print("🔄 Outside prediction hours (9-23), scheduling next task")
            task.setTaskCompleted(success: true)
            return
        }
        
        let validMinutes = [0, 15, 30, 45]
        let isValidTime = validMinutes.contains { abs(minute - $0) <= 5 } // 5-minute tolerance
        
        guard isValidTime else {
            print("🔄 Not near quarter-hour interval, scheduling next task")
            task.setTaskCompleted(success: true)
            return
        }
        
        print("🔄 Running background prediction at \(hour):\(String(format: "%02d", minute))")
        
        // Run the automated fetch → cache → predict process
        Task {
            let modelContext = ModelContext(modelContainer)
            let averagePrediction = await performBackgroundPredictionProcess(modelContext: modelContext)
            
            if let prediction = averagePrediction {
                print("✅ Automated prediction cycle completed successfully at \(hour):\(String(format: "%02d", minute))")
                print("🩸 Average prediction: \(String(format: "%.1f", prediction)) mmol/L (\(String(format: "%.0f", prediction * 18.0)) mg/dL)")
                print("📈 Data automatically saved to SwiftData for CSV export")
                task.setTaskCompleted(success: true)
            } else {
                print("❌ Automated prediction cycle failed at \(hour):\(String(format: "%02d", minute))")
                print("🔄 Will retry at next scheduled time")
                task.setTaskCompleted(success: false)
            }
        }
    }
    
    /// Handles background processing task execution
    /// This is called by the system when the processing task fires
    func handleBackgroundProcessing(task: BGProcessingTask, modelContainer: ModelContainer) {
        print("⚙️ === BACKGROUND PROCESSING TASK STARTED ===")
        
        // Schedule the next background task
        scheduleBackgroundTasks()
        
        // Set expiration handler
        task.expirationHandler = {
            print("⏰ Background processing task expired")
            task.setTaskCompleted(success: false)
        }
        
        // Run extended automated fetch → cache → predict process
        Task {
            let modelContext = ModelContext(modelContainer)
            let averagePrediction = await performBackgroundPredictionProcess(modelContext: modelContext)
            
            if let prediction = averagePrediction {
                let now = Date()
                let hour = Calendar.current.component(.hour, from: now)
                let minute = Calendar.current.component(.minute, from: now)
                
                print("✅ Extended prediction cycle completed successfully at \(hour):\(String(format: "%02d", minute))")
                print("🩸 Average prediction: \(String(format: "%.1f", prediction)) mmol/L (\(String(format: "%.0f", prediction * 18.0)) mg/dL)")
                print("📈 Extended processing complete - data saved to SwiftData")
                task.setTaskCompleted(success: true)
            } else {
                print("❌ Extended prediction cycle failed")
                print("🔄 Will retry at next scheduled time")
                task.setTaskCompleted(success: false)
            }
        }
    }
}
