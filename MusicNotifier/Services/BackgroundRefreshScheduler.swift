//
//  BackgroundRefreshScheduler.swift
//  MusicNotifier
//

import BackgroundTasks
import Foundation
import SwiftData

enum BackgroundRefreshScheduler {
    /// Max artists to check in one background run. Background time budget is ~30s,
    /// so we cap so we never blow it. Remaining artists are picked up next run via the cursor.
    private static let maxArtistsPerBackgroundRun = 40
    private static let cursorKey = "backgroundRefreshArtistCursor"

    static var taskIdentifier: String {
        "\(Bundle.main.bundleIdentifier ?? "functional.MusicNotifier").release-refresh"
    }

    static func scheduleDailyRefresh() {
        #if targetEnvironment(simulator)
        // BGTaskScheduler always returns "unavailable" on simulator — skip the
        // call so it doesn't spam the console with a misleading error every
        // launch. Real devices go through the normal submit path below.
        return
        #else
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        // iOS treats this as an earliest-time floor, not a target. 2 hours
        // gives the system roughly 2–3 firing opportunities through a normal
        // day (morning, midday, evening) instead of the previous 1–2 with a
        // 4-hour floor — matches the user's "another refresh somewhere in
        // the afternoon" ask without needing a second task identifier.
        request.earliestBeginDate = Date().addingTimeInterval(2 * 60 * 60)

        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Code 3 (Unavailable) is expected when Background App Refresh is
            // disabled in iOS Settings or Low Power Mode is on. Don't print it —
            // only print unexpected failures.
            let nsError = error as NSError
            if nsError.domain != "BGSystemTaskSchedulerErrorDomain" || nsError.code != 3 {
                print("Could not schedule background refresh: \(error)")
            }
        }
        #endif
    }

    @MainActor
    static func handleAppRefresh(modelContainer: ModelContainer) async {
        // Re-arm immediately so iOS keeps scheduling us.
        scheduleDailyRefresh()

        let modelContext = modelContainer.mainContext
        let descriptor = FetchDescriptor<ArtistData>(
            predicate: #Predicate { artist in
                artist.isTracked
            },
            sortBy: [SortDescriptor(\.name)]
        )

        let trackedArtists = (try? modelContext.fetch(descriptor)) ?? []
        guard !trackedArtists.isEmpty else {
            return
        }

        let defaults = UserDefaults.standard
        defaults.set(Date().timeIntervalSince1970, forKey: AppSettings.lastBackgroundRefreshAt)

        // Round-robin: each background run handles up to `maxArtistsPerBackgroundRun` artists,
        // starting where the previous run left off.
        let cursor = max(0, defaults.integer(forKey: cursorKey)) % max(trackedArtists.count, 1)
        let endIndex = min(cursor + maxArtistsPerBackgroundRun, trackedArtists.count)
        var batch = Array(trackedArtists[cursor..<endIndex])

        // Wrap to the start if we have remaining headroom in this run.
        let remaining = maxArtistsPerBackgroundRun - batch.count
        if remaining > 0 && cursor > 0 {
            let wrapEnd = min(remaining, cursor)
            batch.append(contentsOf: trackedArtists[0..<wrapEnd])
        }

        let nextCursor = (cursor + batch.count) % trackedArtists.count
        defaults.set(nextCursor, forKey: cursorKey)

        let hour = defaults.object(forKey: AppSettings.releaseNotificationHour) as? Int ?? 8
        let minute = defaults.object(forKey: AppSettings.releaseNotificationMinute) as? Int ?? 0
        let notificationsEnabled = defaults.object(forKey: AppSettings.notificationsEnabled) as? Bool ?? true

        let summary = await ReleaseRefreshService().refreshReleases(
            for: batch,
            in: modelContext,
            scheduleNotifications: notificationsEnabled,
            notificationHour: hour,
            notificationMinute: minute
        )

        let message = "BG \(cursor)–\(cursor + batch.count) of \(trackedArtists.count): \(summary.message)"
        defaults.set(message, forKey: AppSettings.lastBackgroundRefreshResult)
    }
}
