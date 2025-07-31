//
//  ContentView.swift
//  NightScoutToHealthKit Watch App
//
//  Created by Patrick Pallagi on 2025-07-29.
//

import SwiftUI
import WatchKit
import UserNotifications

struct ContentView: View {
    @State private var currentPrediction: String = "—"
    @State private var predictionTime: String = "—"
    @State private var lastUpdate: Date = Date()
    @State private var isConnected: Bool = false
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {
                    // Header
                    VStack(spacing: 4) {
                        Text("🩸 BG Prediction")
                            .font(.headline)
                            .foregroundColor(.blue)
                        
                        Text("20-min forecast")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    // Main prediction display
                    VStack(spacing: 8) {
                        Text(currentPrediction)
                            .font(.title)
                            .fontWeight(.bold)
                            .foregroundColor(.primary)
                        
                        Text("mmol/L")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding()
                    .background(Color(.gray))
                    .cornerRadius(12)
                    
                    // Last update info
                    VStack(spacing: 4) {
                        Text("Last Update")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        Text(predictionTime)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    
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
        }
    }
    
    private func setupNotificationObserver() {
        // Listen for notification updates from iPhone app
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
        
        // Request notification permissions
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            DispatchQueue.main.async {
                if granted {
                    print("✅ Watch notification permissions granted")
                } else {
                    print("❌ Watch notification permissions denied")
                }
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
        // Check if we can communicate with iPhone app
        // This is a simplified connectivity check
        isConnected = WKExtension.shared().applicationState == .active
        
        // Update connectivity status every 30 seconds
        Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { _ in
            isConnected = WKExtension.shared().applicationState == .active
        }
    }
}

#Preview {
    ContentView()
}
