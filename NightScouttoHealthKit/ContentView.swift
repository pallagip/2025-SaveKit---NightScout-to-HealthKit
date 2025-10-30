//
//  ContentView.swift
//  NightScouttoHealthKit
//
//  Created by Patrick Pallagi on 2025-05-09. Commented
//

import SwiftUI
import BackgroundTasks
import UIKit
import CoreML
import SwiftData
import HealthKit

struct ContentView: View {
    var body: some View {
        TabView {
            BGPredictionView()
                .tabItem {
                    Label("Predict", systemImage: "waveform.path.ecg")
                }

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
        }
    }
}

// MARK: - Blood Glucose Prediction
struct BGPredictionView: View {
    @StateObject private var predictionService = BGPredictionService()
    @StateObject private var hk = HealthKitFeatureProvider()
    @StateObject private var updatedGlucosePredictorService = UpdatedGlucosePredictorService()
    @State private var currentBGText: String = "—"
    @State private var changeBasedPredictionText: String = "—"
    @State private var changeBasedChangeText: String = "—"
    @State private var wavenet1Text: String = "—"
    @State private var wavenet2Text: String = "—"
    @State private var wavenet3Text: String = "—"
    @State private var wavenet4Text: String = "—"
    @State private var wavenet5Text: String = "—"
    @AppStorage("useMgdlUnits") private var useMgdlUnits = true
    @State private var lastGlucoseReading: Double = 0.0  // Track previous reading
    @State private var lastReadingTimestamp: Date? = nil  // When the reading was taken
    
    // SwiftData access
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Prediction.timestamp, order: .reverse) private var allPredictions: [Prediction]
    @Query(sort: \WorkoutTimeData.predictionTimestamp, order: .reverse) private var workoutData: [WorkoutTimeData]
    @State private var refreshID = UUID() // Track when to refresh predictions
    @State private var isRefreshing = false // Track refresh status
    
    // Show all predictions (no deduplication) so individual model outputs are visible
    private var predictions: [Prediction] {
        allPredictions
    }

    var body: some View {
        VStack(spacing: 24) {
            // Change-Based Glucose Prediction
            VStack(spacing: 16) {
                Text(useMgdlUnits ? "Change-Based Prediction - 20 min (mg/dL)" : "Change-Based Prediction - 20 min (mmol/L)")
                    .font(.headline)
                
                // Current BG, Change, and Predicted Value display
                VStack(spacing: 12) {
                    // Current BG
                    VStack(spacing: 4) {
                        Text("Current BG")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(currentBGText)
                            .font(.system(size: 28, weight: .semibold, design: .rounded))
                            .foregroundStyle(.primary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(12)
                    .background(Color(.systemGray5))
                    .cornerRadius(12)
                    
                    // Change and Predicted Value
                    HStack(spacing: 16) {
                        VStack(spacing: 4) {
                            Text("Predicted Change")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(changeBasedChangeText)
                                .font(.system(size: 24, weight: .semibold, design: .rounded))
                                .foregroundStyle(.orange)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(12)
                        .background(Color(.systemGray6))
                        .cornerRadius(12)
                        
                        VStack(spacing: 4) {
                            Text("Predicted BG")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(changeBasedPredictionText)
                                .font(.system(size: 32, weight: .bold, design: .rounded))
                                .foregroundStyle(Color(.sRGB, red: 0/255, green: 100/255, blue: 200/255, opacity: 1)) // Deep blue
                        }
                        .frame(maxWidth: .infinity)
                        .padding(12)
                        .background(Color(.systemGray6))
                        .cornerRadius(12)
                    }
                }
                
                HStack {
                    Button("Predict with Change-Based Model") { Task { await predictWithChangeBasedModel() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(updatedGlucosePredictorService.isProcessing)
                }
            }
            .padding()
            .background(Color(.systemGray6))
            .cornerRadius(12)
            
            // Standard WaveNet Models Grid (below)
            VStack(spacing: 16) {
                VStack(spacing: 8) {
                    Text("Standard WaveNet Models")
                        .font(.headline)
                        .padding(.bottom, 4)
                    
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 2), spacing: 12) {
                        VStack(spacing: 4) {
                            Text("WaveNet1")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(wavenet1Text)
                                .font(.title3)
                                .foregroundStyle(colorForModelIndex(1))
                        }
                        .padding(8)
                        .background(Color(.systemGray6))
                        .cornerRadius(8)
                        
                        VStack(spacing: 4) {
                            Text("WaveNet2")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(wavenet2Text)
                                .font(.title3)
                                .foregroundStyle(colorForModelIndex(2))
                        }
                        .padding(8)
                        .background(Color(.systemGray6))
                        .cornerRadius(8)
                        
                        VStack(spacing: 4) {
                            Text("WaveNet3")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(wavenet3Text)
                                .font(.title3)
                                .foregroundStyle(colorForModelIndex(3))
                        }
                        .padding(8)
                        .background(Color(.systemGray6))
                        .cornerRadius(8)
                        
                        VStack(spacing: 4) {
                            Text("WaveNet4")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(wavenet4Text)
                                .font(.title3)
                                .foregroundStyle(colorForModelIndex(4))
                        }
                        .padding(8)
                        .background(Color(.systemGray6))
                        .cornerRadius(8)
                        
                        VStack(spacing: 4) {
                            Text("WaveNet5")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(wavenet5Text)
                                .font(.title3)
                                .foregroundStyle(colorForModelIndex(5))
                        }
                        .padding(8)
                        .background(Color(.systemGray6))
                        .cornerRadius(8)
                    }
                }
            }
            .padding()
            .background(Color(.systemGray6))
            .cornerRadius(12)
            
            // Prediction history section
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Prediction History")
                        .font(.headline)
                    
                    Spacer()
                    
                    // Manual refresh button
                    Button(action: {
                        refreshPredictionHistory()
                    }) {
                        Image(systemName: "arrow.clockwise")
                            .foregroundColor(.blue)
                    }
                    .disabled(isRefreshing)
                }
                .padding(.bottom, 4)
                
                if predictions.isEmpty {
                    VStack(spacing: 8) {
                        Text("No predictions yet")
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                        
                        if isRefreshing {
                            ProgressView()
                                .scaleEffect(0.8)
                        }
                    }
                    .padding()
                } else {
                    // Header row
                    HStack {
                        Text("#")
                            .fontWeight(.medium)
                            .frame(width: 30, alignment: .leading)
                        Text("Date & Time")
                            .fontWeight(.medium)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(useMgdlUnits ? "Value (mg/dL)" : "Value (mmol/L)")
                            .fontWeight(.medium)
                            .frame(width: 80, alignment: .trailing)
                        Text("Type")
                            .fontWeight(.medium)
                            .frame(width: 40, alignment: .trailing)
                    }
                    .padding(.horizontal, 8)
                    .font(.caption)
                    
                    // Prediction list with pull-to-refresh
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(predictions) { prediction in
                                HStack {
                                    // Show prediction count
                                    Text(prediction.predictionCount > 0 ? "\(prediction.predictionCount)" : "—")
                                        .font(.caption)
                                        .fontWeight(.medium)
                                        .foregroundStyle(prediction.isAveragePrediction ? .blue : colorForModelIndex(prediction.modelIndex))
                                        .frame(width: 30, alignment: .leading)
                                    
                                    Text(prediction.formattedDate)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    
                                    // Display value in currently selected units
                                    Text(useMgdlUnits ? 
                                         String(format: "%.0f", prediction.predictionValueInMgdl) : 
                                         String(format: "%.1f", prediction.predictionValueInMmol))
                                        .frame(width: 80, alignment: .trailing)
                                        .fontWeight(prediction.isAveragePrediction ? .bold : .regular)
                                        .foregroundStyle(prediction.isAveragePrediction ? .blue : colorForModelIndex(prediction.modelIndex))
                                    
                                    // Show model type or average indicator
                                    Text(prediction.isAveragePrediction ? "AVG" : 
                                         prediction.modelIndex > 0 ? "M\(prediction.modelIndex)" : "")
                                        .font(.caption)
                                        .foregroundStyle(prediction.isAveragePrediction ? .blue : colorForModelIndex(prediction.modelIndex))
                                        .frame(width: 40, alignment: .trailing)
                                }
                                .padding(.vertical, 4)
                                .padding(.horizontal, 8)
                                .background(
                                    prediction.isAveragePrediction ? 
                                    Color(.systemBlue).opacity(0.1) : 
                                    Color(.systemBackground)
                                )
                                .cornerRadius(4)
                                .id(prediction.id) // Ensure each row has unique ID
                            }
                        }
                        .id(refreshID) // Force refresh when this ID changes
                    }
                    .refreshable {
                        await refreshPredictionHistory()
                    }
                    .frame(maxHeight: 200)
                    .background(Color(.systemGray6))
                    .cornerRadius(8)
                }
            }
        }
        .task {
            await initializeApp()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("PredictionHistoryRefresh"))) { notification in
            print("🔄 Received prediction history refresh notification")
            
            // Force UI refresh by updating the refreshID
            refreshID = UUID()
            
            // Log the refresh details
            if let userInfo = notification.userInfo {
                let count = userInfo["predictionCount"] as? Int ?? 0
                let avgValue = userInfo["averageValue"] as? Double ?? 0.0
                print("📊 UI refreshed - Predictions: \(count), Avg: \(String(format: "%.1f", avgValue)) mg/dL")
            }
        }
        .padding()
    }

    private func initializeApp() async {
        do {
            // Request HealthKit authorization from both services
            try await predictionService.requestHealthKitAuthorization()
            try await hk.requestAuth()
            
            // Migrate existing predictions to have proper sequential counts
            // This fixes the issue where existing predictions show "—" instead of numbers
            predictionService.migratePredictionCounts(modelContext: modelContext)
            
        } catch {
            print("❌ Initialization error: \(error)")
        }
    }

    @MainActor
    private func predict() async {
        do {
            // Run a 24h Nightscout→HealthKit sync first to ensure latest BG is in HealthKit
            let savedCount = await SyncManager.shared.performSync(isBackground: false, minutes: 1440)
            print("✅ Pre-predict sync complete — saved \(savedCount) readings from last 24h")
            
            // Check for recent insulin or carbohydrate entries within the last 20 minutes (guard)
            let hasRecentEntries = try await hk.hasRecentInsulinOrCarbEntries(minutesBack: 20.0)
            
            if hasRecentEntries {
                // Display "Too Early to tell" message and reset all model displays
                currentBGText = "—"
                wavenet1Text = "—"
                wavenet2Text = "—"
                wavenet3Text = "—"
                wavenet4Text = "—"
                wavenet5Text = "—"
                
                print("🚫 Prediction halted: Recent insulin or carbohydrate entry detected within 20 minutes")
                return
            }
            
            // Get current blood glucose and heart rate for real data pipeline connection
            let currentBG = try await hk.fetchLatestGlucoseValue()
            let heartRate = try await hk.fetchLatestHeartRate(minutesBack: 30.0)
            
            print("🩸 Real BG data connected: \(String(format: "%.1f", currentBG)) mg/dL")
            print("❤️ Real HR data connected: \(String(format: "%.0f", heartRate)) bpm")
            
            // Update our tracking for trend calculation
            lastGlucoseReading = useMgdlUnits ? currentBG : (currentBG / 18.0)
            lastReadingTimestamp = Date()
            
            // Update current BG display
            updateCurrentBGDisplay(currentBG: currentBG)
            
            // Also run standard WaveNet models for comparison
            let inputTensor = try await hk.buildWindow()
            let modelPredictions = await SeriesPredictionService.shared.runSeriesPredictions(
                window: inputTensor,
                currentBG: currentBG,
                usedMgdl: true,  // HealthKit always returns mg/dL
                modelContext: modelContext
            )
            
            // Update individual WaveNet model displays
            updateWaveNetDisplays(predictions: modelPredictions)
            
            // Log successful data connection
            print("✅ Real blood glucose and heart rate data successfully connected to WaveNetPro pipeline")
            print("📊 WaveNetPro predictions completed using live health data")
            
            // Force UI refresh by updating the refreshID
            self.refreshID = UUID()
            print("UI refresh triggered")
            
        } catch {
            currentBGText = "Err"
            wavenet1Text = "Err"
            wavenet2Text = "Err"
            wavenet3Text = "Err"
            wavenet4Text = "Err"
            wavenet5Text = "Err"
            print("❌ predict failed:", error)
        }
    }
    
    // New dedicated Change-Based Model prediction function
    private func predictWithChangeBasedModel() async {
        updatedGlucosePredictorService.isProcessing = true
        defer { updatedGlucosePredictorService.isProcessing = false }
        
        do {
            // Run a 24h Nightscout→HealthKit sync first to ensure latest BG is in HealthKit
            let savedCount = await SyncManager.shared.performSync(isBackground: false, minutes: 1440)
            print("✅ Pre-predict sync complete — saved \(savedCount) readings from last 24h")
            
            // Check for recent insulin or carbohydrate entries within the last 20 minutes (guard)
            let hasRecentEntries = try await hk.hasRecentInsulinOrCarbEntries(minutesBack: 20.0)
            
            if hasRecentEntries {
                changeBasedPredictionText = "Too Early"
                changeBasedChangeText = "—"
                currentBGText = "—"
                print("🚫 Change-based prediction halted: Recent insulin or carbohydrate entry detected within 20 minutes")
                return
            }
            
            // Get comprehensive HealthKit data for prediction
            let glucoseHistory = try await hk.fetchRecentGlucoseValues(limit: 24) // Last 2 hours
            let carbHistory = try await fetchCarbHistoryForPrediction()
            let insulinHistory = try await fetchInsulinHistoryForPrediction()
            let heartRateHistory = try await fetchHeartRateHistoryForPrediction()
            
            // Ensure we have glucose data and get the current (most recent) glucose value
            guard !glucoseHistory.isEmpty else {
                throw NSError(domain: "PredictionError", code: 1, userInfo: [NSLocalizedDescriptionKey: "No glucose history available"])
            }
            
            let currentBG = glucoseHistory.first! // Most recent glucose value from the history
            updateCurrentBGDisplay(currentBG: currentBG)
            
            print("📊 Glucose history order check:")
            print("   Most recent (first): \(String(format: "%.1f", glucoseHistory.first!)) mg/dL")
            print("   Oldest (last): \(String(format: "%.1f", glucoseHistory.last!)) mg/dL")
            print("   Will reverse for prediction service (expects oldest->newest)")
            
            print("🔄 Starting change-based prediction with comprehensive HealthKit data")
            print("🩸 Current BG: \(String(format: "%.1f", currentBG)) mg/dL")
            print("📊 Using \(glucoseHistory.count) glucose readings, \(carbHistory.count) carb entries, \(insulinHistory.count) insulin entries")
            
            // Create a properly ordered glucose history (most recent first, but prediction expects oldest first)
            let orderedGlucoseHistory = Array(glucoseHistory.reversed()) // Reverse to get oldest->newest
            
            // Use the UpdatedGlucosePredictorService to make prediction
            if let result = updatedGlucosePredictorService.predictAbsoluteGlucose(
                glucoseHistory: orderedGlucoseHistory,
                carbsHistory: carbHistory,
                insulinHistory: insulinHistory,
                heartRateHistory: heartRateHistory,
                currentTime: Date()
            ) {
                // Update displays with the results
                updateChangeBasedDisplay(prediction: result.absolutePrediction ?? 0, change: result.predictedChange ?? 0)
                
                print("🔄 Change-based prediction completed:")
                print("   Absolute: \(String(format: "%.1f", result.absolutePrediction ?? 0)) mg/dL")
                print("   Change: \(result.predictedChange ?? 0 > 0 ? "+" : "")\(String(format: "%.1f", result.predictedChange ?? 0)) mg/dL")
                
                // Cache Random Forest prediction in SwiftData for CSV export
                print("🎯 About to cache individual RandomForest prediction from Change-Based Model")
                Task {
                    await cacheRandomForestPrediction(
                        prediction: result.absolutePrediction ?? 0,
                        timestamp: Date(),
                        carbHistory: carbHistory,
                        insulinHistory: insulinHistory
                    )
                    
                    print("🎯 Individual RandomForest prediction caching completed, sending notification...")
                    
                    // Notify that RandomForest data has been updated for CSV export
                    await MainActor.run {
                        NotificationCenter.default.post(
                            name: NSNotification.Name("RandomForestDataUpdated"),
                            object: nil,
                            userInfo: ["modelContext": modelContext]
                        )
                        print("🎯 RandomForestDataUpdated notification sent with context!")
                    }
                }
            } else {
                throw NSError(domain: "ChangePredictionError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Change-based prediction failed"])
            }
            
            // Force UI refresh
            self.refreshID = UUID()
            
        } catch {
            changeBasedPredictionText = "Err"
            changeBasedChangeText = "Err"
            currentBGText = "Err"
            print("❌ Change-based prediction failed: \(error)")
        }
    }
    
    private func updateCurrentBGDisplay(currentBG: Double) {
        // Update current BG display (currentBG is in mg/dL)
        currentBGText = useMgdlUnits ? 
            String(format: "%.0f", currentBG) : 
            String(format: "%.1f", currentBG / 18.0)
    }
    
    private func updateChangeBasedDisplay(prediction: Double, change: Double) {
        // Update change-based prediction display (values are in mg/dL)
        changeBasedPredictionText = useMgdlUnits ? 
            String(format: "%.0f", prediction) : 
            String(format: "%.1f", prediction / 18.0)
            
        let changePrefix = change > 0 ? "+" : ""
        changeBasedChangeText = useMgdlUnits ?
            "\(changePrefix)\(String(format: "%.0f", change))" :
            "\(changePrefix)\(String(format: "%.1f", change / 18.0))"
    }
    
    // Helper methods to fetch data for change-based predictions
    private func fetchCarbHistoryForPrediction() async throws -> [Double] {
        let carbIntakes = try await hk.fetchRecentCarbIntake(hoursBack: 6.0)
        return carbIntakes.map { $0.grams }
    }
    
    private func fetchInsulinHistoryForPrediction() async throws -> [Double] {
        let insulinDoses = try await hk.fetchRecentInsulinDoses(hoursBack: 6.0)
        return insulinDoses.map { $0.units }
    }
    
    private func fetchHeartRateHistoryForPrediction() async throws -> [Double] {
        // Get recent heart rate readings
        let heartRate = try await hk.fetchLatestHeartRate(minutesBack: 30.0)
        // Return array with repeated current heart rate for now
        return Array(repeating: heartRate, count: 8)
    }

    private func updateWaveNetDisplays(predictions: [Int: Prediction]) {
        // Update each WaveNet model display
        if let prediction1 = predictions[1] {
            wavenet1Text = useMgdlUnits ? 
                String(format: "%.0f", prediction1.modelOutput * 18.0) : 
                String(format: "%.1f", prediction1.modelOutput)
        } else {
            wavenet1Text = "—"
        }
        
        if let prediction2 = predictions[2] {
            wavenet2Text = useMgdlUnits ? 
                String(format: "%.0f", prediction2.modelOutput * 18.0) : 
                String(format: "%.1f", prediction2.modelOutput)
        } else {
            wavenet2Text = "—"
        }
        
        if let prediction3 = predictions[3] {
            wavenet3Text = useMgdlUnits ? 
                String(format: "%.0f", prediction3.modelOutput * 18.0) : 
                String(format: "%.1f", prediction3.modelOutput)
        } else {
            wavenet3Text = "—"
        }
        
        if let prediction4 = predictions[4] {
            wavenet4Text = useMgdlUnits ? 
                String(format: "%.0f", prediction4.modelOutput * 18.0) : 
                String(format: "%.1f", prediction4.modelOutput)
        } else {
            wavenet4Text = "—"
        }
        
        if let prediction5 = predictions[5] {
            wavenet5Text = useMgdlUnits ? 
                String(format: "%.0f", prediction5.modelOutput * 18.0) : 
                String(format: "%.1f", prediction5.modelOutput)
        } else {
            wavenet5Text = "—"
        }
    }

    // Map model index to exact hex colors
    // WaveNet1: #007AFF (blue)
    // WaveNet2: #34C759 (green)
    // WaveNet3: #FF9500 (orange)
    // WaveNet4: #FF3B30 (red)
    // WaveNet5: #AF52DE (purple)
    private func colorForModelIndex(_ index: Int) -> Color {
        switch index {
        case 1: // #007AFF
            return Color(.sRGB, red: 0/255, green: 122/255, blue: 255/255, opacity: 1)
        case 2: // #34C759
            return Color(.sRGB, red: 52/255, green: 199/255, blue: 89/255, opacity: 1)
        case 3: // #FF9500
            return Color(.sRGB, red: 255/255, green: 149/255, blue: 0/255, opacity: 1)
        case 4: // #FF3B30
            return Color(.sRGB, red: 255/255, green: 59/255, blue: 48/255, opacity: 1)
        case 5: // #AF52DE
            return Color(.sRGB, red: 175/255, green: 82/255, blue: 222/255, opacity: 1)
        default:
            return Color.primary
        }
    }
    
    private func calculateAveragePrediction(predictions: [Int: Prediction]) -> Double {
        let validPredictions = predictions.values.compactMap { $0.modelOutput }
        guard !validPredictions.isEmpty else { return 0.0 }
        
        let sum = validPredictions.reduce(0.0, +)
        return sum / Double(validPredictions.count)
    }
    
    // Helper method to calculate glucose momentum (trend)
    private func calculateMomentum(from readings: [Double]) -> Double {
        guard readings.count >= 2 else { return 0.0 }
        
        // Calculate the rate of change between the most recent readings
        let recent = readings[0]
        let previous = readings[1]
        
        // Return change in mg/dL per minute (approximate)
        return (recent - previous) / 5.0 // Assuming 5-minute intervals
    }
    
    // Helper method to determine stability status based on momentum
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
    
    // Method to refresh prediction history (both manual and pull-to-refresh)
    private func refreshPredictionHistory() async {
        isRefreshing = true
        
        // Force UI refresh by updating the refreshID
        refreshID = UUID()
        
        // Add a small delay to show the refresh indicator
        try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
        
        print("🔄 Prediction history refreshed - Total predictions: \(predictions.count)")
        
        isRefreshing = false
    }
    
    // Synchronous version for button tap
    private func refreshPredictionHistory() {
        Task {
            await refreshPredictionHistory()
        }
    }
    
    
    // MARK: - Test Cache Data Method
    /// Adds test insulin and carb data to SwiftData caches for testing fallback functionality
    private func addTestCacheData() async {
        let now = Date()
        
        // Add test insulin data (recent doses to simulate active IOB)
        let testInsulinDoses = [
            (timestamp: now.addingTimeInterval(-30 * 60), amount: 5.0, type: "Test Bolus 1"), // 30 min ago
            (timestamp: now.addingTimeInterval(-90 * 60), amount: 3.5, type: "Test Bolus 2"), // 1.5 hours ago
            (timestamp: now.addingTimeInterval(-150 * 60), amount: 2.0, type: "Test Bolus 3") // 2.5 hours ago
        ]
        
        // Add test carb data (recent intake to simulate active COB)
        let testCarbIntakes = [
            (timestamp: now.addingTimeInterval(-45 * 60), amount: 25.0, type: "Test Meal 1"), // 45 min ago
            (timestamp: now.addingTimeInterval(-120 * 60), amount: 15.0, type: "Test Snack 1"), // 2 hours ago
            (timestamp: now.addingTimeInterval(-180 * 60), amount: 40.0, type: "Test Meal 2") // 3 hours ago
        ]
        
        var insulinCount = 0
        var carbCount = 0
        
        // Insert test insulin data
        for (timestamp, amount, type) in testInsulinDoses {
            let testUUID = "test-insulin-\(UUID().uuidString)"
            
            // Check if similar test data already exists to avoid duplicates
            // Calculate time range outside predicate to avoid unsupported function calls
            let timeStart = timestamp.addingTimeInterval(-60)
            let timeEnd = timestamp.addingTimeInterval(60)
            let fetchDescriptor = FetchDescriptor<NightScoutInsulinCache>(
                predicate: #Predicate<NightScoutInsulinCache> { cache in
                    cache.sourceInfo == "Test Data" && cache.timestamp >= timeStart && cache.timestamp <= timeEnd
                }
            )
            
            let existingInsulin = try? modelContext.fetch(fetchDescriptor)
            if existingInsulin?.isEmpty != false {
                let insulinCache = NightScoutInsulinCache(
                    timestamp: timestamp,
                    insulinAmount: amount,
                    insulinType: type,
                    nightScoutId: testUUID,
                    sourceInfo: "Test Data"
                )
                insulinCache.updateDecayedAmount()
                modelContext.insert(insulinCache)
                insulinCount += 1
                print("💉 Added test insulin: \(String(format: "%.2f", amount)) U (\(type)) at \(timestamp.formatted(.dateTime.hour().minute()))")
            }
        }
        
        // Insert test carb data
        for (timestamp, amount, type) in testCarbIntakes {
            let testUUID = "test-carbs-\(UUID().uuidString)"
            
            // Check if similar test data already exists to avoid duplicates
            // Calculate time range outside predicate to avoid unsupported function calls
            let timeStart = timestamp.addingTimeInterval(-60)
            let timeEnd = timestamp.addingTimeInterval(60)
            let fetchDescriptor = FetchDescriptor<NightScoutCarbCache>(
                predicate: #Predicate<NightScoutCarbCache> { cache in
                    cache.sourceInfo == "Test Data" && cache.timestamp >= timeStart && cache.timestamp <= timeEnd
                }
            )
            
            let existingCarbs = try? modelContext.fetch(fetchDescriptor)
            if existingCarbs?.isEmpty != false {
                let carbCache = NightScoutCarbCache(
                    timestamp: timestamp,
                    carbAmount: amount,
                    carbType: type,
                    nightScoutId: testUUID,
                    sourceInfo: "Test Data"
                )
                carbCache.updateDecayedAmount()
                modelContext.insert(carbCache)
                carbCount += 1
                print("🍞 Added test carbs: \(String(format: "%.1f", amount)) g (\(type)) at \(timestamp.formatted(.dateTime.hour().minute()))")
            }
        }
        
        // Save the context
        do {
            try modelContext.save()
            print("✅ Test cache data saved: \(insulinCount) insulin entries, \(carbCount) carb entries")
            print("🧪 Test cache data is now available for predictions!")
            print("📍 Look for debug logs like:")
            print("   • 'Glucose range from cache: X.X to Y.Y mmol/L'")
            print("   • 'IOB from cache: Z.Z units, COB from cache: W.W grams'")
        } catch {
            print("❌ Failed to save test cache data: \(error)")
        }
    }
    
    /// Cache a Random Forest prediction in SwiftData
    private func cacheRandomForestPrediction(
        prediction: Double,
        timestamp: Date,
        carbHistory: [Double],
        insulinHistory: [Double]
    ) async {
        print("🌲 Starting to cache RandomForest prediction: \(String(format: "%.1f", prediction)) mg/dL")
        do {
            // Convert prediction from mg/dL to mmol/L
            let predictionMmol = prediction / 18.0
            print("🌲 Converted to mmol/L: \(String(format: "%.2f", predictionMmol))")
            
            // Calculate prediction count
            let predictionCount = try calculateNextRandomForestPredictionCount()
            print("🌲 Calculated prediction count: \(predictionCount)")
            
            // Create the RandomForestPrediction object
            let randomForestPrediction = RandomForestPrediction(
                timestamp: timestamp,
                predictionValue_mmol: predictionMmol,
                predictionCount: predictionCount
            )
            
            // Set carb and insulin timing information
            let lastCarbTimestamp = try await fetchLastCarbTimestamp(before: timestamp, hoursBack: 5.0)
            let lastInsulinTimestamp = try await fetchLastInsulinTimestamp(before: timestamp, hoursBack: 4.0)
            
            randomForestPrediction.setCarbTiming(lastCarbTimestamp: lastCarbTimestamp, predictionTimestamp: timestamp)
            randomForestPrediction.setInsulinTiming(lastInsulinTimestamp: lastInsulinTimestamp, predictionTimestamp: timestamp)
            
            // Insert into SwiftData
            modelContext.insert(randomForestPrediction)
            try modelContext.save()
            
            print("🌲 Random Forest prediction cached: \(String(format: "%.1f", prediction)) mg/dL at \(timestamp.formatted())")
            print("🌲 Prediction count: \(predictionCount), mmol/L: \(String(format: "%.2f", predictionMmol))")
            
        } catch {
            print("❌ Failed to cache Random Forest prediction: \(error)")
        }
    }
    
    /// Calculate next Random Forest prediction count
    private func calculateNextRandomForestPredictionCount() throws -> Int {
        let descriptor = FetchDescriptor<RandomForestPrediction>(
            sortBy: [SortDescriptor(\RandomForestPrediction.predictionCount, order: .reverse)]
        )
        let predictions = try modelContext.fetch(descriptor)
        
        if let latestCount = predictions.first?.predictionCount {
            return latestCount + 1
        } else {
            return 1
        }
    }
    
    /// Fetch last carb timestamp before a given time
    private func fetchLastCarbTimestamp(before timestamp: Date, hoursBack: Double) async throws -> Date? {
        return try await hk.fetchLastCarbEntryTimestamp(before: timestamp, hoursBack: hoursBack)
    }
    
    /// Fetch last insulin timestamp before a given time
    private func fetchLastInsulinTimestamp(before timestamp: Date, hoursBack: Double) async throws -> Date? {
        return try await hk.fetchLastInsulinEntryTimestamp(before: timestamp, hoursBack: hoursBack)
    }
}

// MARK: - Settings & Nightscout Sync
struct SettingsView: View {
    // Persisted settings
    @AppStorage("nightscoutBaseURL") private var nightscoutBaseURLString = ""
    @AppStorage("apiSecret")       private var apiSecret               = ""
    @AppStorage("apiToken")        private var apiToken                = ""
    
    // SwiftData context for working with predictions
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \MultiModelPrediction.timestamp, order: .reverse) private var multiModelPredictions: [MultiModelPrediction]
    @Query(sort: \HealthKitBGCache.timestamp, order: .reverse) private var cachedBGReadings: [HealthKitBGCache]
    @Query(sort: \RandomForestPrediction.timestamp, order: .reverse) private var randomForestPredictions: [RandomForestPrediction]
    
    // Manual random forest predictions array for more control
    @State private var manualRandomForestPredictions: [RandomForestPrediction] = []
    // Reset CSV confirmation dialog
    @State private var showResetCSVConfirmation = false
    // Next sync date (written when a sync is scheduled)
    @AppStorage("nextSyncDate")    private var nextSyncDate           = Date()
    // Blood glucose units preference
    @AppStorage("useMgdlUnits")    private var useMgdlUnits           = true
    // Field focus for keyboard management
    @FocusState private var focusedField: Field?
    private enum Field { case url, secret, token }
    
    // For CSV export and sharing
    @State private var showingShareSheet = false
    @State private var csvURL: URL?
    @State private var showingRandomForestShareSheet = false
    @State private var randomForestCSVURL: URL?
    
    // Random Forest caching service
    @StateObject private var randomForestCachingService = RandomForestCachingService.shared
    
    // Force refresh for RandomForest predictions
    @State private var randomForestRefreshID = UUID()

    // View model (no parameters → safe to initialize here)
    @StateObject private var viewModel = ContentViewModel()
    // Track UI state
    @State private var isInitialized = false
    
    // Computed property to get the current count of RandomForest predictions
    private var currentRandomForestCount: Int {
        let manualCount = manualRandomForestPredictions.count
        let queryCount = randomForestPredictions.count
        print("🔍 RandomForest count debug - Manual: \(manualCount), Query: \(queryCount)")
        
        // Use whichever has more predictions (handles both scenarios)
        return max(manualCount, queryCount)
    }
    
    // Computed property to determine which array to use for export
    private var randomForestPredictionsForExport: [RandomForestPrediction] {
        manualRandomForestPredictions.isEmpty ? randomForestPredictions : manualRandomForestPredictions
    }
    
    // Computed property for current CET time
    private var currentCETTime: String {
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: "Europe/Berlin")
        formatter.dateFormat = "HH:mm:ss 'CET'"
        return formatter.string(from: Date())
    }
    
    // MARK: - Helper Methods
    
    /// Manually refresh RandomForest predictions from SwiftData using notification context
    private func refreshRandomForestPredictionsWithContext(_ context: ModelContext) async {
        print("🔄 Starting manual refresh with notification context...")
        do {
            // Force save any pending changes first
            try context.save()
            
            let descriptor = FetchDescriptor<RandomForestPrediction>(
                sortBy: [SortDescriptor(\RandomForestPrediction.timestamp, order: .reverse)]
            )
            let predictions = try context.fetch(descriptor)
            
            await MainActor.run {
                manualRandomForestPredictions = predictions
                print("🌲 Notification context refresh complete: \(predictions.count) RandomForest predictions found")
                if !predictions.isEmpty {
                    print("🌲 Latest prediction: \(predictions.first!.timestamp.formatted()) - \(String(format: "%.2f", predictions.first!.predictionMmol)) mmol/L")
                }
            }
        } catch {
            print("❌ Failed to refresh with notification context: \(error)")
        }
    }
    
    /// Manually refresh RandomForest predictions from SwiftData
    private func refreshRandomForestPredictions() async {
        print("🔄 Starting manual refresh of RandomForest predictions...")
        do {
            // Force save any pending changes first
            try modelContext.save()
            
            let descriptor = FetchDescriptor<RandomForestPrediction>(
                sortBy: [SortDescriptor(\RandomForestPrediction.timestamp, order: .reverse)]
            )
            let predictions = try modelContext.fetch(descriptor)
            
            await MainActor.run {
                manualRandomForestPredictions = predictions
                print("🌲 Manual refresh complete: \(predictions.count) RandomForest predictions found")
                if !predictions.isEmpty {
                    print("🌲 Latest prediction: \(predictions.first!.timestamp.formatted()) - \(String(format: "%.2f", predictions.first!.predictionMmol)) mmol/L")
                } else {
                    // Debug: let's see what other models are in the database
                    do {
                        let allDescriptor = FetchDescriptor<RandomForestPrediction>()
                        let allPredictions = try modelContext.fetch(allDescriptor)
                        print("🔍 Debug: Found \(allPredictions.count) total RandomForest predictions in database")
                    } catch {
                        print("🔍 Debug: Failed to fetch all predictions: \(error)")
                    }
                }
            }
        } catch {
            print("❌ Failed to refresh RandomForest predictions: \(error)")
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
            // Settings fields
            TextField("Nightscout URL (e.g. https://mysite...)", text: $nightscoutBaseURLString)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
                .focused($focusedField, equals: .url)
                .padding()
                .background(Color(.systemGray6))
                .cornerRadius(8)

            TextField("API Secret Header", text: $apiSecret)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
                .focused($focusedField, equals: .secret)
                .padding()
                .background(Color(.systemGray6))
                .cornerRadius(8)

            TextField("API Token", text: $apiToken)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
                .focused($focusedField, equals: .token)
                .padding()
                .background(Color(.systemGray6))
                .cornerRadius(8)
                
            // Blood glucose units toggle
            Toggle(isOn: $useMgdlUnits) {
                HStack {
                    Text("Blood Glucose Units:")
                    Text(useMgdlUnits ? "mg/dL" : "mmol/L")
                        .foregroundColor(.blue)
                        .fontWeight(.bold)
                }
            }
            .padding()
            .background(Color(.systemGray6))
            .cornerRadius(8)

            // Save settings & schedule next sync
            Button("Save Settings") {
                focusedField = nil
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                                to: nil, from: nil, for: nil)
                Task {
                    do {
                        try await viewModel.saveSettings()
                    } catch {
                        print("⚠️ Settings save failed: \(error)")
                        viewModel.lastSyncResult = "Settings error: \(error.localizedDescription)"
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(Color.blue)
            .foregroundColor(.white)
            .cornerRadius(10)

            Divider().padding(.vertical)
            
            // Manual sync button for 24 hours of data
            Button {
                Task {
                    viewModel.syncInProgress = true
                    // Call perform sync with 1440 minutes (24 hours)
                    let savedCount = await SyncManager.shared.performSync(isBackground: false, minutes: 1440)
                    viewModel.syncInProgress = false
                    
                    if savedCount > 0 {
                        viewModel.lastSyncResult = "Successfully saved \(savedCount) readings from the last 24 hours"
                    } else {
                        viewModel.lastSyncResult = "No new data found in the last 24 hours"
                    }
                }
            } label: {
                if viewModel.syncInProgress {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle())
                } else {
                    Text("Sync Data for 24h")
                        .frame(maxWidth: .infinity)
                }
            }
            .padding()
            .background(viewModel.syncInProgress ? Color.gray : Color.green)
            .foregroundColor(.white)
            .cornerRadius(10)
            .disabled(viewModel.syncInProgress)

            // Status
            if let result = viewModel.lastSyncResult {
                Text(result)
                    .font(.caption)
                    .foregroundColor(result.contains("failed") ? .red : .green)
                    .padding(.top)
            }
            
            Divider().padding(.vertical)
            
            // HealthKit BG Cache Sync button
            Button {
                Task { @MainActor in
                    viewModel.syncInProgress = true
                    do {
                        // 1) Cache BG readings from HealthKit -> SwiftData (24h)
                        let bgCount = try await HealthKitBGSyncService.shared.syncHealthKitBGToCache(
                            modelContext: modelContext,
                            hoursBack: 24.0
                        )

                        // 2) Cache insulin and carbs from HealthKit -> SwiftData (foreground only)
                        let icResult = await WatchConnectivityManager.shared.performHealthKitToSwiftDataSync()

                        // 3) Backfill WorkoutTimeData for existing predictions so CSV can include workout info
                        var workoutsAdded = 0
                        for prediction in multiModelPredictions {
                            // Check if a WorkoutTimeData exists within ±30 seconds of prediction timestamp
                            let windowStart = prediction.timestamp.addingTimeInterval(-30)
                            let windowEnd = prediction.timestamp.addingTimeInterval(30)
                            let descriptor = FetchDescriptor<WorkoutTimeData>(
                                predicate: #Predicate<WorkoutTimeData> { w in
                                    w.predictionTimestamp >= windowStart && w.predictionTimestamp <= windowEnd
                                }
                            )
                            let existing = try modelContext.fetch(descriptor)
                            if existing.isEmpty {
                                let workoutService = WorkoutTrackingService()
                                _ = await workoutService.createWorkoutTimeRecord(
                                    predictionTimestamp: prediction.timestamp,
                                    modelContext: modelContext
                                )
                                workoutsAdded += 1
                            }
                        }

                        // 4) Backfill insulin/carb associations for predictions from SwiftData caches (4h insulin, 5h carbs)
                        let matcher = MultiModelPredictionMatchingService()
                        let assocResult = try matcher.backfillInsulinAndCarbAssociations(
                            predictions: multiModelPredictions,
                            modelContext: modelContext
                        )
                        try modelContext.save()

                        viewModel.lastSyncResult = "Cached BG: \(bgCount), insulin: \(icResult.insulin), carbs: \(icResult.carbs), workouts added: \(workoutsAdded), associations updated — insulin: \(assocResult.updatedInsulin), carbs: \(assocResult.updatedCarb)"
                    } catch {
                        print("⚠️ HealthKit caching failed: \(error)")
                        viewModel.lastSyncResult = "HealthKit caching failed: \(error.localizedDescription)"
                    }

                    viewModel.syncInProgress = false
                }
            } label: {
                if viewModel.syncInProgress {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle())
                } else {
                    Text("Cache HealthKit Data")
                        .frame(maxWidth: .infinity)
                }
            }
            .padding()
            .background(viewModel.syncInProgress ? Color.gray : Color.purple)
            .foregroundColor(.white)
            .cornerRadius(10)
            .disabled(viewModel.syncInProgress)

            // Export predictions button
            Button {
                Task {
                    do {
                        viewModel.syncInProgress = true
                        
                        // Export stored predictions to CSV (with actual BG matching)
                        let fileURL = try await CSVExportManager.shared.exportStoredPredictions(predictions: multiModelPredictions, modelContext: modelContext)
                        
                        // Store URL for sharing
                        csvURL = fileURL
                        showingShareSheet = true
                        
                    } catch {
                        print("⚠️ CSV Export failed: \(error)")
                        viewModel.lastSyncResult = "CSV Export failed: \(error.localizedDescription)"
                    }
                    
                    viewModel.syncInProgress = false
                }
            } label: {
                if viewModel.syncInProgress {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle())
                        .scaleEffect(0.8)
                } else {
                    Text("Export Predictions (\(multiModelPredictions.count))")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.bordered)
            .tint(.orange)
            .padding(.top, 8)
            .disabled(viewModel.syncInProgress || multiModelPredictions.isEmpty)
            
            // MARK: - Random Forest Section
            VStack(alignment: .leading, spacing: 12) {
                Text("Random Forest Predictions")
                    .font(.headline)
                    .padding(.bottom, 4)
                
                // Random Forest Cache button
                Button {
                    Task {
                        do {
                            viewModel.syncInProgress = true
                            let cachedCount = try await randomForestCachingService.cacheRandomForestPredictions(
                                modelContext: modelContext,
                                hoursBack: 24.0
                            )
                            viewModel.lastSyncResult = "Cached \(cachedCount) Random Forest predictions from last 24 hours"
                            
                            // Force refresh after caching
                            await refreshRandomForestPredictions()
                        } catch {
                            print("⚠️ Random Forest caching failed: \(error)")
                            viewModel.lastSyncResult = "Random Forest caching failed: \(error.localizedDescription)"
                        }
                        viewModel.syncInProgress = false
                    }
                } label: {
                    if viewModel.syncInProgress {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle())
                            .scaleEffect(0.8)
                    } else {
                        Text("Random Forest Cache (24h)")
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding()
                .background(viewModel.syncInProgress ? Color.gray : Color(.sRGB, red: 46/255, green: 125/255, blue: 50/255, opacity: 1))
                .foregroundColor(.white)
                .cornerRadius(10)
                .disabled(viewModel.syncInProgress)
                
                // Export Random Forest CSV button
                Button {
                    Task {
                        do {
                            Button("Cache Random Forest (24h)") {
                                Task {
                                    let cached = try await randomForestCachingService.cacheRandomForestPredictions(modelContext: modelContext, hoursBack: 24.0)
                                    print("✅ Cached \(cached) Random Forest predictions")
                                }
                            }
                            // Export Random Forest predictions to CSV
                            let fileURL = try await RandomForestCSVExportManager.shared.exportRandomForestPredictions(
                                predictions: randomForestPredictionsForExport,
                                modelContext: modelContext
                            )
                            // Store URL for sharing
                            randomForestCSVURL = fileURL
                            showingRandomForestShareSheet = true
                            
                        } catch {
                            print("⚠️ Random Forest CSV Export failed: \(error)")
                            viewModel.lastSyncResult = "Random Forest CSV Export failed: \(error.localizedDescription)"
                        }
                        
                        viewModel.syncInProgress = false
                    }
                } label: {
                    if viewModel.syncInProgress {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle())
                            .scaleEffect(0.8)
                    } else {
                        Text("Export Random Forest CSV (\(currentRandomForestCount))")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.bordered)
                .tint(.green)
                .padding(.top, 8)
                .disabled(viewModel.syncInProgress)
                
                // Test button to create a simple RandomForest prediction
                Button("🧪 Test: Create Simple Prediction") {
                    Task {
                        print("🧪 Creating test RandomForest prediction...")
                        let testPrediction = RandomForestPrediction(
                            timestamp: Date(),
                            predictionValue_mmol: 10.0,
                            predictionCount: 999
                        )
                        print("🧪 Created test prediction at: \(testPrediction.timestamp.formatted())")
                        
                        modelContext.insert(testPrediction)
                        print("🧪 Inserted test prediction, hasChanges: \(modelContext.hasChanges)")
                        
                        do {
                            try modelContext.save()
                            print("🧪 Saved test prediction successfully")
                        } catch {
                            print("🧪 Failed to save test prediction: \(error)")
                        }
                        
                        // Try to fetch it back
                        let descriptor = FetchDescriptor<RandomForestPrediction>()
                        let allPredictions = try? modelContext.fetch(descriptor)
                        print("🧪 Fetched \(allPredictions?.count ?? 0) total predictions after test")
                    }
                }
                .buttonStyle(.bordered)
                .tint(.purple)
                .padding(.top, 4)
                
                // Debug button to manually check RandomForest predictions
                Button("🔍 Debug: Check RandomForest DB") {
                    Task {
                        print("🔍 === DEBUG RANDOMFOREST DATABASE ===")
                        
                        // Check what's in the @Query first
                        print("🔍 @Query count: \(randomForestPredictions.count)")
                        if !randomForestPredictions.isEmpty {
                            print("🔍 @Query latest: \(randomForestPredictions.first!.timestamp.formatted())")
                        }
                        
                        // Force a manual refresh
                        await refreshRandomForestPredictions()
                        print("🔍 Manual array count after refresh: \(manualRandomForestPredictions.count)")
                        
                        // Try different fetch approaches
                        do {
                            let allDescriptor = FetchDescriptor<RandomForestPrediction>()
                            let allPredictions = try modelContext.fetch(allDescriptor)
                            print("🔍 Direct fetch found: \(allPredictions.count) predictions")
                            
                            if !allPredictions.isEmpty {
                                let latest = allPredictions.sorted { $0.timestamp > $1.timestamp }.first!
                                print("🔍 Latest direct fetch: \(latest.timestamp.formatted()) - \(String(format: "%.2f", latest.predictionMmol)) mmol/L")
                            }
                        } catch {
                            print("🔍 Direct fetch failed: \(error)")
                        }
                    }
                }
                .buttonStyle(.bordered)
                .tint(.blue)
                .padding(.top, 4)
                
                // Random Forest status display
                if let result = randomForestCachingService.lastCacheResult {
                    Text(result)
                        .font(.caption)
                        .foregroundColor(result.contains("failed") ? .red : .green)
                        .padding(.top, 4)
                }
            }
            .padding()
            
            Divider().padding(.vertical)
            
            // MARK: - Notification Testing Section
            VStack(alignment: .leading, spacing: 12) {
                Text("Notification System")
                    .font(.headline)
                    .padding(.bottom, 4)
                
                // Notification status
                Button("Check Notification Status") {
                    NotificationManager.shared.checkNotificationStatus()
                    NotificationManager.shared.getPendingNotificationCount()
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.blue)
                .foregroundColor(.white)
                .cornerRadius(10)
                
                // Test prediction notification
                Button("Test Prediction Notification") {
                    Task {
                        await NotificationHandler.shared.triggerTestPrediction(modelContainer: modelContext.container)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.orange)
                .foregroundColor(.white)
                .cornerRadius(10)
                
                // Reschedule notifications
                Button("Reschedule Notifications") {
                    NotificationManager.shared.scheduleHourlyNotifications()
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.green)
                .foregroundColor(.white)
                .cornerRadius(10)
                
                // Cancel all notifications
                Button("Cancel All Notifications") {
                    NotificationManager.shared.cancelAllNotifications()
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.red)
                .foregroundColor(.white)
                .cornerRadius(10)
                
                // Reset CSV Data
                Button("🗑️ Reset CSV Data") {
                    showResetCSVConfirmation = true
                }
                .onTapGesture {
                    print("🔍 DEBUG: Reset button was tapped!")
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.orange)
                .foregroundColor(.white)
                .cornerRadius(10)
                .confirmationDialog(
                    "Reset CSV Data",
                    isPresented: $showResetCSVConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Reset All Random Forest Data", role: .destructive) {
                        Task {
                            await resetRandomForestCSVData()
                        }
                    }
                    Button("Cancel", role: .cancel) { }
                } message: {
                    Text("This will permanently delete all Random Forest predictions from the database. You'll start fresh with count 1. This cannot be undone.")
                }
                
                // Debug: Direct Reset (No Confirmation)
                Button("🚨 DIRECT RESET (DEBUG)") {
                    print("🔍 DEBUG: Direct reset button pressed!")
                    Task {
                        await resetRandomForestCSVData()
                    }
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.purple)
                .foregroundColor(.white)
                .cornerRadius(10)
                
                // Current time info
                VStack(alignment: .leading, spacing: 4) {
                    Text("Current Time Info:")
                        .font(.caption)
                        .fontWeight(.medium)
                    
                    Text("Time: \(currentCETTime)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Text("Is Scheduled Time: \(NotificationHandler.shared.isScheduledPredictionTime() ? "Yes" : "No")")
                        .font(.caption)
                        .foregroundColor(NotificationHandler.shared.isScheduledPredictionTime() ? .green : .secondary)
                    
                    if let identifier = NotificationHandler.shared.getCurrentNotificationIdentifier() {
                        Text("Current ID: \(identifier)")
                            .font(.caption)
                            .foregroundColor(.blue)
                    }
                }
                .padding()
                .background(Color(.systemGray6))
                .cornerRadius(8)
            }
            .padding()
        }
        .sheet(isPresented: $showingShareSheet) {
            if let csvURL = csvURL {
                ShareSheet(activityItems: [csvURL])
            }
        }
        .sheet(isPresented: $showingRandomForestShareSheet) {
            if let randomForestCSVURL = randomForestCSVURL {
                ShareSheet(activityItems: [randomForestCSVURL])
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("RandomForestDataUpdated"))) { notification in
            print("📡 Received RandomForest data update notification - starting manual refresh...")
            
            // Try to use the context from the notification if available
            if let notificationContext = notification.userInfo?["modelContext"] as? ModelContext {
                print("🔄 Using notification context for refresh")
                Task {
                    await refreshRandomForestPredictionsWithContext(notificationContext)
                }
            } else {
                print("🔄 Using local context for refresh")
                // Force refresh of RandomForest predictions when updated
                Task {
                    // Add a small delay to allow SwiftData to sync
                    try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
                    await refreshRandomForestPredictions()
                    
                    // If still empty, try one more time after another delay
                    if manualRandomForestPredictions.isEmpty {
                        print("🔄 First refresh found 0 predictions, trying again...")
                        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
                        await refreshRandomForestPredictions()
                    }
                }
            }
        }
        .onAppear {
            print("👀 SettingsView onAppear - isInitialized: \(isInitialized)")
            if !isInitialized {
                Task { 
                    print("🔄 Initializing SettingsView...")
                    await viewModel.initialize(with: modelContext)
                    await refreshRandomForestPredictions()
                    isInitialized = true
                    print("✅ SettingsView initialization complete")
                }
            }
        }
    }
}

// MARK: - Share Sheet

struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]
    
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
        return controller
    }
    
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {
        // No updates needed
    }
}

@MainActor
class ContentViewModel: ObservableObject {
    @Published var syncInProgress = false
    @Published var lastSyncResult: String?
    
    // For prediction matching
    private let predictionMatchingService = PredictionMatchingService()
    
    // SwiftData context for working with predictions
    private var modelContext: ModelContext? = nil


    func handleManualSync() async throws {
        syncInProgress = true
        defer { syncInProgress = false }

        // Get the count of new entries saved
        let savedCount = await SyncManager.shared.performSync(isBackground: false)
        
        // After syncing Nightscout data to HealthKit, also match predictions with actual values
        var matchedCount = 0
        if let context = modelContext {
            do {
                // Match predictions with actual HealthKit values
                matchedCount = try await predictionMatchingService.matchPredictionsWithActualValues(context: context)
                print("✅ Matched \(matchedCount) predictions with actual HealthKit values")
            } catch {
                print("⚠️ Error matching predictions with HealthKit data: \(error)")
            }
        }
        
        // Provide detailed feedback based on what was actually saved and matched
        if savedCount > 0 || matchedCount > 0 {
            lastSyncResult = "Sync complete - Saved \(savedCount) readings to HealthKit, Updated \(matchedCount) predictions"
        } else {
            lastSyncResult = "Sync complete - No new data to save or update"
        }
    }

    func triggerSync() async throws -> Int {
        // First sync Nightscout data to HealthKit
        let savedCount = await SyncManager.shared.performSync(isBackground: false)
        
        // Then match predictions with actual values
        if let context = modelContext {
            do {
                // Match predictions with actual HealthKit values
                let matchedCount = try await predictionMatchingService.matchPredictionsWithActualValues(context: context)
                print("✅ Matched \(matchedCount) predictions with actual HealthKit values")
            } catch {
                print("⚠️ Error matching predictions with HealthKit data: \(error)")
            }
        }
        
        return savedCount
    }



    func saveSettings() async throws {
        let defaults = UserDefaults.standard
        guard
            let urlString = defaults.string(forKey: "nightscoutBaseURL"),
            let url = URL(string: urlString)
        else {
            print("⚠️ Invalid URL")
            throw URLError(.badURL)
        }
        print("🔧 Saving settings – URL: \(url)")
        try await HealthKitManager().requestAuthorization()
        print("✅ HealthKit authorization successful")
        
        // Trigger an immediate sync with the new settings
        let savedCount = await SyncManager.shared.performSync(isBackground: false)
        
        // After syncing, match predictions with actual values
        var matchedCount = 0
        if let context = modelContext {
            do {
                // Match predictions with actual HealthKit values
                matchedCount = try await predictionMatchingService.matchPredictionsWithActualValues(context: context)
                print("✅ Matched \(matchedCount) predictions with actual HealthKit values")
            } catch {
                print("⚠️ Error matching predictions with HealthKit data: \(error)")
            }
        }
        
        // Update the result message based on what was saved and matched
        if savedCount > 0 || matchedCount > 0 {
            lastSyncResult = "Settings saved. Synced \(savedCount) readings and updated \(matchedCount) predictions."
        } else {
            lastSyncResult = "Settings saved. HealthKit is already up to date."
        }
    }
    
    // Initialize with model context (called from the view)
    @MainActor
    func initialize(with context: ModelContext) async {
        self.modelContext = context
    }
}
    
    // MARK: - Reset CSV Data Function
    @MainActor
    private func resetRandomForestCSVData() async {
        print("🗑️ === STARTING COMPREHENSIVE RANDOM FOREST DATA RESET ===")
        
        // Method 1: Try direct SwiftData deletion
        await attemptSwiftDataDeletion()
        
        // Method 2: Try batch deletion using NSBatchDeleteRequest (if available)
        await attemptBatchDeletion()
        
        // Method 3: Reset service state regardless
        randomForestCachingService.resetInternalState()
        
        // Method 4: Clear manual arrays
        manualRandomForestPredictions.removeAll()
        
        // Method 5: Force UI refresh
        randomForestRefreshID = UUID()
        
        // Send notification to refresh UI
        NotificationCenter.default.post(
            name: NSNotification.Name("RandomForestDataUpdated"), 
            object: nil
        )
        
        print("🔄 All reset methods completed. Next prediction should start from count 1.")
        print("🗑️ === RESET PROCESS FINISHED ===")
    }
    
    @MainActor
    private func attemptSwiftDataDeletion() async {
        do {
            print("📋 Method 1: SwiftData deletion...")
            
            let fetchDescriptor = FetchDescriptor<RandomForestPrediction>(
                sortBy: [SortDescriptor(\RandomForestPrediction.timestamp, order: .forward)]
            )
            let allPredictions = try modelContext.fetch(fetchDescriptor)
            
            print("🔍 Found \(allPredictions.count) predictions via SwiftData fetch")
            
            if allPredictions.isEmpty {
                print("ℹ️ No predictions found via SwiftData")
                return
            }
            
            // Delete all predictions
            for prediction in allPredictions {
                modelContext.delete(prediction)
            }
            
            print("🔄 Saving context after marking \(allPredictions.count) for deletion...")
            try modelContext.save()
            
            // Immediate verification
            let verifyPredictions = try modelContext.fetch(fetchDescriptor)
            print("✅ SwiftData deletion: \(verifyPredictions.count) predictions remain")
            
        } catch {
            print("❌ SwiftData deletion failed: \(error)")
        }
    }
    
    @MainActor
    private func attemptBatchDeletion() async {
        do {
            print("📋 Method 2: Attempting alternative deletion...")
            
            // Try creating a new fetch and delete again
            let freshDescriptor = FetchDescriptor<RandomForestPrediction>()
            let freshPredictions = try modelContext.fetch(freshDescriptor)
            
            print("🔍 Fresh fetch found \(freshPredictions.count) predictions")
            
            if freshPredictions.count > 0 {
                print("🗑️ Attempting to delete \(freshPredictions.count) remaining predictions...")
                
                for prediction in freshPredictions {
                    print("🗑️ Deleting: Count \(prediction.predictionCount) at \(prediction.timestamp.formatted())")
                    modelContext.delete(prediction)
                }
                
                try modelContext.save()
                print("💾 Batch deletion save completed")
                
                // Final check
                let finalPredictions = try modelContext.fetch(freshDescriptor)
                print("🔍 Final count after batch deletion: \(finalPredictions.count)")
            }
            
        } catch {
            print("❌ Batch deletion failed: \(error)")
        }
    }

} // End of SettingsView

