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
        // Handle messages from watch if needed
        print("📱 Received message from watch: \(message)")
        replyHandler(["status": "received"])
    }
}
