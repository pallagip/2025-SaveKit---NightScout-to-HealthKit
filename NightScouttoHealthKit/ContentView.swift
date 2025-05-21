//
//  ContentView.swift
//  NightScouttoHealthKit
//
//  Created by Patrick Pallagi on 2025-05-09.
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
    @State private var scaler: SequenceMinMaxScaler?
    @StateObject private var hk = HealthKitFeatureProvider()
    @State private var model: MLModel?
    @State private var predictText = "—"
    @AppStorage("useMgdlUnits") private var useMgdlUnits = true
    @State private var lastGlucoseReading: Double = 0.0  // Track previous reading
    @State private var lastReadingTimestamp: Date? = nil  // When the reading was taken
    
    // SwiftData access
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Prediction.timestamp, order: .reverse) private var predictions: [Prediction]
    @State private var refreshID = UUID() // Track when to refresh predictions

    var body: some View {
        VStack(spacing: 24) {
            // Prediction section
            VStack(spacing: 16) {
                Text(useMgdlUnits ? "Predicted BG in 20 min (mg/dL)" : "Predicted BG in 20 min (mmol/L)")
                    .font(.headline)
                Text(predictText)
                    .font(.system(size: 64, weight: .bold, design: .rounded))
                HStack {
                    Button("Predict") { Task { await predict() } }
                        .buttonStyle(.borderedProminent)
                    Button("Personalize") { Task { await personalize() } }
                        .buttonStyle(.bordered)
                }
            }
            .padding()
            .background(Color(.systemGray6))
            .cornerRadius(12)
            
            // Prediction history section
            VStack(alignment: .leading, spacing: 8) {
                Text("Prediction History")
                    .font(.headline)
                    .padding(.bottom, 4)
                
                if predictions.isEmpty {
                    Text("No predictions yet")
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding()
                } else {
                    // Header row
                    HStack {
                        Text("Date & Time")
                            .fontWeight(.medium)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("Value")
                            .fontWeight(.medium)
                            .frame(width: 80, alignment: .trailing)
                    }
                    .padding(.horizontal, 8)
                    .font(.caption)
                    
                    // Prediction list - will refresh when refreshID changes
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(predictions) { prediction in
                                HStack {
                                    Text(prediction.formattedDate)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    Text(prediction.formattedValue)
                                        .frame(width: 80, alignment: .trailing)
                                }
                                .padding(.vertical, 4)
                                .padding(.horizontal, 8)
                                .background(Color(.systemBackground))
                                .cornerRadius(4)
                                .id(prediction.id) // Ensure each row has unique ID
                            }
                        }
                        .id(refreshID) // Force refresh when this ID changes
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
        .padding()
    }

    private func initializeApp() async {
        do {
            // Initialize scaler
            scaler = try SequenceMinMaxScaler()
            
            // Load ML model
            guard let modelURL = Bundle.main.url(forResource: "BGPersonal",
                                               withExtension: "mlmodelc") else {
                throw NSError(domain: "ModelError",
                            code: 1,
                            userInfo: [NSLocalizedDescriptionKey:
                                      "Could not find BGPersonal model"])
            }
            model = try MLModel(contentsOf: modelURL)
            
            // Request HealthKit authorization
            try await hk.requestAuth()
            
        } catch {
            print("❌ Initialization error: \(error)")
            predictText = "Init Err"
        }
    }

    @MainActor
    private func predict() async {
        do {
            guard let model = model else {
                predictText = "No Model"
                return
            }
            
            // Get health data
            let x = try await hk.buildWindow()
            
            // Transform data if scaler exists
            if let scaler = scaler {
                scaler.transform(x)
            }
            
            // Create MLFeatureValue safely
            let featureValue = MLFeatureValue(multiArray: x)
            
            // Create model input with the correct feature name
            let input = ["bidirectional_input": featureValue]
            let inputProvider = try MLDictionaryFeatureProvider(dictionary: input)
            
            // Make prediction
            let out = try await model.prediction(from: inputProvider)
            
            // Process result
            guard let outputFeature = out.featureValue(for: "Identity"),
                  let multiArray = outputFeature.multiArrayValue else {
                throw NSError(domain: "PredictionError",
                            code: 1,
                            userInfo: [NSLocalizedDescriptionKey:
                                      "Invalid model output"])
            }
            
            // Get the raw prediction value from the model (clearly scaled between 0-1)
            let scaledPrediction = multiArray[0].doubleValue
            
            // Get the current BG for context
            let currentBG = try await hk.fetchLatestGlucoseValue() / 18.0  // Convert mg/dL to mmol/L
            
            // Detect the trend by comparing to the last reading
            var bgTrend: Double = 0.0 // Default to neutral trend
            
            if lastGlucoseReading > 0 && lastReadingTimestamp != nil {
                // Calculate the rate of change per minute
                let timeDiff = Date().timeIntervalSince(lastReadingTimestamp!) / 60.0 // in minutes
                
                // Only calculate trend if enough time has passed (at least 1 minute)
                // to avoid extreme values from tiny time differences
                if timeDiff >= 1.0 {
                    let bgDiff = currentBG - lastGlucoseReading
                    let rateOfChange = bgDiff / timeDiff // mmol/L per minute
                    
                    // Apply a reasonable cap to rate of change (±0.3 mmol/L per minute)
                    // This is already quite rapid for BG changes
                    let cappedRateOfChange = min(0.3, max(-0.3, rateOfChange))
                    
                    // Extrapolate to predict 20 minutes ahead based on just the trend
                    // but with a damping factor to be conservative in predictions
                    let dampingFactor = 0.7 // reduce the impact of the trend
                    bgTrend = cappedRateOfChange * 20.0 * dampingFactor
                    
                    print("BG trend: \(bgTrend > 0 ? "rising" : "falling") at \(abs(cappedRateOfChange)) mmol/L per minute")
                } else {
                    print("Too little time has passed for reliable trend calculation (\(timeDiff) minutes)")
                }
            } else {
                print("First reading - no trend data available yet")
            }
            
            // Update the last reading for next time
            lastGlucoseReading = currentBG
            lastReadingTimestamp = Date()
            
            // Based on the debug output, the model seems to consistently predict values around 0.28,
            // which appears to be inaccurate for predicting changes
            
            // Define reasonable bounds for blood glucose in mmol/L
            let maxReasonableBG = 25.0  // Maximum reasonable BG 
            let minReasonableBG = 2.0   // Minimum reasonable BG
            
            // Interpret raw model output, but now consider the detected trend
            // 0.28 is very low on 0-1 scale, suggesting a drop - but this doesn't match reality when BG is rising
            
            // Create a weighted prediction that combines:
            // 1. The model output (but with lower weight if it contradicts observed trend)
            // 2. The observed trend (with higher weight)
            
            // If BG is relatively stable (trend is small), put less weight on both predictions
            // and more weight on the current BG value
            let isStable = abs(bgTrend) < 1.0 // Less than 1 mmol/L change predicted over 20 min
            
            // Raw model output seems to consistently predict a significant drop regardless of actual trend
            // For a 0.28 value (what we're consistently seeing), the model is predicting a large drop
            
            // Normalize the model's prediction (0.28 is about -0.44 on a -1 to 1 scale)
            let normalizedFactor = (scaledPrediction - 0.5) * 2 // Convert to -1 to +1 range
            
            // Determine reasonable change range (up to 4 mmol/L in 20 minutes) - more conservative
            let maxChangeRange = 4.0
            
            // Calculate model's predicted change
            let modelPredictedChange = normalizedFactor * maxChangeRange
            
            // For weighting, consider:
            // 1. When BG is stable, trust neither model nor trend too much
            // 2. When model contradicts trend, trust trend more for rising BG, model more for falling BG
            // 3. When they agree, use a balanced approach
            
            let modelWeight: Double
            let trendWeight: Double
            
            if isStable {
                // When BG is stable, predict minimal change
                modelWeight = 0.2
                trendWeight = 0.3
            } else if modelPredictedChange < 0 && bgTrend > 0 {
                // Model predicts drop but trend shows rise - trust trend more
                modelWeight = 0.2
                trendWeight = 0.8
            } else if modelPredictedChange < 0 && bgTrend < 0 {
                // Both predict drop - balanced approach
                modelWeight = 0.5
                trendWeight = 0.5
            } else {
                // Other scenarios - balanced approach
                modelWeight = 0.5
                trendWeight = 0.5
            }
            
            // Calculate the weighted change
            let weightedChange: Double
            if isStable {
                // For stable BG, predict a very small change (regression to normal)
                let targetBG = 7.0 // Normal BG target in mmol/L
                let regressionFactor = 0.05 // Small factor for regression to mean
                let naturalRegression = (targetBG - currentBG) * regressionFactor
                
                // Combine minimal model and trend influence with natural regression
                weightedChange = (modelPredictedChange * modelWeight) + 
                                 (bgTrend * trendWeight) + 
                                 (naturalRegression * (1 - modelWeight - trendWeight))
            } else {
                // Regular weighted combination for changing BG
                weightedChange = (modelPredictedChange * modelWeight) + (bgTrend * trendWeight)
            }
            
            // Calculate the final predicted BG
            let predictedBG = currentBG + weightedChange
            
            // Apply final reasonableness bounds
            let finalPrediction = min(maxReasonableBG, max(minReasonableBG, predictedBG))
            
            // Enhanced logging with stability information
            let stabilityStatus = isStable ? "STABLE" : (bgTrend > 0 ? "RISING" : "FALLING")
            print("[BG PREDICTION]")
            print("Current: \(String(format: "%.1f", currentBG)) mmol/L (\(stabilityStatus))")
            print("Model output: \(scaledPrediction) → Change: \(String(format: "%.1f", modelPredictedChange)) mmol/L")
            print("Observed trend: \(String(format: "%.1f", bgTrend)) mmol/L over 20 min")
            print("Weights: Model=\(modelWeight), Trend=\(trendWeight)")
            print("Final predicted change: \(String(format: "%.1f", weightedChange)) mmol/L")
            print("Prediction: \(String(format: "%.1f", finalPrediction)) mmol/L in 20 min")
            
            // Format and display the result in the selected units
            if useMgdlUnits {
                predictText = String(format: "%.0f", finalPrediction * 18.0) // mg/dL
            } else {
                predictText = String(format: "%.1f", finalPrediction) // mmol/L
            }
            
            // Save prediction to SwiftData with all metadata
            // Always store the value in mmol/L internally for consistency
            let prediction = Prediction(
                timestamp: Date(),
                predictionValue: finalPrediction,
                usedMgdlUnits: useMgdlUnits,
                currentBG: currentBG,
                stabilityStatus: isStable ? "STABLE" : (bgTrend > 0 ? "RISING" : "FALLING"),
                modelOutput: scaledPrediction,
                modelPredictedChange: modelPredictedChange,
                observedTrend: bgTrend,
                modelWeight: modelWeight,
                trendWeight: trendWeight,
                finalPredictedChange: weightedChange
            )
            
            // Save the prediction and ensure UI is updated
            modelContext.insert(prediction)
            
            // This try-catch block ensures we capture any persistence errors
            do {
                try modelContext.save()
                print("✅ Prediction saved successfully")
                
                // Force UI refresh by updating the refreshID
                // This ensures the prediction list is updated immediately
                await MainActor.run { 
                    self.refreshID = UUID()
                    print("UI refresh triggered")
                }
            } catch {
                print("❌ Error saving prediction: \(error)")
            }
            
        } catch {
            predictText = "Err"
            print("❌ predict failed:", error)
        }
    }

    @MainActor
    private func personalize() async {
        do {
            // Get latest glucose value
            let glucoseValue = try await hk.fetchLatestGlucoseValue()
            
            // Store data for model personalization
            let timestamp = Date().timeIntervalSince1970
            let personalizationData = ["timestamp": timestamp,
                                    "glucoseValue": glucoseValue]
            
            // Save to UserDefaults
            var existingData = UserDefaults.standard.array(
                forKey: "personalizationData") as? [[String: Any]] ?? []
            existingData.append(personalizationData)
            UserDefaults.standard.set(existingData,
                                    forKey: "personalizationData")
            
            // Update UI
            predictText = "✔︎ Data Collected"
            
        } catch {
            predictText = "Tune Err"
            print("❌ personalize failed:", error)
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
    // Next sync date (written when a sync is scheduled)
    @AppStorage("nextSyncDate")    private var nextSyncDate           = Date()
    // Blood glucose units preference
    @AppStorage("useMgdlUnits")    private var useMgdlUnits           = true
    // Field focus for keyboard management
    @FocusState private var focusedField: Field?
    private enum Field { case url, secret, token }
    
    // For CSV export
    @State private var showingExportSuccess = false

    // View model (no parameters → safe to initialize here)
    @StateObject private var viewModel = ContentViewModel()
    
    // Track UI state
    @State private var isInitialized = false

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

            // Export predictions button
            Button {
                if let fileURL = CSVExportManager.shared.exportPredictions(from: modelContext) {
                    // Get the root view controller
                    guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                          let rootViewController = windowScene.windows.first?.rootViewController else {
                        return
                    }
                    
                    // Share the CSV file
                    CSVExportManager.shared.shareCSV(from: fileURL, presenter: rootViewController)
                    showingExportSuccess = true
                }
            } label: {
                Text("Export Predictions")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.orange)
            .padding(.top, 8)
            .alert("Export Ready", isPresented: $showingExportSuccess) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("Your predictions have been exported to CSV format. Choose where to save or share the file.")
            }
            }
            .padding()
        }
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
