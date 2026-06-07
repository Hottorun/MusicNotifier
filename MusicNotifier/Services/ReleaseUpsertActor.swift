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

    /// Sendable artist-update bundle so the actor can apply tracked-artist
    /// metadata (resolved catalog ID, artwork URL, lastCheckedAt) inside the
    /// same transaction as the release upsert — eliminating the duplicate
    /// `@Query` invalidation that used to fire from a separate MainActor save.
    struct ArtistUpdates: Sendable {
        let resolvedCatalogIDs: [String: String]
        let resolvedArtworkURLs: [String: URL]
        let trackedProviderIDs: [String]
    }

    func apply(
        fetchedReleases: [FetchedRelease],
        now: Date,
        sameDaySummaryEnabled: Bool,
        upcomingEnabled: Bool,
        // First-ever refresh after install or after iCloud import. New rows
        // with a past `releaseDate` are inserted as already-seen so the feed
        // doesn't open with a wall of historical drops the user has likely
        // heard. Future-dated rows stay unseen so the user still gets the
        // "new" treatment on releases that drop after install.
        markHistoricalAsSeen: Bool = false,
        context: PerArtistContext,
        artistUpdates: ArtistUpdates? = nil
    ) -> Output {
        var output = Output()
        var newReleasesData: [ReleaseData] = []
        var dateChangedData: [ReleaseData] = []

        do {
            // Bounded fetch: only pull ReleaseData rows whose `providerID`
            // appears in the current fetched batch. The dedup key is
            // `providerID`, so any row not in this set can't collide with
            // an insert. On long-lived libraries (10k+ stored releases)
            // this drops the SQLite read + dict build from O(all rows)
            // to O(batch size) — the largest single source of end-of-
            // refresh lag.
            let fetchedIDs = Set(fetchedReleases.map(\.providerID))
            let existingDescriptor = FetchDescriptor<ReleaseData>(
                predicate: #Predicate { fetchedIDs.contains($0.providerID) }
            )
            let allExisting = try modelContext.fetch(existingDescriptor)
            // CloudKit mirroring can briefly land two `ReleaseData` rows for
            // the same providerID before `CloudSyncDeduplicator` merges them.
            // `uniqueKeysWithValues` crashes on collision; `uniquingKeysWith`
            // keeps the more-recently-updated row, which the upsert then
            // patches in place. The duplicate is left alone — the deduper
            // will remove it on its next pass.
            var existingByID = Dictionary(
                allExisting.map { ($0.providerID, $0) },
                uniquingKeysWith: { lhs, rhs in
                    lhs.lastUpdatedAt >= rhs.lastUpdatedAt ? lhs : rhs
                }
            )

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
                    // First-refresh seeding: pre-mark *deep-history* drops as
                    // already seen so the feed doesn't open with years of
                    // backfill noise. Anything from the last 60 days is kept
                    // unseen — that window covers "this single dropped last
                    // week" / "this album came out last month" which the user
                    // legitimately wants to see as new on first launch.
                    let historicalCutoffDays = 60
                    let cutoff = Calendar.current.date(
                        byAdding: .day,
                        value: -historicalCutoffDays,
                        to: Calendar.current.startOfDay(for: now)
                    )
                    if markHistoricalAsSeen,
                       let rd = fetched.releaseDate,
                       let cutoff,
                       Calendar.current.startOfDay(for: rd) < cutoff {
                        new.isSeen = true
                    }
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

            // Fold tracked-artist metadata writes into this same transaction
            // so the @Query observers only see one propagation, not two.
            if let artistUpdates {
                let trackedIDs = Set(artistUpdates.trackedProviderIDs)
                let descriptor = FetchDescriptor<ArtistData>(
                    predicate: #Predicate { trackedIDs.contains($0.providerID) }
                )
                if let artists = try? modelContext.fetch(descriptor) {
                    for artist in artists {
                        if let catalogID = artistUpdates.resolvedCatalogIDs[artist.providerID] {
                            artist.catalogArtistID = catalogID
                        }
                        if let artwork = artistUpdates.resolvedArtworkURLs[artist.providerID] {
                            artist.artworkURL = artwork
                        }
                        artist.lastCheckedAt = now
                    }
                }
            }

            try modelContext.save()

            // Widget snapshot: the bounded `existingByID` fetch above only
            // contains releases in this batch — not enough for the widget's
            // "40 closest-to-now" view, especially on small incremental
            // refreshes. Do a targeted fetch for widget content (released
            // last 60 days OR upcoming) and feed that to the snapshot
            // builder. Cheap because it's still date-bounded.
            let widgetCutoff = Calendar.current.date(byAdding: .day, value: -60, to: now) ?? now
            let widgetDescriptor = FetchDescriptor<ReleaseData>(
                predicate: #Predicate { release in
                    release.dismissedAt == nil &&
                    (release.releaseDate == nil || release.releaseDate! >= widgetCutoff)
                }
            )
            let widgetReleases = (try? modelContext.fetch(widgetDescriptor)) ?? Array(existingByID.values)
            let (snapshot, requests) = WidgetSnapshotWriter.captureSnapshot(from: widgetReleases)
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
