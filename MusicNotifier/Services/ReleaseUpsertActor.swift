//
//  ReleaseUpsertActor.swift
//  MusicNotifier
//
//  Background-thread upsert pipeline for `ReleaseData` inserts/updates after a
//  refresh. Moving this off MainActor was the single biggest remaining source
//  of UI lag during refresh — the loop touches potentially hundreds of @Model
//  instances, each property write fires a SwiftData change notification, and
//  `modelContext.save()` synchronously commits the transaction to SQLite.
//
//  The actor builds Sendable spec lists for notification scheduling and a
//  Sendable widget snapshot inside the same pass, so the caller only ever
//  hands cheap value types back to MainActor after we yield.
//

import Foundation
import SwiftData

@ModelActor
actor ReleaseUpsertActor {
    /// Sendable bundle returned from the actor. Carries everything the caller
    /// needs to finish out a refresh on MainActor — counts, summary strings,
    /// notification specs, widget snapshot, playlist sync candidates — without
    /// reaching back into the actor's `ReleaseData` instances directly.
    struct Output: Sendable {
        var newReleaseCount: Int = 0
        var updatedReleaseCount: Int = 0
        var summarySpecs: [ReleaseSummarySpec] = []
        var upcomingSpecs: [ReleaseNotificationSpec] = []
        var playlistCandidates: [PlaylistSyncCandidate] = []
        var widgetSnapshot: WidgetSnapshot = WidgetSnapshot(generatedAt: Date(), releases: [])
        var widgetRequests: [WidgetArtworkRequest] = []
        var storageFailure: String?
    }

    /// Pure-data inputs the actor needs from main. None of these reference
    /// SwiftData @Model instances so they cross the actor boundary cleanly.
    struct PerArtistContext: Sendable {
        let preferenceByArtist: [String: ArtistNotificationPreference]
        let genresByArtist: [String: [String]]
        let globalPreference: ArtistNotificationPreference
    }

    func apply(
        fetchedReleases: [FetchedRelease],
        now: Date,
        sameDaySummaryEnabled: Bool,
        upcomingEnabled: Bool,
        context: PerArtistContext
    ) -> Output {
        var output = Output()
        var newReleasesData: [ReleaseData] = []
        var dateChangedData: [ReleaseData] = []

        do {
            // Same single-fetch + dictionary lookup the original main-thread
            // version used. Crucially, this fetch now runs on the actor's
            // executor so the SQLite read isn't blocking the UI.
            let allExisting = try modelContext.fetch(FetchDescriptor<ReleaseData>())
            var existingByID = Dictionary(uniqueKeysWithValues: allExisting.map { ($0.providerID, $0) })

            for fetched in fetchedReleases {
                if let existing = existingByID[fetched.providerID] {
                    let releaseDateChanged = existing.releaseDate != fetched.releaseDate
                    var changed = false

                    if existing.artistProviderID != fetched.artistProviderID {
                        existing.artistProviderID = fetched.artistProviderID
                        changed = true
                    }
                    if existing.artistName != fetched.artistName {
                        existing.artistName = fetched.artistName
                        changed = true
                    }
                    if existing.title != fetched.title {
                        existing.title = fetched.title
                        changed = true
                    }
                    if releaseDateChanged {
                        existing.releaseDate = fetched.releaseDate
                        changed = true
                    }
                    if existing.artworkURL != fetched.artworkURL {
                        existing.artworkURL = fetched.artworkURL
                        changed = true
                    }
                    if existing.albumURL != fetched.albumURL {
                        existing.albumURL = fetched.albumURL
                        changed = true
                    }
                    if existing.provider != fetched.provider {
                        existing.provider = fetched.provider
                        changed = true
                    }
                    if existing.type != fetched.type {
                        existing.type = fetched.type
                        changed = true
                    }

                    if changed {
                        existing.lastUpdatedAt = now
                        output.updatedReleaseCount += 1
                    }
                    if releaseDateChanged {
                        dateChangedData.append(existing)
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
                    newReleasesData.append(new)
                    modelContext.insert(new)
                    existingByID[fetched.providerID] = new
                    output.newReleaseCount += 1
                }
            }

            // Decide notifications + mark notifiedAt *before* save so the
            // commit captures the notified state in one transaction.
            if sameDaySummaryEnabled {
                let todayReleases = newReleasesData.filter { release in
                    guard release.notifiedAt == nil, let releaseDate = release.releaseDate else { return false }
                    guard Self.shouldNotify(
                        type: release.type,
                        artistPreference: context.preferenceByArtist[release.artistProviderID] ?? .inherit,
                        globalPreference: context.globalPreference
                    ) else { return false }
                    return Calendar.current.isDateInToday(releaseDate) || releaseDate < Date()
                }
                output.summarySpecs = todayReleases.map(ReleaseSummarySpec.init(from:))
                todayReleases.forEach { $0.notifiedAt = now }
            }

            if upcomingEnabled {
                let dateChangedIDs = Set(dateChangedData.map(\.providerID))
                let upcomingToSchedule = (newReleasesData + dateChangedData).filter { release in
                    guard let releaseDate = release.releaseDate, releaseDate > Date() else { return false }
                    guard release.notifiedAt == nil || dateChangedIDs.contains(release.providerID) else { return false }
                    guard Self.shouldNotify(
                        type: release.type,
                        artistPreference: context.preferenceByArtist[release.artistProviderID] ?? .inherit,
                        globalPreference: context.globalPreference
                    ) else { return false }
                    return true
                }
                output.upcomingSpecs = upcomingToSchedule.compactMap(ReleaseNotificationSpec.init(from:))
                upcomingToSchedule.forEach { $0.notifiedAt = now }
            }

            // Playlist sync candidates — Sendable projection of just the
            // fields the playlist engine needs. Built here so the caller
            // doesn't need to reach back into actor-owned @Model instances.
            output.playlistCandidates = newReleasesData
                .filter { MusicProvider.fromStoredName($0.provider) == .appleMusic && !$0.providerID.isEmpty }
                .map { release in
                    PlaylistSyncCandidate(
                        albumProviderID: release.providerID,
                        kind: release.type,
                        artistGenres: context.genresByArtist[release.artistProviderID] ?? []
                    )
                }

            try modelContext.save()

            // Widget snapshot piggybacks on the dictionary we already have —
            // no extra fetch needed. `captureSnapshot` only reads basic
            // property values so it's safe to call on the actor's executor.
            let (snapshot, requests) = WidgetSnapshotWriter.captureSnapshot(
                from: Array(existingByID.values)
            )
            output.widgetSnapshot = snapshot
            output.widgetRequests = requests
        } catch {
            output.storageFailure = error.localizedDescription
        }

        return output
    }

    /// Inlined copy of `ReleaseRefreshService.shouldNotify` that takes the
    /// `type` raw string instead of a `ReleaseData` reference, so the actor
    /// doesn't have to keep `ReleaseData` lookups in hot loops.
    private static func shouldNotify(
        type: String,
        artistPreference: ArtistNotificationPreference,
        globalPreference: ArtistNotificationPreference
    ) -> Bool {
        let effectivePreference = artistPreference == .inherit ? globalPreference : artistPreference
        let kind = ReleaseKind(rawValue: type) ?? .album
        switch effectivePreference {
        case .inherit, .all: return true
        case .albumsOnly: return kind == .album || kind == .ep
        case .singlesOnly: return kind == .single
        case .muted: return false
        }
    }
}
