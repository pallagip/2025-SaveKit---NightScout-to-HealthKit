//
// NightScouttoHealthKitApp.swift
// NightScouttoHealthKit
//
// Created by Patrick Pallagi on 2025-05-09.
//

import SwiftUI
import SwiftData
import UIKit
import BackgroundTasks

// MARK: - BGTask Identifiers
fileprivate let refreshTaskID = "com.ProDiabeticsTeam.NightScouttoHealthKitv1"
fileprivate let processingTaskID = "com.ProDiabeticsTeam.NightScouttoHealthKit.processing"

@main
struct NightScouttoHealthKitApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .modelContainer(for: [Item.self])
        }
    }
}

final class AppDelegate: UIResponder, UIApplicationDelegate {
    // MARK: - UIApplicationDelegate

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        return true
    }


}

// MARK: - SwiftData Model
@Model
final class Item: Identifiable {
    @Attribute(.unique) var id: UUID = UUID()
    var title: String
    init(title: String) {
        self.title = title
    }
}
