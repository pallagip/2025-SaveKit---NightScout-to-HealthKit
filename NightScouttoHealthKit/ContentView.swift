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
    @State private var wavenetPro1Text: String = "—"
    @State private var wavenetPro2Text: String = "—"
    @State private var wavenetPro3Text: String = "—"
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
            // Top 3 WaveNetPro Predictions (Horizontal)
            VStack(spacing: 16) {
                Text(useMgdlUnits ? "WaveNetPro Predictions - 20 min (mg/dL)" : "WaveNetPro Predictions - 20 min (mmol/L)")
                    .font(.headline)
                
                // Top 3 WaveNetPro models in horizontal line
                HStack(spacing: 16) {
                    VStack(spacing: 4) {
                        Text("WaveNetPro1")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(wavenetPro1Text)
                            .font(.system(size: 32, weight: .bold, design: .rounded))
                            .foregroundStyle(Color(.sRGB, red: 0/255, green: 122/255, blue: 255/255, opacity: 1))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(12)
                    .background(Color(.systemGray6))
                    .cornerRadius(12)
                    
                    VStack(spacing: 4) {
                        Text("WaveNetPro2")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(wavenetPro2Text)
                            .font(.system(size: 32, weight: .bold, design: .rounded))
                            .foregroundStyle(Color(.sRGB, red: 52/255, green: 199/255, blue: 89/255, opacity: 1))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(12)
                    .background(Color(.systemGray6))
                    .cornerRadius(12)
                    
                    VStack(spacing: 4) {
                        Text("WaveNetPro3")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(wavenetPro3Text)
                            .font(.system(size: 32, weight: .bold, design: .rounded))
                            .foregroundStyle(Color(.sRGB, red: 255/255, green: 149/255, blue: 0/255, opacity: 1))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(12)
                    .background(Color(.systemGray6))
                    .cornerRadius(12)
                }
                
                HStack {
                    Button("Predict") { Task { await predict() } }
                        .buttonStyle(.borderedProminent)
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
                wavenetPro1Text = "Too Early"
                wavenetPro2Text = "Too Early"
                wavenetPro3Text = "Too Early"
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
            
            // Run WaveNetPro predictions using the new models and real data
            let proPredictions = try await predictionService.predictWithWaveNetPro()
            
            // Update WaveNetPro displays
            updateWaveNetProDisplays(predictions: proPredictions)
            
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
            wavenetPro1Text = "Err"
            wavenetPro2Text = "Err"
            wavenetPro3Text = "Err"
            wavenet1Text = "Err"
            wavenet2Text = "Err"
            wavenet3Text = "Err"
            wavenet4Text = "Err"
            wavenet5Text = "Err"
            print("❌ predict failed:", error)
        }
    }
    
    private func updateWaveNetProDisplays(predictions: [Int: Double]) {
        // Update WaveNetPro model displays (predictions are in mmol/L)
        if let prediction1 = predictions[1] {
            wavenetPro1Text = useMgdlUnits ? 
                String(format: "%.0f", prediction1 * 18.0) : 
                String(format: "%.1f", prediction1)
        } else {
            wavenetPro1Text = "—"
        }
        
        if let prediction2 = predictions[2] {
            wavenetPro2Text = useMgdlUnits ? 
                String(format: "%.0f", prediction2 * 18.0) : 
                String(format: "%.1f", prediction2)
        } else {
            wavenetPro2Text = "—"
        }
        
        if let prediction3 = predictions[3] {
            wavenetPro3Text = useMgdlUnits ? 
                String(format: "%.0f", prediction3 * 18.0) : 
                String(format: "%.1f", prediction3)
        } else {
            wavenetPro3Text = "—"
        }
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


    // View model (no parameters → safe to initialize here)
    @StateObject private var viewModel = ContentViewModel()
    
    // Track UI state
    @State private var isInitialized = false
    
    // Computed property for current CET time
    private var currentCETTime: String {
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: "Europe/Berlin")
        formatter.dateFormat = "HH:mm:ss 'CET'"
        return formatter.string(from: Date())
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
            .onAppear {
                if !isInitialized {
                    Task { 
                        await viewModel.initialize(with: modelContext)
                        isInitialized = true
                    }
                }
            }

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

} // End of SettingsView

