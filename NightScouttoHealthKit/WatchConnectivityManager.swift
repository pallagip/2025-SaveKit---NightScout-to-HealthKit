//
//  WatchConnectivityManager.swift
//  NightScouttoHealthKit
//
//  Handles communication between iPhone app and Apple Watch
//

import Foundation
import WatchConnectivity

class WatchConnectivityManager: NSObject, ObservableObject {
    static let shared = WatchConnectivityManager()
    
    @Published var isWatchConnected = false
    @Published var isPaired = false
    @Published var isWatchAppInstalled = false
    
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
                handleGPUPredictionRequest(message: message, replyHandler: replyHandler)
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
                handleGPUPredictionRequest(message: userInfo)
            default:
                print("⚠️ Unknown background message type from watch: \(type)")
            }
        }
    }
    
    // MARK: - GPU Prediction Handling
    private func handleGPUPredictionRequest(message: [String: Any], replyHandler: (([String: Any]) -> Void)? = nil) {
        print("🧠 Processing GPU prediction request from watch")
        
        // Send immediate acknowledgment
        replyHandler?(["success": true, "status": "processing_started"])
        
        // Send processing status to watch
        sendGPUProcessingStatusToWatch(isProcessing: true)
        
        // Trigger GPU prediction asynchronously
        Task { @MainActor in
            do {
                print("🚀 Starting GPU WaveNet prediction requested from watch")
                
                // Use the existing BackgroundGPUWaveNetService
                await BackgroundGPUWaveNetService.shared.triggerManualGPUPrediction()
                
                // Get the latest prediction result after processing
                let predictionStats = BackgroundGPUWaveNetService.shared.getBackgroundPredictionStats()
                
                if predictionStats.averageValue > 0, let lastPredictionTime = predictionStats.lastPrediction {
                    // Convert mg/dL back to mmol/L for watch display
                    let predictionMmol = predictionStats.averageValue / 18.0
                    print("✅ GPU prediction completed from watch request: \(String(format: "%.1f", predictionMmol)) mmol/L")
                    
                    // Send result to watch
                    self.sendGPUPredictionToWatch(
                        prediction: predictionMmol,
                        timestamp: lastPredictionTime
                    )
                    
                    // Send completion status
                    self.sendGPUProcessingStatusToWatch(isProcessing: false)
                } else {
                    print("❌ GPU prediction completed but no result available")
                    self.sendGPUProcessingStatusToWatch(isProcessing: false)
                }
            } catch {
                print("❌ GPU prediction error: \(error.localizedDescription)")
                self.sendGPUProcessingStatusToWatch(isProcessing: false)
            }
        }
    }
}
