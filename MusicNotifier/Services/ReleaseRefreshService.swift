//
//  ReleaseRefreshService.swift
//  MusicNotifier
//

import Foundation
import SwiftData

enum RefreshPhase: String, Sendable {
    case warming = "Connecting…"
    case releases = "Checking releases"
    case videos = "Checking videos"
    case concerts = "Checking concerts"
    case finishing = "Finishing up"
}

struct ReleaseRefreshProgress: Sendable {
    let checkedArtists: Int
    let totalArtists: Int
    let currentArtistName: String
    var phase: RefreshPhase = .releases
    /// When true, render an indeterminate sweep — `checkedArtists`/`totalArtists` are
    /// not meaningful for this phase (video / concert tail).
    var isIndeterminate: Bool = false

    var fractionCompleted: Double {
        guard totalArtists > 0 else { return 0 }
        return Double(checkedArtists) / Double(totalArtists)
    }
}

struct ReleaseRefreshSummary {
    let newReleaseCount: Int
    let updatedReleaseCount: Int
    let checkedArtists: Int
    let totalArtists: Int
    let failures: [String]

    var message: String {
        var text = "Checked \(checkedArtists)/\(totalArtists) artists. Found \(newReleaseCount) new releases."
        if let firstFailure = failures.first {
            text += " \(failures.count) searches failed. First: \(firstFailure)"
        }
        return text
    }
}

struct ReleaseRefreshService {
    /// Off-main: perform the actual MusicKit fetch. Does not touch SwiftData.
    func fetch(
        inputs: [ArtistFetchInput],
        progress: (@Sendable (ReleaseRefreshProgress) -> Void)? = nil
    ) async -> ReleaseFetchResult {
        let appleInputs = inputs.filter { MusicProvider.fromStoredName($0.provider) == .appleMusic }
        let spotifyInputs = inputs.filter { MusicProvider.fromStoredName($0.provider) == .spotify }

        var releases: [FetchedRelease] = []
        var failures: [String] = []
        var resolvedCatalogIDs: [String: String] = [:]
        var resolvedArtworkURLs: [String: URL] = [:]
        var checkedArtists = 0

        if !appleInputs.isEmpty {
            let progressOffset = checkedArtists
            let result = await AppleMusicReleaseService().fetchReleases(for: appleInputs) { checked, _, name in
                progress?(
                    ReleaseRefreshProgress(
                        checkedArtists: progressOffset + checked,
                        totalArtists: inputs.count,
                        currentArtistName: name
                    )
                )
            }
            releases.append(contentsOf: result.releases)
            failures.append(contentsOf: result.failures)
            resolvedCatalogIDs.merge(result.resolvedCatalogIDs) { _, new in new }
            resolvedArtworkURLs.merge(result.resolvedArtworkURLs) { _, new in new }
            checkedArtists += result.checkedArtists
        }

        for input in spotifyInputs {
            if Task.isCancelled { break }
            progress?(
                ReleaseRefreshProgress(
                    checkedArtists: checkedArtists,
                    totalArtists: inputs.count,
                    currentArtistName: input.name
                )
            )

            let outcome = await SpotifyService().fetchOne(input)
            checkedArtists += 1
            releases.append(contentsOf: outcome.releases)
            if let error = outcome.errorMessage {
                failures.append("\(input.name): \(error)")
            }

            progress?(
                ReleaseRefreshProgress(
                    checkedArtists: checkedArtists,
                    totalArtists: inputs.count,
                    currentArtistName: input.name
                )
            )
        }

        return ReleaseFetchResult(
            releases: releases,
            failures: failures,
            checkedArtists: checkedArtists,
            totalArtists: inputs.count,
            resolvedCatalogIDs: resolvedCatalogIDs,
            resolvedArtworkURLs: resolvedArtworkURLs,
            storefrontCountryCode: nil
        )
    }

    /// MainActor entry point. Touches only the small main-context state that
    /// the rest of the UI directly observes (tracked-artist catalog IDs,
    /// artwork URLs, lastCheckedAt). All ReleaseData upsert work — the
    /// potentially-hundreds-of-rows hot loop, the `modelContext.save()`
    /// SQLite commit, the widget snapshot build, and the spec collection
    /// for notifications — is delegated to `ReleaseUpsertActor` running on
    /// a background executor with its own ModelContext.
    @MainActor
    func apply(
        result: ReleaseFetchResult,
        trackedArtists: [ArtistData],
        modelContext: ModelContext,
        scheduleNotifications: Bool,
        notificationHour: Int,
        notificationMinute: Int
    ) async -> ReleaseRefreshSummary {
        let now = Date()
        let defaults = UserDefaults.standard
        defaults.set(now.timeIntervalSince1970, forKey: AppSettings.lastRefreshAt)
        if let storefront = result.storefrontCountryCode {
            defaults.set(storefront, forKey: AppSettings.lastStorefrontCountryCode)
        }

        // Artist metadata used to be written + saved on the main context
        // here, separately from the actor's release save — producing two
        // distinct @Query invalidations per refresh. We now bundle the
        // updates into the actor's transaction so the UI sees a single
        // commit at end-of-refresh.
        let artistUpdates = ReleaseUpsertActor.ArtistUpdates(
            resolvedCatalogIDs: result.resolvedCatalogIDs,
            resolvedArtworkURLs: result.resolvedArtworkURLs,
            trackedProviderIDs: trackedArtists.map(\.providerID)
        )

        let notificationsEnabled = defaults.object(forKey: AppSettings.notificationsEnabled) as? Bool ?? true
        let upcomingNotificationsEnabled = defaults.object(forKey: AppSettings.upcomingReleaseNotificationsEnabled) as? Bool ?? true
        let sameDaySummaryEnabled = defaults.object(forKey: AppSettings.sameDayReleaseSummaryEnabled) as? Bool ?? true
        let globalPreference = ArtistNotificationPreference(
            rawValue: defaults.string(forKey: AppSettings.globalNotificationReleasePreference) ?? ArtistNotificationPreference.all.rawValue
        ) ?? .all
        let preferenceByArtist = Dictionary(uniqueKeysWithValues: trackedArtists.map {
            ($0.providerID, ArtistNotificationPreference(rawValue: $0.notificationPreference) ?? .inherit)
        })
        let genresByArtistID = Dictionary(
            uniqueKeysWithValues: trackedArtists.map { ($0.providerID, $0.genres ?? []) }
        )

        // Hand the heavy upsert off the main thread. The actor owns its own
        // ModelContext on a background executor; the ModelContainer is shared
        // so SwiftData propagates the save back to the main context's @Query
        // observers. Everything we get back is Sendable.
        let actor = ReleaseUpsertActor(modelContainer: modelContext.container)
        let upsert = await actor.apply(
            fetchedReleases: result.releases,
            now: now,
            sameDaySummaryEnabled: scheduleNotifications && notificationsEnabled && sameDaySummaryEnabled,
            upcomingEnabled: scheduleNotifications && notificationsEnabled && upcomingNotificationsEnabled,
            context: ReleaseUpsertActor.PerArtistContext(
                preferenceByArtist: preferenceByArtist,
                genresByArtist: genresByArtistID,
                globalPreference: globalPreference
            ),
            artistUpdates: artistUpdates
        )

        if let storageFailure = upsert.storageFailure {
            return ReleaseRefreshSummary(
                newReleaseCount: upsert.newReleaseCount,
                updatedReleaseCount: upsert.updatedReleaseCount,
                checkedArtists: result.checkedArtists,
                totalArtists: result.totalArtists,
                failures: result.failures + ["Storage: \(storageFailure)"]
            )
        }
        defaults.set(now.timeIntervalSince1970, forKey: AppSettings.lastSuccessfulRefreshAt)

        // Notifications — UNUserNotificationCenter authorization needs to be
        // requested on main (it can show UI), but the actual `add` calls run
        // detached so the daemon round-trips don't pile up serially.
        if scheduleNotifications && notificationsEnabled
            && (!upsert.summarySpecs.isEmpty || !upsert.upcomingSpecs.isEmpty) {
            _ = await NotificationScheduler().requestAuthorization()
            let summarySnapshot = upsert.summarySpecs
            let upcomingSnapshot = upsert.upcomingSpecs
            let hour = notificationHour
            let minute = notificationMinute
            Task.detached(priority: .utility) {
                let scheduler = NotificationScheduler()
                if !summarySnapshot.isEmpty {
                    await scheduler.scheduleReleaseSummaryNotification(specs: summarySnapshot)
                }
                for spec in upcomingSnapshot {
                    await scheduler.scheduleReleaseDayNotification(spec: spec, hour: hour, minute: minute)
                    await scheduler.schedulePreReleaseAlerts(spec: spec, hour: hour, minute: minute)
                }
            }
        }

        // Widget snapshot — encode + disk write + timeline reload detached.
        let widgetSnapshot = upsert.widgetSnapshot
        let artworkRequests = upsert.widgetRequests
        Task.detached(priority: .utility) {
            WidgetSnapshotWriter.persist(snapshot: widgetSnapshot)
            await WidgetSnapshotWriter.cacheArtwork(for: artworkRequests)
        }

        // Playlist sync — Sendable candidates were built inside the actor.
        if !upsert.playlistCandidates.isEmpty {
            let candidates = upsert.playlistCandidates
            Task { @MainActor in
                await AppleMusicPlaylistSync().sync(candidates: candidates)
            }
        }

        return ReleaseRefreshSummary(
            newReleaseCount: upsert.newReleaseCount,
            updatedReleaseCount: upsert.updatedReleaseCount,
            checkedArtists: result.checkedArtists,
            totalArtists: result.totalArtists,
            failures: result.failures
        )
    }

    /// Convenience wrapper: fetch off-main + apply on main. Used by the background scheduler
    /// and "Refetch all releases" path that don't need a live progress UI.
    @MainActor
    func refreshReleases(
        for trackedArtists: [ArtistData],
        in modelContext: ModelContext,
        scheduleNotifications: Bool,
        notificationHour: Int,
        notificationMinute: Int,
        progress: ((ReleaseRefreshProgress) -> Void)? = nil
    ) async -> ReleaseRefreshSummary {
        let inputs = trackedArtists.map {
            ArtistFetchInput(providerID: $0.providerID, name: $0.name, provider: $0.provider, catalogArtistID: $0.catalogArtistID)
        }

        let result = await fetch(inputs: inputs) { latest in
            Task { @MainActor in
                progress?(latest)
            }
        }

        return await apply(
            result: result,
            trackedArtists: trackedArtists,
            modelContext: modelContext,
            scheduleNotifications: scheduleNotifications,
            notificationHour: notificationHour,
            notificationMinute: notificationMinute
        )
    }
}
