import Foundation
import UserNotifications
import SwiftData
import UIKit
import WatchConnectivity

/// Handles notification responses and triggers background prediction processes
class NotificationHandler: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationHandler()
    
    private var modelContainer: ModelContainer?
    private var processingNotifications = Set<String>() // Track notifications being processed
    
    private override init() {
        super.init()
        setupNotificationDelegate()
    }
    
    /// Sets up the notification delegate
    func setupNotificationDelegate() {
        UNUserNotificationCenter.current().delegate = self
    }
    
    /// Sets the model container for SwiftData operations
    /// - Parameter container: The SwiftData model container
    func setModelContainer(_ container: ModelContainer) {
        self.modelContainer = container
    }
    
    // MARK: - UNUserNotificationCenterDelegate
    
    /// Called when a notification is delivered while the app is in the foreground
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        
        print("🔔 NOTIFICATION RECEIVED: \(notification.request.identifier)")
        print("🔔 App State: \(UIApplication.shared.applicationState.rawValue)")
        
        // Check if this is a background prediction trigger
        if notification.request.identifier.hasPrefix("prediction_trigger_") {
            print("🔔 Background prediction trigger fired: \(notification.request.identifier)")
            
            // Check if this trigger is already being processed
            if processingNotifications.contains(notification.request.identifier) {
                print("⚠️ Trigger \(notification.request.identifier) is already being processed, skipping")
                completionHandler([])
                return
            }
            
            // Ensure we have a model container
            guard let modelContainer = self.modelContainer else {
                print("❌ No model container available for prediction trigger")
                completionHandler([])
                return
            }
            
            print("✅ Starting prediction process for trigger: \(notification.request.identifier)")
            
            // Process the prediction in the background
            Task {
                await handlePredictionTrigger(identifier: notification.request.identifier)
            }
            
            // Don't show the background trigger notification to the user
            completionHandler([])
        } else if notification.request.identifier.hasPrefix("prediction_result_") {
            print("📤 Showing prediction result notification: \(notification.request.identifier)")
            // Show prediction result notifications
            completionHandler([.banner])
        } else {
            print("📱 Showing other notification: \(notification.request.identifier)")
            // Show other notifications normally
            completionHandler([.banner, .sound])
        }
    }
    
    /// Called when the user taps on a notification
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        
        let identifier = response.notification.request.identifier
        print("🔔 User tapped notification: \(identifier)")
        
        // Handle background prediction trigger taps (shouldn't normally happen since they're silent)
        if identifier.hasPrefix("prediction_trigger_") {
            // Check if this trigger is already being processed
            if processingNotifications.contains(identifier) {
                print("⚠️ Trigger \(identifier) is already being processed, skipping user tap")
                completionHandler()
                return
            }
            
            Task {
                await handlePredictionTrigger(identifier: identifier)
            }
        }
        // Result notifications don't need special handling - just dismiss
        
        completionHandler()
    }
    
    // MARK: - Background Processing
    
    /// Handles a background prediction trigger by running the complete prediction process
    /// and sending a result notification with the actual prediction
    /// - Parameter identifier: The trigger identifier
    @MainActor
    private func handlePredictionTrigger(identifier: String) async {
        print("🔔 === HANDLE PREDICTION TRIGGER CALLED: \(identifier) ===")
        
        // Check if already processing this notification
        if processingNotifications.contains(identifier) {
            print("⚠️ Notification \(identifier) is already being processed, skipping")
            return
        }
        
        // Mark as processing
        processingNotifications.insert(identifier)
        defer { 
            processingNotifications.remove(identifier)
            print("🧹 Removed \(identifier) from processing set")
        }
        
        print("🔔 === BACKGROUND PREDICTION TRIGGER STARTED: \(identifier) ===")
        
        // Get model container and context
        guard let modelContainer = self.modelContainer else {
            print("❌ No model container available for prediction trigger")
            sendFailureResultNotification()
            return
        }
        
        print("✅ Model container available, creating context...")
        let modelContext = ModelContext(modelContainer)
        print("✅ Model context created, starting prediction process...")
        
        // Run the prediction process
        let startTime = Date()
        let averagePrediction = await NotificationManager.shared.performBackgroundPredictionProcess(
            modelContext: modelContext
        )
        let endTime = Date()
        let duration = endTime.timeIntervalSince(startTime)
        
        print("⏱️ Prediction process completed in \(String(format: "%.1f", duration))s")
        
        // Send a new result notification with the actual prediction
        if let prediction = averagePrediction {
            print("✅ Got prediction result: \(String(format: "%.1f", prediction)) mmol/L")
            print("📤 Sending prediction result notification...")
            sendPredictionResultNotification(averagePrediction: prediction)
        } else {
            print("❌ Prediction process returned nil, sending failure notification...")
            sendFailureResultNotification()
        }
        
        print("🔔 === BACKGROUND PREDICTION TRIGGER COMPLETED: \(identifier) ===")
    }
    
    // MARK: - Result Notification Methods
    
    /// Sends a notification with the prediction result optimized for Apple Watch
    /// - Parameter averagePrediction: Average prediction value in mmol/L
    private func sendPredictionResultNotification(averagePrediction: Double) {
        let timestamp = Date()
        let content = UNMutableNotificationContent()
        content.title = "🩸 BG Prediction"
        
        // Format prediction in both units with Apple Watch-friendly formatting
        let predictionMgdl = averagePrediction * 18.0
        let mmolString = String(format: "%.1f", averagePrediction)
        let mgdlString = String(format: "%.0f", predictionMgdl)
        
        // Optimized for Apple Watch readability - shorter, clearer format
        content.body = "📊 \(mmolString) mmol/L (\(mgdlString) mg/dL)"
        
        // Add subtitle for better Apple Watch display
        content.subtitle = "20-min prediction"
        
        // Silent notification (no sound/vibration)
        content.sound = nil
        content.badge = 0
        
        // Add category for potential Apple Watch actions
        content.categoryIdentifier = "BG_PREDICTION"
        
        // Add user info for Apple Watch complications or apps
        content.userInfo = [
            "prediction_mmol": averagePrediction,
            "prediction_mgdl": predictionMgdl,
            "timestamp": timestamp.timeIntervalSince1970,
            "type": "bg_prediction"
        ]
        
        // Add thread identifier for grouping on Apple Watch
        content.threadIdentifier = "bg_predictions"
        
        // Send prediction to Apple Watch via WatchConnectivity
        WatchConnectivityManager.shared.sendPredictionToWatch(
            prediction: averagePrediction,
            timestamp: timestamp
        )
        
        // Create unique identifier for result notification
        let resultIdentifier = "prediction_result_\(Int(timestamp.timeIntervalSince1970))"
        
        // Create the request
        let request = UNNotificationRequest(identifier: resultIdentifier, content: content, trigger: nil)
        
        // Send immediately to iPhone
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("❌ Error sending iPhone prediction notification: \(error.localizedDescription)")
            } else {
                print("✅ Sent iPhone prediction notification: \(mmolString) mmol/L")
            }
        }
    }
    
    /// Sends a failure notification when prediction process fails (Apple Watch optimized)
    private func sendFailureResultNotification() {
        let content = UNMutableNotificationContent()
        content.title = "❗️ BG Prediction"
        content.body = "❌ Prediction failed"
        content.subtitle = "Check data sync"
        
        // Silent notification (no sound/vibration)
        content.sound = nil
        content.badge = 0
        
        // Add category for consistency
        content.categoryIdentifier = "BG_PREDICTION"
        
        // Add user info for Apple Watch
        content.userInfo = [
            "timestamp": Date().timeIntervalSince1970,
            "type": "bg_prediction_failure"
        ]
        
        // Add thread identifier for grouping on Apple Watch
        content.threadIdentifier = "bg_predictions"
        
        // Create unique identifier for failure notification
        let failureIdentifier = "prediction_failure_\(Int(Date().timeIntervalSince1970))"
        
        // Create the request
        let request = UNNotificationRequest(identifier: failureIdentifier, content: content, trigger: nil)
        
        // Send immediately
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("❌ Error sending Apple Watch failure notification: \(error.localizedDescription)")
            } else {
                print("📤 Sent Apple Watch failure notification")
            }
        }
    }
    
    // MARK: - Background App Refresh Support
    
    /// Handles background app refresh for prediction notifications
    /// This method can be called from BGAppRefreshTask or BGProcessingTask
    /// - Parameter modelContainer: The SwiftData model container
    /// - Returns: Success status
    @MainActor
    func handleBackgroundRefresh(modelContainer: ModelContainer) async -> Bool {
        print("🔄 === BACKGROUND APP REFRESH FOR PREDICTIONS ===")
        
        let modelContext = ModelContext(modelContainer)
        
        // Check if we're in a time window where predictions should run
        let calendar = Calendar.current
        let now = Date()
        let hour = calendar.component(.hour, from: now)
        let minute = calendar.component(.minute, from: now)
        
        // Only run during prediction hours (9-23) and at quarter-hour intervals
        guard hour >= 9 && hour <= 23 else {
            print("🔄 Outside prediction hours (9-23), skipping background refresh")
            return true
        }
        
        let validMinutes = [0, 15, 30, 45]
        let isValidTime = validMinutes.contains { abs(minute - $0) <= 2 } // 2-minute tolerance
        
        guard isValidTime else {
            print("🔄 Not at quarter-hour interval, skipping background refresh")
            return true
        }
        
        print("🔄 Running background prediction at \(hour):\(String(format: "%02d", minute))")
        
        // Run the prediction process
        let averagePrediction = await NotificationManager.shared.performBackgroundPredictionProcess(
            modelContext: modelContext
        )
        
        // Send notification with result
        let identifier = "background_refresh_\(hour)_\(minute)"
        
        if let prediction = averagePrediction {
            NotificationManager.shared.sendPredictionNotification(
                averagePrediction: prediction,
                identifier: identifier
            )
            print("🔄 Background refresh completed successfully")
            return true
        } else {
            NotificationManager.shared.sendFailureNotification(identifier: identifier)
            print("🔄 Background refresh failed")
            return false
        }
    }
    
    // MARK: - Utility Functions
    
    /// Checks if the current time matches a scheduled prediction time
    /// - Returns: True if current time is within 2 minutes of a scheduled time
    func isScheduledPredictionTime() -> Bool {
        let calendar = Calendar.current
        let now = Date()
        let hour = calendar.component(.hour, from: now)
        let minute = calendar.component(.minute, from: now)
        
        // Check if within prediction hours
        guard hour >= 9 && hour <= 23 else { return false }
        
        // Check if within 2 minutes of quarter-hour intervals
        let validMinutes = [0, 15, 30, 45]
        return validMinutes.contains { abs(minute - $0) <= 2 }
    }
    
    /// Gets the current scheduled notification identifier based on time
    /// - Returns: The notification identifier for the current time slot
    func getCurrentNotificationIdentifier() -> String? {
        let calendar = Calendar.current
        let now = Date()
        let hour = calendar.component(.hour, from: now)
        let minute = calendar.component(.minute, from: now)
        
        // Find the closest quarter-hour
        let validMinutes = [0, 15, 30, 45]
        guard let closestMinute = validMinutes.min(by: { abs($0 - minute) < abs($1 - minute) }) else {
            return nil
        }
        
        // Only return identifier if within 2 minutes of the scheduled time
        guard abs(minute - closestMinute) <= 2 else { return nil }
        
        return "prediction_notification_\(hour)_\(closestMinute)"
    }
    
    /// Manually triggers a prediction notification for testing
    /// - Parameter modelContainer: The SwiftData model container
    @MainActor
    func triggerTestPrediction(modelContainer: ModelContainer) async {
        print("🧪 === MANUAL TEST PREDICTION TRIGGERED ===")
        
        let modelContext = ModelContext(modelContainer)
        
        let averagePrediction = await NotificationManager.shared.performBackgroundPredictionProcess(
            modelContext: modelContext
        )
        
        if let prediction = averagePrediction {
            sendPredictionResultNotification(averagePrediction: prediction)
        } else {
            sendFailureResultNotification()
        }
        
        print("🧪 === TEST PREDICTION COMPLETED ===")
    }
}
