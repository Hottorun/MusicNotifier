//
//  ReleaseRefreshService.swift
//  MusicNotifier
//

import Foundation
import SwiftData

struct ReleaseRefreshProgress: Sendable {
    let checkedArtists: Int
    let totalArtists: Int
    let currentArtistName: String

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

    /// On main: apply the fetched result to SwiftData and schedule notifications.
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

        for artist in trackedArtists {
            if let catalogID = result.resolvedCatalogIDs[artist.providerID] {
                artist.catalogArtistID = catalogID
            }
            // Catalog artwork is the authoritative source — overwrite library artwork
            // (which is frequently nil or a broken/invalid URL from MusicKit).
            if let artwork = result.resolvedArtworkURLs[artist.providerID] {
                artist.artworkURL = artwork
            }
            artist.lastCheckedAt = now
        }

        var newReleases: [ReleaseData] = []
        var dateChangedReleases: [ReleaseData] = []
        var updatedReleaseCount = 0

        do {
            // PERF: single fetch + dictionary lookup, instead of N individual
            // predicate fetches inside the loop. For ~400 releases this turns
            // 400+ SQLite queries on MainActor into one, removing the worst
            // UI lag during refresh.
            let allExisting = try modelContext.fetch(FetchDescriptor<ReleaseData>())
            var existingByID = Dictionary(uniqueKeysWithValues: allExisting.map { ($0.providerID, $0) })

            for fetched in result.releases {
                if let existing = existingByID[fetched.providerID] {
                    let releaseDateChanged = existing.releaseDate != fetched.releaseDate

                    existing.artistProviderID = fetched.artistProviderID
                    existing.artistName = fetched.artistName
                    existing.title = fetched.title
                    existing.releaseDate = fetched.releaseDate
                    existing.artworkURL = fetched.artworkURL
                    existing.albumURL = fetched.albumURL
                    existing.provider = fetched.provider
                    existing.type = fetched.type
                    existing.lastUpdatedAt = now
                    updatedReleaseCount += 1

                    if releaseDateChanged {
                        dateChangedReleases.append(existing)
                    }
                } else {
                    let new = ReleaseData(
                        providerID: fetched.providerID,
                        artistProviderID: fetched.artistProviderID,
                        artistName: fetched.artistName,
                        title: fetched.title,
                        releaseDate: fetched.releaseDate,
                        artworkURL: fetched.artworkURL,
                        albumURL: fetched.albumURL,
                        provider: fetched.provider,
                        type: fetched.type
                    )
                    newReleases.append(new)
                    modelContext.insert(new)
                    existingByID[fetched.providerID] = new  // protect against same-batch dupes
                }
            }

            try modelContext.save()
            defaults.set(now.timeIntervalSince1970, forKey: AppSettings.lastSuccessfulRefreshAt)
        } catch {
            return ReleaseRefreshSummary(
                newReleaseCount: newReleases.count,
                updatedReleaseCount: updatedReleaseCount,
                checkedArtists: result.checkedArtists,
                totalArtists: result.totalArtists,
                failures: result.failures + ["Storage: \(error.localizedDescription)"]
            )
        }

        let notificationsEnabled = defaults.object(forKey: AppSettings.notificationsEnabled) as? Bool ?? true

        if scheduleNotifications && notificationsEnabled {
            let notificationScheduler = NotificationScheduler()
            _ = await notificationScheduler.requestAuthorization()

            let upcomingNotificationsEnabled = defaults.object(forKey: AppSettings.upcomingReleaseNotificationsEnabled) as? Bool ?? true
            let sameDaySummaryEnabled = defaults.object(forKey: AppSettings.sameDayReleaseSummaryEnabled) as? Bool ?? true
            let globalPreference = ArtistNotificationPreference(
                rawValue: defaults.string(forKey: AppSettings.globalNotificationReleasePreference) ?? ArtistNotificationPreference.all.rawValue
            ) ?? .all
            let preferenceByArtist = Dictionary(uniqueKeysWithValues: trackedArtists.map {
                (
                    $0.providerID,
                    ArtistNotificationPreference(rawValue: $0.notificationPreference) ?? .inherit
                )
            })

            if sameDaySummaryEnabled {
                let todayReleases = newReleases.filter { release in
                    guard release.notifiedAt == nil, let releaseDate = release.releaseDate else { return false }
                    guard shouldNotify(for: release, artistPreference: preferenceByArtist[release.artistProviderID] ?? .inherit, globalPreference: globalPreference) else { return false }
                    return Calendar.current.isDateInToday(releaseDate) || releaseDate < Date()
                }

                if !todayReleases.isEmpty {
                    await notificationScheduler.scheduleReleaseSummaryNotification(releases: todayReleases)
                    todayReleases.forEach { $0.notifiedAt = now }
                }
            }

            if upcomingNotificationsEnabled {
                let upcomingToSchedule: [ReleaseData] = (newReleases + dateChangedReleases).filter { release in
                    guard let releaseDate = release.releaseDate, releaseDate > Date() else { return false }
                    guard release.notifiedAt == nil || dateChangedReleases.contains(where: { $0.providerID == release.providerID }) else { return false }
                    guard shouldNotify(for: release, artistPreference: preferenceByArtist[release.artistProviderID] ?? .inherit, globalPreference: globalPreference) else { return false }
                    return true
                }

                for release in upcomingToSchedule {
                    await notificationScheduler.scheduleReleaseDayNotification(
                        for: release,
                        hour: notificationHour,
                        minute: notificationMinute
                    )
                    // Optional N-day-before heads-ups (driven by AppSettings.releasePreAlertDays).
                    await notificationScheduler.schedulePreReleaseAlerts(
                        for: release,
                        hour: notificationHour,
                        minute: notificationMinute
                    )
                    release.notifiedAt = now
                }
            }

            try? modelContext.save()
        }

        let artworkRequests = WidgetSnapshotWriter.write(releases: try? modelContext.fetch(FetchDescriptor<ReleaseData>()))
        Task.detached(priority: .utility) {
            await WidgetSnapshotWriter.cacheArtwork(for: artworkRequests)
        }

        // Mirror the newly discovered Apple-Music releases to (a) the default
        // managed playlist when the toggle is on, and (b) every user-defined
        // playlist rule that matches. Run detached so a slow network doesn't
        // block the refresh from completing.
        let genresByArtistID: [String: [String]] = Dictionary(
            uniqueKeysWithValues: trackedArtists.map { ($0.providerID, $0.genres ?? []) }
        )
        let candidates: [PlaylistSyncCandidate] = newReleases
            .filter { MusicProvider.fromStoredName($0.provider) == .appleMusic && !$0.providerID.isEmpty }
            .map { release in
                PlaylistSyncCandidate(
                    albumProviderID: release.providerID,
                    kind: release.type,
                    artistGenres: genresByArtistID[release.artistProviderID] ?? []
                )
            }
        if !candidates.isEmpty {
            Task { @MainActor in
                await AppleMusicPlaylistSync().sync(candidates: candidates)
            }
        }

        return ReleaseRefreshSummary(
            newReleaseCount: newReleases.count,
            updatedReleaseCount: updatedReleaseCount,
            checkedArtists: result.checkedArtists,
            totalArtists: result.totalArtists,
            failures: result.failures
        )
    }

    private func shouldNotify(
        for release: ReleaseData,
        artistPreference: ArtistNotificationPreference,
        globalPreference: ArtistNotificationPreference
    ) -> Bool {
        let effectivePreference = artistPreference == .inherit ? globalPreference : artistPreference
        let kind = ReleaseKind(rawValue: release.type) ?? .album

        switch effectivePreference {
        case .inherit, .all:
            return true
        case .albumsOnly:
            return kind == .album || kind == .ep
        case .singlesOnly:
            return kind == .single
        case .muted:
            return false
        }
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
