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

    var body: some View {
        VStack(spacing: 24) {
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
            
            // Create model input
            let input = ["input": featureValue]
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
            
            let val = multiArray[0].doubleValue
            if useMgdlUnits {
                predictText = String(format: "%.0f", val * 18.0) // mg/dL
            } else {
                predictText = String(format: "%.1f", val) // mmol/L
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
    // Next sync date (written when a sync is scheduled)
    @AppStorage("nextSyncDate")    private var nextSyncDate           = Date()
    // Blood glucose units preference
    @AppStorage("useMgdlUnits")    private var useMgdlUnits           = true
    // Field focus for keyboard management
    @FocusState private var focusedField: Field?
    private enum Field { case url, secret, token }

    // View model (no parameters → safe to initialize here)
    @StateObject private var viewModel = ContentViewModel()

    var body: some View {
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

            // Manual sync
            Button {
                Task {
                    do {
                        try await viewModel.handleManualSync()
                    } catch {
                        print("❌ Manual sync failed: \(error)")
                        viewModel.lastSyncResult = "Sync failed: \(error.localizedDescription)"
                    }
                }
            } label: {
                if viewModel.syncInProgress {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle())
                } else {
                    Text("Sync Now")
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

            Spacer()
        }
        .padding()
    }
}

@MainActor
class ContentViewModel: ObservableObject {
    @Published var syncInProgress = false
    @Published var lastSyncResult: String?


    func handleManualSync() async throws {
        syncInProgress = true
        defer { syncInProgress = false }

        // Get the count of new entries saved
        let savedCount = await SyncManager.shared.performSync(isBackground: false)
        // Provide detailed feedback based on what was actually saved
        if savedCount > 0 {
            lastSyncResult = "Successfully saved \(savedCount) new readings to HealthKit"
        } else {
            lastSyncResult = "Sync complete - No new data to save"
        }
    }

    func triggerSync() async throws -> Int {
        return await SyncManager.shared.performSync(isBackground: false)
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
        // Update the result message based on what was saved
        if savedCount > 0 {
            lastSyncResult = "Settings saved and \(savedCount) new readings synced to HealthKit"
        } else {
            lastSyncResult = "Settings saved. HealthKit is already up to date."
        }
    }
}
