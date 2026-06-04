//
//  MusicNotifierApp.swift
//  MusicNotifier
//
//  Created by Dimitris Kern on 28.07.25.
//

import SwiftUI
import SwiftData
import BackgroundTasks
import UserNotifications
import WidgetKit

@main
struct MusicNotifierApp: App {
    @State private var refreshCoordinator = RefreshCoordinator()
    @StateObject private var navigationDepth = TabNavigationDepth()
    @AppStorage(AppSettings.appearance) private var appearanceRaw: String = "system"

    private var preferredScheme: ColorScheme? {
        switch appearanceRaw {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }
    private let notificationDelegate = ForegroundNotificationDelegate()

    var sharedModelContainer: ModelContainer = {
        // SwiftData + CloudKit writes its store inside the app-group container's
        // Application Support directory. On a fresh install that directory
        // doesn't exist yet and Core Data logs a wall of `Failed to stat path`
        // errors before it falls back to creating the parent itself. Pre-creating
        // it ourselves silences that noise — first-launch logs are dramatically
        // shorter and we save a few synchronous filesystem retries.
        if let groupURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppSettings.appGroupIdentifier) {
            let supportDir = groupURL.appending(path: "Library/Application Support")
            try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        }

        let schema = Schema([
            Item.self,
            ArtistData.self,
            ReleaseData.self,
            VideoData.self,
            ConcertData.self,
        ])
        // iCloud-backed configuration. SwiftData mirrors the local store to the
        // user's private CloudKit DB so artists and releases sync across iPhone,
        // iPad, and Mac. Falls back to a local-only store on the catch path so
        // the app still launches if the container isn't reachable.
        let cloudConfiguration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            cloudKitDatabase: .private("iCloud.com.kern.functional.MusicNotifier")
        )

        // Try cloud → local → wipe-and-local. Each step prints why it fell through
        // so console logs show the actual schema/migration error.
        let localConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        if let container = try? ModelContainer(for: schema, configurations: [cloudConfiguration]) {
            return container
        } else {
            print("[ModelContainer] CloudKit-backed container failed; trying local")
        }

        if let container = try? ModelContainer(for: schema, configurations: [localConfiguration]) {
            return container
        } else {
            print("[ModelContainer] Local container failed; existing store is incompatible with new schema — wiping and retrying")
        }

        // Last resort: nuke the local store and rebuild fresh. Loses artists/releases
        // but the next refresh will repopulate everything from MusicKit, and a
        // running app beats a hard fatalError.
        resetSwiftDataStore()
        do {
            return try ModelContainer(for: schema, configurations: [localConfiguration])
        } catch {
            fatalError("Could not create ModelContainer even after wipe: \(error)")
        }
    }()

    init() {
        // Critical: without setting a delegate, foreground notifications (including the
        // "Send test notification" button and same-day release alerts) are silently dropped.
        UNUserNotificationCenter.current().delegate = notificationDelegate

        // URLCache.shared defaults to 20MB on disk — far too small for a feed
        // full of artwork. Bumping it means cold launches paint cached covers
        // from disk instead of re-downloading them.
        URLCache.shared = URLCache(
            memoryCapacity: 32 * 1024 * 1024,
            diskCapacity: 256 * 1024 * 1024
        )
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(refreshCoordinator)
                .environmentObject(navigationDepth)
                .preferredColorScheme(preferredScheme)
                .task {
                    BackgroundRefreshScheduler.scheduleDailyRefresh()
                    // Force the widget extension to re-evaluate its timeline on
                    // every app launch — guarantees our MN-WIDGET logs fire and
                    // any data refreshed since last reload becomes visible.
                    WidgetCenter.shared.reloadAllTimelines()
                    // CloudKit mirroring can produce duplicate rows when two
                    // devices import the same artist before sync settles —
                    // merge them on every launch.
                    CloudSyncDeduplicator.run(in: sharedModelContainer.mainContext)
                }
        }
        .modelContainer(sharedModelContainer)
        .backgroundTask(.appRefresh(BackgroundRefreshScheduler.taskIdentifier)) {
            await BackgroundRefreshScheduler.handleAppRefresh(modelContainer: sharedModelContainer)
        }
        // Reasonable starting window for Mac Catalyst — wide enough to hold the
        // sidebar + a comfortable detail column without horizontal cramping.
        .defaultSize(width: 1180, height: 760)
        // Menu-bar items + ⌘ shortcuts for Mac / iPad hardware keyboards. We
        // post Notifications instead of binding state across the Scene/App
        // boundary; ContentView already listens and forwards to the same
        // selection / refresh / settings paths the UI uses.
        .commands {
            CommandGroup(replacing: .newItem) {} // suppress unused "New Window"

            // `replacing:` instead of `after:` — Catalyst auto-installs its
            // own "MusicNotifier > Settings…" menu item bound to ⌘, and the
            // `after:` variant *adds* a second one, which makes UIKit throw
            // "Replacement elements contain duplicates" the moment a
            // responder chain installs keyboard shortcuts (e.g. when the
            // search sheet's text field comes up). `replacing:` swaps the
            // platform default with our own action.
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    NotificationCenter.default.post(name: .musicNotifierOpenSettings, object: nil)
                }
                .keyboardShortcut(",", modifiers: .command)
            }

            CommandMenu("Go") {
                Button("Feed") { selectTab(0) }
                    .keyboardShortcut("1", modifiers: .command)
                Button("Upcoming") { selectTab(1) }
                    .keyboardShortcut("2", modifiers: .command)
                Button("Artists") { selectTab(2) }
                    .keyboardShortcut("3", modifiers: .command)
                Button("Videos") { selectTab(3) }
                    .keyboardShortcut("4", modifiers: .command)
                Button("Concerts") { selectTab(4) }
                    .keyboardShortcut("5", modifiers: .command)
                Divider()
                Button("Refresh") {
                    NotificationCenter.default.post(name: .musicNotifierRequestRefresh, object: nil)
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }
    }

    private func selectTab(_ tag: Int) {
        NotificationCenter.default.post(name: .musicNotifierSelectTab, object: tag)
    }
}

/// Delete the SwiftData store files. Called as a last-resort recovery when the
/// existing store can't be opened with the current schema (CloudKit mirroring
/// requirements changed the model). Always available — not DEBUG-only — because
/// schema mismatches happen on TestFlight + release upgrades too.
private func resetSwiftDataStore() {
    let fileManager = FileManager.default
    let supportDirectory = URL.applicationSupportDirectory
    let storeNames = [
        "default.store",
        "default.store-shm",
        "default.store-wal"
    ]

    for storeName in storeNames {
        let url = supportDirectory.appending(path: storeName)
        if fileManager.fileExists(atPath: url.path) {
            try? fileManager.removeItem(at: url)
        }
    }
}
