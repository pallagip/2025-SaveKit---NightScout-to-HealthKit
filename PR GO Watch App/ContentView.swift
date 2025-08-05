//
//  ContentView.swift
//  NightScoutToHealthKit Watch App
//
//  Created by Patrick Pallagi on 2025-07-29.
//

import SwiftUI
import WatchKit
import UserNotifications
import WatchConnectivity

struct ContentView: View {
    @State private var currentPrediction: String = "—"
    @State private var predictionTime: String = "—"
    @State private var lastUpdate: Date = Date()
    @State private var isConnected: Bool = false
    @State private var isProcessingGPU: Bool = false
    @State private var lastGPUPrediction: String = "—"
    @State private var lastGPUTime: String = "—"
    @StateObject private var watchManager = WatchConnectivityManager.shared
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {
                   
                    // GPU Prediction Results
                    VStack(spacing: 8) {
                        Text("🧠 GPU Prediction")
                            .font(.caption)
                            .foregroundColor(.orange)
                        
                        Text(lastGPUPrediction)
                            .font(.title2)
                            .fontWeight(.semibold)
                            .foregroundColor(.orange)
                        
                        Text(lastGPUTime)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .padding()
                    .background(Color.orange.opacity(0.1))
                    .cornerRadius(10)
                    
                    // GPU Prediction Trigger Button
                    Button(action: {
                        triggerGPUPrediction()
                    }) {
                        HStack {
                            if isProcessingGPU {
                                ProgressView()
                                    .scaleEffect(0.8)
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            } else {
                                Image(systemName: "brain")
                            }
                            Text(isProcessingGPU ? "Processing..." : "Trigger GPU")
                        }
                        .foregroundColor(.white)
                        .font(.caption)
                        .fontWeight(.semibold)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .disabled(isProcessingGPU || !isConnected)
                    
                    // Connection status
                    HStack {
                        Circle()
                            .fill(isConnected ? Color.green : Color.red)
                            .frame(width: 8, height: 8)
                        
                        Text(isConnected ? "Connected" : "Disconnected")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                }
                .padding()
            }
        }
        .onAppear {
            setupNotificationObserver()
            checkConnectivity()
            setupWatchConnectivity()
            requestNotificationPermissions()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("OpenWatchAppFromNotification"))) { _ in
            // This handles deep linking from notification taps
            print("🔔 Watch app opened from OneSignal notification tap")
        }
    }
    
    private func setupNotificationObserver() {
        // Listen for regular prediction updates from iPhone app
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("BGPredictionUpdate"),
            object: nil,
            queue: .main
        ) { notification in
            if let userInfo = notification.userInfo,
               let prediction = userInfo["prediction"] as? Double,
               let timestamp = userInfo["timestamp"] as? Date {
                updatePrediction(prediction: prediction, timestamp: timestamp)
            }
        }
        
        // Listen for GPU prediction updates from iPhone app
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("GPUPredictionUpdate"),
            object: nil,
            queue: .main
        ) { notification in
            if let userInfo = notification.userInfo,
               let prediction = userInfo["prediction"] as? Double,
               let timestamp = userInfo["timestamp"] as? Date {
                updateGPUPrediction(prediction: prediction, timestamp: timestamp)
            }
        }
        
        // Listen for GPU processing status
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("GPUProcessingStatus"),
            object: nil,
            queue: .main
        ) { notification in
            if let userInfo = notification.userInfo,
               let isProcessing = userInfo["isProcessing"] as? Bool {
                self.isProcessingGPU = isProcessing
            }
        }
        
        // Listen for GPU prediction results
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("GPUPredictionUpdate"),
            object: nil,
            queue: .main
        ) { notification in
            if let userInfo = notification.userInfo,
               let prediction = userInfo["prediction"] as? Double,
               let timestamp = userInfo["timestamp"] as? Date {
                self.updateGPUPrediction(prediction: prediction, timestamp: timestamp)
                print("✅ Watch received GPU prediction result: \(String(format: "%.1f", prediction)) mmol/L")
            }
        }
    }
    
    private func updatePrediction(prediction: Double, timestamp: Date) {
        currentPrediction = String(format: "%.1f", prediction)
        
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        predictionTime = formatter.string(from: timestamp)
        
        lastUpdate = timestamp
        isConnected = true
        
        // Send local notification on watch
        sendWatchNotification(prediction: prediction)
    }
    
    private func sendWatchNotification(prediction: Double) {
        let content = UNMutableNotificationContent()
        content.title = "🩸 BG Prediction"
        content.body = "📊 \(String(format: "%.1f", prediction)) mmol/L"
        content.subtitle = "20-min prediction"
        content.sound = nil // Silent
        
        let request = UNNotificationRequest(
            identifier: "watch_bg_prediction_\(Int(Date().timeIntervalSince1970))",
            content: content,
            trigger: nil
        )
        
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("❌ Error sending watch notification: \(error)")
            } else {
                print("✅ Sent watch notification: \(String(format: "%.1f", prediction)) mmol/L")
            }
        }
    }
    
    private func checkConnectivity() {
        // Use WatchConnectivity for proper connection status
        isConnected = watchManager.isConnected
        
        // Update connectivity status every 10 seconds
        Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { _ in
            self.isConnected = self.watchManager.isConnected
        }
    }
    
    private func setupWatchConnectivity() {
        // Initialize watch connectivity manager
        _ = WatchConnectivityManager.shared
        print("🔗 Watch connectivity initialized for ContentView")
    }
    
    private func requestNotificationPermissions() {
        // Request comprehensive notification permissions for OneSignal integration
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound, .badge, .providesAppNotificationSettings]
        ) { granted, error in
            DispatchQueue.main.async {
                if granted {
                    print("✅ Watch notification permissions granted for OneSignal")
                } else {
                    print("❌ Watch notification permissions denied: \(error?.localizedDescription ?? "unknown")")
                }
            }
        }
    }
    
    private func triggerGPUPrediction() {
        guard isConnected else {
            print("⚠️ Cannot trigger GPU prediction - iPhone not connected")
            return
        }
        
        isProcessingGPU = true
        
        // Send message to iPhone to trigger GPU prediction
        let message = [
            "type": "trigger_gpu_prediction",
            "timestamp": Date().timeIntervalSince1970,
            "source": "watch_button"
        ] as [String: Any]
        
        if WCSession.default.isReachable {
            WCSession.default.sendMessage(message, replyHandler: { response in
                DispatchQueue.main.async {
                    print("✅ GPU prediction request acknowledged by iPhone")
                    if let success = response["success"] as? Bool, !success {
                        self.isProcessingGPU = false
                    }
                }
            }) { error in
                DispatchQueue.main.async {
                    print("❌ Failed to send GPU prediction request: \(error.localizedDescription)")
                    self.isProcessingGPU = false
                }
            }
        } else {
            // Use background transfer if not immediately reachable
            WCSession.default.transferUserInfo(message)
            print("📤 Sent GPU prediction request via background transfer")
        }
    }
    
    private func updateGPUPrediction(prediction: Double, timestamp: Date) {
        lastGPUPrediction = String(format: "%.1f", prediction)
        
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        lastGPUTime = formatter.string(from: timestamp)
        
        isProcessingGPU = false
    }
    

}

#Preview {
    ContentView()
}
