//
//  WatchConnectivityManager.swift
//  NightScouttoHealthKit Watch App
//
//  Handles communication between iPhone app and Apple Watch
//

import Foundation
import WatchConnectivity
import UserNotifications
import Combine

class WatchConnectivityManager: NSObject, ObservableObject {
    static let shared = WatchConnectivityManager()
    
    @Published var isConnected = false
    @Published var lastPrediction: Double?
    @Published var lastPredictionTime: Date?
    
    private override init() {
        super.init()
        setupWatchConnectivity()
    }
    
    private func setupWatchConnectivity() {
        if WCSession.isSupported() {
            let session = WCSession.default
            session.delegate = self
            session.activate()
            print("🔗 WatchConnectivity session activated")
        }
    }
    
    func sendPredictionToWatch(prediction: Double, timestamp: Date) {
        guard WCSession.default.activationState == .activated else {
            print("⚠️ WatchConnectivity not activated, sending local notification instead")
            sendLocalWatchNotification(prediction: prediction, timestamp: timestamp)
            return
        }
        
        let userInfo = [
            "type": "bg_prediction",
            "prediction_mmol": prediction,
            "prediction_mgdl": prediction * 18.0,
            "timestamp": timestamp.timeIntervalSince1970,
            "formatted_time": DateFormatter.localizedString(from: timestamp, dateStyle: .none, timeStyle: .short)
        ] as [String: Any]
        
        // Try immediate delivery first if watch is reachable
        if WCSession.default.isReachable {
            WCSession.default.sendMessage(userInfo, replyHandler: { response in
                print("✅ Watch responded to prediction message")
            }) { error in
                print("⚠️ Immediate delivery failed: \(error.localizedDescription)")
                print("🔄 Falling back to background transfer...")
                self.sendViaBackgroundTransfer(userInfo: userInfo, prediction: prediction, timestamp: timestamp)
            }
        } else {
            print("⚠️ Watch not immediately reachable, using background transfer")
            sendViaBackgroundTransfer(userInfo: userInfo, prediction: prediction, timestamp: timestamp)
        }
    }
    
    private func sendViaBackgroundTransfer(userInfo: [String: Any], prediction: Double, timestamp: Date) {
        // Use transferUserInfo for reliable background delivery
        WCSession.default.transferUserInfo(userInfo)
        print("📤 Sent prediction via background transfer: \(String(format: "%.1f", prediction)) mmol/L")
        
        // Also send local notification as backup
        sendLocalWatchNotification(prediction: prediction, timestamp: timestamp)
    }
    
    private func sendLocalWatchNotification(prediction: Double, timestamp: Date) {
        let content = UNMutableNotificationContent()
        content.title = "🩸 BG Prediction"
        content.body = "📊 \(String(format: "%.1f", prediction)) mmol/L (\(String(format: "%.0f", prediction * 18.0)) mg/dL)"
        content.subtitle = "20-min prediction"
        content.sound = nil // Silent notification
        content.categoryIdentifier = "BG_PREDICTION"
        content.threadIdentifier = "bg_predictions"
        
        // Add user info for watch complications
        content.userInfo = [
            "prediction_mmol": prediction,
            "prediction_mgdl": prediction * 18.0,
            "timestamp": timestamp.timeIntervalSince1970,
            "type": "bg_prediction"
        ]
        
        let request = UNNotificationRequest(
            identifier: "watch_bg_prediction_\(Int(timestamp.timeIntervalSince1970))",
            content: content,
            trigger: nil
        )
        
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("❌ Error sending watch notification: \(error.localizedDescription)")
            } else {
                print("✅ Sent watch notification: \(String(format: "%.1f", prediction)) mmol/L")
            }
        }
    }
}

// MARK: - WCSessionDelegate
extension WatchConnectivityManager: WCSessionDelegate {
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        DispatchQueue.main.async {
            self.isConnected = activationState == .activated
            if let error = error {
                print("❌ WatchConnectivity activation error: \(error.localizedDescription)")
            } else {
                print("✅ WatchConnectivity activated with state: \(activationState.rawValue)")
            }
        }
    }
    
    func session(_ session: WCSession, didReceiveMessage message: [String : Any]) {
        DispatchQueue.main.async {
            if let type = message["type"] as? String {
                switch type {
                case "bg_prediction":
                    self.handleBGPrediction(message: message)
                case "gpu_prediction_result":
                    self.handleGPUPredictionResult(message: message)
                case "gpu_processing_status":
                    self.handleGPUProcessingStatus(message: message)
                default:
                    print("⚠️ Unknown message type from iPhone: \(type)")
                }
            }
        }
    }
    
    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String : Any] = [:]) {
        DispatchQueue.main.async {
            if let type = userInfo["type"] as? String {
                switch type {
                case "bg_prediction":
                    self.handleBGPrediction(message: userInfo)
                case "gpu_prediction_result":
                    self.handleGPUPredictionResult(message: userInfo)
                case "gpu_processing_status":
                    self.handleGPUProcessingStatus(message: userInfo)
                case "onesignal_notification":
                    self.handleOneSignalNotification(message: userInfo)
                default:
                    print("⚠️ Unknown background message type from iPhone: \(type)")
                }
            }
        }
    }
    
    // MARK: - Message Handlers
    private func handleBGPrediction(message: [String: Any]) {
        guard let prediction = message["prediction_mmol"] as? Double,
              let timestamp = message["timestamp"] as? TimeInterval else {
            print("❌ Invalid BG prediction message format")
            return
        }
        
        self.lastPrediction = prediction
        self.lastPredictionTime = Date(timeIntervalSince1970: timestamp)
        
        print("📱 Received BG prediction from iPhone: \(String(format: "%.1f", prediction)) mmol/L")
        
        // Send local notification on watch
        self.sendLocalWatchNotification(
            prediction: prediction,
            timestamp: Date(timeIntervalSince1970: timestamp)
        )
        
        // Post notification for UI update
        NotificationCenter.default.post(
            name: NSNotification.Name("BGPredictionUpdate"),
            object: nil,
            userInfo: [
                "prediction": prediction,
                "timestamp": Date(timeIntervalSince1970: timestamp)
            ]
        )
    }
    
    private func handleGPUPredictionResult(message: [String: Any]) {
        guard let prediction = message["prediction_mmol"] as? Double,
              let timestamp = message["timestamp"] as? TimeInterval else {
            print("❌ Invalid GPU prediction result message format")
            return
        }
        
        print("🧠 Received GPU prediction result from iPhone: \(String(format: "%.1f", prediction)) mmol/L")
        
        // Post notification for GPU prediction UI update
        NotificationCenter.default.post(
            name: NSNotification.Name("GPUPredictionUpdate"),
            object: nil,
            userInfo: [
                "prediction": prediction,
                "timestamp": Date(timeIntervalSince1970: timestamp)
            ]
        )
        
        // GPU prediction result received - UI will update via NotificationCenter
    }
    
    private func handleGPUProcessingStatus(message: [String: Any]) {
        guard let isProcessing = message["isProcessing"] as? Bool else {
            print("❌ Invalid GPU processing status message format")
            return
        }
        
        print("🔄 GPU processing status: \(isProcessing ? "STARTED" : "COMPLETED")")
        
        // Post notification for processing status UI update
        NotificationCenter.default.post(
            name: NSNotification.Name("GPUProcessingStatus"),
            object: nil,
            userInfo: ["isProcessing": isProcessing]
        )
    }
    
    private func handleOneSignalNotification(message: [String: Any]) {
        print("🔔 Received OneSignal notification from iPhone")
        
        // Post notification to open watch app from deep link (no watch notifications)
        NotificationCenter.default.post(
            name: NSNotification.Name("OpenWatchAppFromNotification"),
            object: nil,
            userInfo: message
        )
    }
    

}
