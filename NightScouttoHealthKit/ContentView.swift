//
//  ContentView.swift
//  NightScouttoHealthKit
//
//  Created by Patrick Pallagi on 2025-05-09.
//

import SwiftUI
import BackgroundTasks
import UIKit

struct ContentView: View {
    // Persisted settings
    @AppStorage("nightscoutBaseURL") private var nightscoutBaseURLString = ""
    @AppStorage("apiSecret")       private var apiSecret               = ""
    @AppStorage("apiToken")        private var apiToken                = ""
    // Next sync date (written when a sync is scheduled)
    @AppStorage("nextSyncDate")    private var nextSyncDate           = Date()
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

            // Save settings & schedule next sync
            Button("Save Settings") {
                focusedField = nil
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                                to: nil, from: nil, for: nil)
                Task {
                    do {
                        try await viewModel.saveSettings()
                        await viewModel.scheduleNextSync()
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
                Task { await viewModel.handleManualSync() }
            } label: {
                if viewModel.syncInProgress {
                    ProgressView().progressViewStyle(CircularProgressViewStyle())
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

            // Countdown
            CountdownView(targetDate: nextSyncDate)
                .frame(maxWidth: .infinity)
                .padding(.top, 8)

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
        .onAppear { viewModel.startTimer() }
        .onDisappear { viewModel.stopTimer() }
    }
}

@MainActor
class ContentViewModel: ObservableObject {
    @Published var syncInProgress = false
    @Published var lastSyncResult: String?
    private var timer: Timer?

    init() {}

    func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            Task { await self.checkAndPerformAutoSync() }
        }
    }

    func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func checkAndPerformAutoSync() async {
        let next = UserDefaults.standard.object(forKey: "nextSyncDate") as? Date ?? .distantPast
        guard Date() >= next, !syncInProgress else { return }
        await handleManualSync()
    }

    func handleManualSync() async {
        syncInProgress = true
        defer { syncInProgress = false }

        do {
            try await triggerSync()
            lastSyncResult = "Sync completed successfully"
        } catch {
            print("⚠️ Manual sync failed: \(error)")
            lastSyncResult = "Sync failed: \(error.localizedDescription)"
        }
    }

    func triggerSync() async throws {
        print("🔄 Manual sync triggered")
        let defaults = UserDefaults.standard
        guard
            let urlString = defaults.string(forKey: "nightscoutBaseURL"),
            let url       = URL(string: urlString)
        else {
            print("⚠️ Cannot sync: Invalid URL")
            throw URLError(.badURL)
        }
        let secret = defaults.string(forKey: "apiSecret") ?? ""
        let token  = defaults.string(forKey: "apiToken")  ?? ""

        print("🔄 Starting sync with URL: \(url)")
        let coordinator = SyncCoordinator(
            nightscoutService: NightscoutService(baseURL: url,
                                                 apiSecret: secret,
                                                 apiToken:  token),
            healthKitManager: HealthKitManager()
        )
        try await coordinator.performSync()
        await scheduleNextSync()
    }

    func scheduleNextSync() async {
        let next = Date().addingTimeInterval(5 * 60) // 5 min
        print("📅 Next sync scheduled for: \(next)")
        UserDefaults.standard.set(next, forKey: "nextSyncDate")
    }

    func saveSettings() async throws {
        let defaults = UserDefaults.standard
        guard
            let urlString = defaults.string(forKey: "nightscoutBaseURL"),
            let url       = URL(string: urlString)
        else {
            print("⚠️ Invalid URL")
            throw URLError(.badURL)
        }
        print("🔧 Saving settings – URL: \(url)")
        try await HealthKitManager().requestAuthorization()
        print("✅ HealthKit authorization successful")
    }
}

struct CountdownView: View {
    let targetDate: Date
    @State private var now = Date()
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var timeRemaining: TimeInterval {
        max(targetDate.timeIntervalSince(now), 0)
    }

    private func formattedRemaining() -> String {
        let total   = Int(timeRemaining)
        let minutes = total / 60
        let seconds = total % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    var body: some View {
        VStack {
            Text("Next automatic sync in")
                .font(.caption)
                .foregroundColor(.secondary)
            Text(formattedRemaining())
                .font(.largeTitle.monospacedDigit())
                .foregroundColor(timeRemaining < 10 ? .red : .primary)
        }
        .onReceive(timer) { now = $0 }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(10)
    }
}

// The background‐refresh task identifier
fileprivate let refreshTaskID = "com.ProDiabeticsTeam.NightScouttoHealthKit.refresh"
