//
//  SyncManager.swift
//  NightScouttoHealthKit
//
//  Created by Patrick Pallagi on 2025-05-13.
//  Rewritten by ChatGPT on 2025-05-16.
//

import Foundation
import BackgroundTasks
import UIKit

/// Central manager that keeps Nightscout → HealthKit in sync
final class SyncManager {
    // MARK: - Singleton

    static let shared = SyncManager()
    private init() {
        // Observe entering background to reschedule tasks
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Configuration

    /// How often (at minimum) we want to sync
    private let syncInterval: TimeInterval = 20 * 60 // 20 minutes

    /// Identifiers must match those you register in AppDelegate
    private let refreshTaskId = "com.ProDiabeticsTeam.NightScouttoHealthKitv1"
    private let processingTaskId = "com.ProDiabeticsTeam.NightScouttoHealthKitv1.processing"

    // MARK: - State Tracking

    /// Last successful sync timestamp persisted so it survives relaunch
    private var lastSyncDate: Date? {
        get { UserDefaults.standard.object(forKey: "lastSyncDate") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "lastSyncDate") }
    }
    
    /// Time interval since the last successful sync
    var timeSinceLastSync: TimeInterval {
        guard let last = lastSyncDate else { return .infinity }
        return Date().timeIntervalSince(last)
    }

    private var isSyncInProgress = false
    private var foregroundTimer: Timer?

    // MARK: - Public API

    /// Call once at app startup (e.g. in AppDelegate) to kick everything off
    func start() {
        registerBackgroundTasks()
        scheduleNextRefresh()
    }
    
    /// Start the foreground timer if it's not already running
    func startTimerIfNeeded() {
        if foregroundTimer == nil {
            startForegroundTimer()
        }
    }
    
    /// Stop the foreground timer
    func stopTimer() {
        foregroundTimer?.invalidate()
        foregroundTimer = nil
    }
    
    /// Calculate time until next sync is due
    func timeUntilNextSync() -> TimeInterval {
        return max(syncInterval - timeSinceLastSync, 0)
    }

    // MARK: - Foreground Sync

    /// A short‐interval timer (fires every minute) to top up while the app is running
    private func startForegroundTimer() {
        foregroundTimer?.invalidate()
        foregroundTimer = Timer.scheduledTimer(
            timeInterval: 60,
            target: self,
            selector: #selector(foregroundTimerFired),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(foregroundTimer!, forMode: .common)
    }

    @objc private func foregroundTimerFired() {
        guard shouldSyncNow else { return }
        Task { await performSync(isBackground: false) }
    }

    /// Whether enough time has passed that we should sync again
    private var shouldSyncNow: Bool {
        return timeSinceLastSync >= syncInterval
    }

    // MARK: - Background Task Scheduling

    private func registerBackgroundTasks() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: refreshTaskId,
            using: nil
        ) { [weak self] task in
            guard let self = self else { return }
            Task {
                await self.handleBackgroundRefresh(task: task as! BGAppRefreshTask)
            }
        }
    }
    
    /// Schedule next background refresh task
    func scheduleNextRefresh() {
        // Always cancel pending so we don't double‐book
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: refreshTaskId)

        // App Refresh (~every 20 min)
        let refreshRequest = BGAppRefreshTaskRequest(identifier: refreshTaskId)
        refreshRequest.earliestBeginDate = Date(timeIntervalSinceNow: syncInterval)
        do {
            try BGTaskScheduler.shared.submit(refreshRequest)
            print("✅ Scheduled BGAppRefreshTaskRequest")
        } catch {
            print("❌ Failed to schedule BGAppRefreshTaskRequest: \(error)")
        }
    }

    @objc private func appDidEnterBackground() {
        // Whenever we go background, make sure tasks are queued
        scheduleNextRefresh()
    }

    // MARK: - Background Task Handling

    /// Handle background refresh task
    private func handleBackgroundRefresh(task: BGAppRefreshTask) async {
        // Immediately schedule the next one
        scheduleNextRefresh()

        // Perform a sync
        let work = Task {
            await performSync(isBackground: true)
            task.setTaskCompleted(success: true)
        }

        task.expirationHandler = {
            work.cancel()
            task.setTaskCompleted(success: false)
        }
    }

    // MARK: - Core Sync Logic

    /// Trigger a sync. Returns number of new entries (if you care).
    @discardableResult
    func performSync(isBackground: Bool, extended: Bool = false) async -> Int {
        guard !isSyncInProgress else { return 0 }
        isSyncInProgress = true
        defer { isSyncInProgress = false }

        do {
            let coordinator = makeCoordinator()
            let lookbackMinutes = isBackground ? 40 : 20

            return try await coordinator.performSync(minutes: lookbackMinutes)
        } catch {
            print("Sync failed: \(error)")
            return 0
        }
    }

    private func makeCoordinator() -> SyncCoordinator {
        let defs   = UserDefaults.standard
        let base   = defs.string(forKey: "nightscoutBaseURL") ?? ""
        let url    = URL(string: base) ?? URL(string: "https://example.com")!
        let secret = defs.string(forKey: "apiSecret") ?? ""
        let token  = defs.string(forKey: "apiToken") ?? ""

        let service = NightscoutService(baseURL: url, apiSecret: secret, apiToken: token)
        return SyncCoordinator(nightscoutService: service,
                               healthKitManager: HealthKitManager())
    }
}

// MARK: - Sync Timer Notification

extension Notification.Name {
    /// Fired whenever the next‐sync countdown or lastSyncDate has changed
    static let syncTimerUpdated = Notification.Name("syncTimerUpdated")
}
