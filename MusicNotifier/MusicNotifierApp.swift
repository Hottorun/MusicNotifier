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
import CloudKit
import MusicKit

@main
struct MusicNotifierApp: App {
    @State private var refreshCoordinator = RefreshCoordinator()
    @StateObject private var navigationDepth = TabNavigationDepth()
    @AppStorage(AppSettings.appearance) private var appearanceRaw: String = "system"
    @AppStorage(AppSettings.enableVideosTab) private var enableVideosTab = false
    @Environment(\.scenePhase) private var scenePhase

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

        // Defined once in `AppSchema` so the App Intents entry point can't
        // drift out of sync with this one — a subset schema opening the same
        // store silently drops the missing entities' tables.
        let schema = AppSchema.make()
        // iCloud-backed configuration. SwiftData mirrors the local store to the
        // user's private CloudKit DB so artists and releases sync across iPhone,
        // iPad, and Mac. Falls back to a local-only store on the catch path so
        // the app still launches if the container isn't reachable.
        let cloudConfiguration = AppSchema.cloudConfiguration(for: schema)

        // Try cloud → local → wipe-and-local. Each step logs why it fell through
        // so console logs show the actual schema/migration error.
        let localConfiguration = AppSchema.localConfiguration(for: schema)

        if let container = try? ModelContainer(for: schema, configurations: [cloudConfiguration]) {
            AppSchema.recordStoreBacking(isCloudKitBacked: true)
            Log.v("[HYDRATE] CloudKit-backed ModelContainer created OK (container=\(AppSchema.cloudKitContainerIdentifier))")
            // Diagnostic: count what's already in the store at launch.
            // Useful to tell apart "fresh install, CloudKit hasn't
            // delivered yet" vs "CloudKit delivered between launches".
            // Gated on `Log.verbose` because these are two full table
            // counts on the main context, on the cold-launch path, before
            // the first frame — pure cost for a release build.
            if Log.verbose {
                let ctx = container.mainContext
                let artistCount = (try? ctx.fetchCount(FetchDescriptor<ArtistData>())) ?? -1
                let releaseCount = (try? ctx.fetchCount(FetchDescriptor<ReleaseData>())) ?? -1
                Log.v("[HYDRATE] launch-time store contents: artists=\(artistCount) releases=\(releaseCount)")
            }
            return container
        } else {
            // Surfaced in Settings — see `AppSchema.storeIsCloudKitBacked`.
            AppSchema.recordStoreBacking(isCloudKitBacked: false)
            Log.v("[HYDRATE] CloudKit-backed container FAILED — falling back to local")
        }

        if let container = try? ModelContainer(for: schema, configurations: [localConfiguration]) {
            return container
        } else {
            Log.v("[ModelContainer] Local container failed; existing store is incompatible with new schema — wiping and retrying")
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

        // Start listening for CloudKit mirroring events before the container
        // is touched, so the very first setup event (the one that fails when
        // the CloudKit schema hasn't been deployed) isn't missed.
        MainActor.assumeIsolated { CloudSyncMonitor.shared.start() }

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
                .onChange(of: scenePhase) { _, newPhase in
                    // Flush any pending debounced SwiftData save before the
                    // app heads to background so we never lose a write.
                    if newPhase == .background || newPhase == .inactive {
                        Task { @MainActor in
                            ModelContextSaveDebouncer.shared.flush()
                        }
                    }
                    // Re-run dedup on every foreground transition. The launch
                    // run (in `.task` below) fires before CloudKit hydration
                    // arrives on a fresh install, so it misses duplicates
                    // caused by a local import racing the cloud pull. Running
                    // again on `.active` cleans those up the next time the
                    // user opens the app.
                    if newPhase == .active {
                        Task { @MainActor in
                            CloudSyncDeduplicator.run(in: sharedModelContainer.mainContext)
                        }
                        // Re-check MusicKit authorization on every foreground.
                        // The user can revoke library access from iOS Settings
                        // while the app is backgrounded; if that happened,
                        // refresh requests would silently fail. Stashing the
                        // current status in UserDefaults lets the existing
                        // "MusicKit unavailable" empty state pick it up.
                        Task {
                            await Self.verifyMusicLibraryAccess()
                        }
                    }
                }
                // CloudKit-driven remote changes can deliver an iSeen=true
                // copy of a release that already exists locally as
                // iSeen=false (because a refresh inserted it before iCloud
                // arrived). Without a dedup pass on remote-change, the
                // user keeps seeing the unread duplicate until they
                // background+foreground the app. Debounced so a sync
                // storm doesn't run dedup 100 times in a row.
                .onReceive(
                    NotificationCenter.default
                        .publisher(for: .NSPersistentStoreRemoteChange)
                        .debounce(for: .seconds(2), scheduler: RunLoop.main)
                ) { _ in
                    Task { @MainActor in
                        CloudSyncDeduplicator.run(in: sharedModelContainer.mainContext)
                    }
                }
                .task {
                    // Pre-warm CloudKit. Asking for `accountStatus`
                    // forces the CloudKit subsystem to validate the
                    // account + container at launch instead of lazily
                    // on first sync request — shaves a couple of
                    // seconds off the time-to-first-record on a fresh
                    // install. Result is discarded; we just want the
                    // side effect of CloudKit waking up early.
                    Task.detached(priority: .utility) {
                        _ = try? await CKContainer.default().accountStatus()
                    }
                    // Initial library-access check at launch — same flow as
                    // foreground re-checks. Re-requests if .notDetermined so
                    // a returning user with wiped permissions gets the prompt
                    // again instead of staring at a frozen feed.
                    Task {
                        await Self.verifyMusicLibraryAccess()
                    }
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
                // Gated on the same flag the tab bar / sidebar use. Videos was
                // always listed, so picking it while off (the default) silently
                // dropped the user back on the Feed.
                if enableVideosTab {
                    Button("Videos") { selectTab(3) }
                        .keyboardShortcut("4", modifiers: .command)
                }
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

    /// Check MusicKit authorization on launch and every foreground transition.
    /// Stores the resolved status under `AppSettings.lastKnownMusicAuthStatus`
    /// (rawValue) so the rest of the UI can react without each view having to
    /// call `MusicAuthorization.currentStatus` itself. Re-requests when the
    /// status is `.notDetermined` — covers users who skipped onboarding or
    /// whose authorization was reset.
    @MainActor
    private static func verifyMusicLibraryAccess() async {
        let initial = MusicAuthorization.currentStatus
        let resolved: MusicAuthorization.Status
        if initial == .notDetermined {
            resolved = await MusicAuthorization.request()
        } else {
            resolved = initial
        }
        UserDefaults.standard.set(resolved.rawValue, forKey: AppSettings.lastKnownMusicAuthStatus)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: AppSettings.lastKnownMusicAuthCheckedAt)
        switch resolved {
        case .authorized:
            Log.v("[Auth] MusicKit authorized")
        case .denied:
            Log.v("[Auth] MusicKit denied — refresh will fail until user re-authorizes in Settings")
        case .restricted:
            Log.v("[Auth] MusicKit restricted")
        case .notDetermined:
            Log.v("[Auth] MusicKit still notDetermined after request")
        @unknown default:
            Log.v("[Auth] MusicKit unknown status: \(resolved)")
        }
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
