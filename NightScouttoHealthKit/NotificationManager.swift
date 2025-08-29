import Foundation
import UserNotifications
import SwiftData
import BackgroundTasks
import UIKit

class NotificationManager: ObservableObject {
    static let shared = NotificationManager()
    
    private init() {}
    
    // Initialize background automation without notifications
    func initializeBackgroundAutomation() {
        print("⚙️ Initializing background automation (no notifications required)")
        
        // Start background task scheduling immediately
        scheduleBackgroundTasks()
        
        print("🦖 Process: Fetch → Cache → Predict (all automatic, no user interaction needed)")
    }
    
    // Schedule all notifications for the specified times
    func scheduleHourlyNotifications() {
        print("🚫 Hourly notification scheduling disabled - predictions are manual-only")
        // Clear any existing notifications
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
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
        print("🚫 BACKGROUND PREDICTIONS DISABLED - This method should not be called")
        print("🚫 Predictions are now manual-only via button presses")
        return nil
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
    
    /// Background task scheduling disabled - predictions are now manual-only
    func scheduleBackgroundTasks() {
        print("🚫 Background task scheduling disabled - predictions are manual-only")
        // Cancel any existing background tasks
        BGTaskScheduler.shared.cancelAllTaskRequests()
    }
    
    /// Background app refresh disabled - predictions are now manual-only
    func handleBackgroundAppRefresh(task: BGAppRefreshTask, modelContainer: ModelContainer) {
        print("🚫 Background app refresh disabled - predictions are manual-only")
        task.setTaskCompleted(success: true)
    }
    
    /// Background processing disabled - predictions are now manual-only
    func handleBackgroundProcessing(task: BGProcessingTask, modelContainer: ModelContainer) {
        print("🚫 Background processing disabled - predictions are manual-only")
        task.setTaskCompleted(success: true)
    }
}
