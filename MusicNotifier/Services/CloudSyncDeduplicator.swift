//
//  CloudSyncDeduplicator.swift
//  MusicNotifier
//

import Foundation
import SwiftData

/// Merges duplicate `ArtistData` / `ReleaseData` rows that can appear when the
/// same artist is imported on two devices before CloudKit mirroring catches up.
/// SwiftData's CloudKit mirroring is last-write-wins per record, but it does
/// NOT enforce uniqueness on `providerID`, so two concurrent inserts produce
/// two rows with the same provider key.
///
/// Run once on app launch from `MusicNotifierApp`. Idempotent — repeated runs
/// are no-ops once duplicates are merged.
enum CloudSyncDeduplicator {
    /// Row counts as of the last completed pass, used to skip redundant work.
    private struct TableCounts: Equatable {
        var artists = 0
        var releases = 0
        var videos = 0
    }

    @MainActor private static var lastCounts: TableCounts?

    /// - Parameter force: bypass the change gate. Used right after an import,
    ///   where a duplicate may have been created by a CloudKit row landing
    ///   mid-write without the net count changing.
    @MainActor
    static func run(in context: ModelContext, force: Bool = false) {
        // The four merge passes below each fetch and materialize an entire
        // table. That's fine once at launch, but `run` is also called on every
        // foreground transition and on every remote-change notification — on a
        // library with thousands of releases that turned into a repeated
        // main-thread stall.
        //
        // Duplicates can only ever *add* rows, so if nothing has grown since
        // the last pass there is nothing new to merge. `fetchCount` is a SQL
        // aggregate that materializes no objects, making the common "nothing
        // changed" case effectively free.
        let counts = currentCounts(in: context)
        if !force, let lastCounts, counts == lastCounts { return }

        let artistMerges = mergeArtists(in: context)
        // Second pass catches the "same human artist, two different
        // providerIDs" case — e.g. one row added from library import
        // (providerID = library identifier), another added later via
        // search / appears-on (providerID = catalog identifier). Both
        // resolve to the same Apple Music `catalogArtistID`, which is
        // the canonical artist identity. Without this pass the rows
        // never collapse because `mergeArtists` keys by providerID.
        let catalogMerges = mergeArtistsByCatalogID(in: context)
        let releaseMerges = mergeReleases(in: context)
        let videoMerges = mergeVideos(in: context)
        if artistMerges + catalogMerges + releaseMerges + videoMerges > 0 {
            try? context.save()
            Log.v("[Dedup] merged \(artistMerges) artists (providerID), \(catalogMerges) artists (catalogID), \(releaseMerges) releases, \(videoMerges) videos")
            // Merging deletes rows, so re-read rather than reusing `counts`.
            lastCounts = currentCounts(in: context)
        } else {
            lastCounts = counts
        }
    }

    @MainActor
    private static func currentCounts(in context: ModelContext) -> TableCounts {
        TableCounts(
            artists: (try? context.fetchCount(FetchDescriptor<ArtistData>())) ?? 0,
            releases: (try? context.fetchCount(FetchDescriptor<ReleaseData>())) ?? 0,
            videos: (try? context.fetchCount(FetchDescriptor<VideoData>())) ?? 0
        )
    }

    @MainActor
    private static func mergeVideos(in context: ModelContext) -> Int {
        guard let all = try? context.fetch(FetchDescriptor<VideoData>()) else { return 0 }
        let groups = Dictionary(grouping: all) { "\($0.provider)|\($0.providerID)" }
        var deleted = 0
        for (_, rows) in groups where rows.count > 1 {
            let sorted = rows.sorted { $0.discoveredAt < $1.discoveredAt }
            let survivor = sorted[0]
            for dup in sorted.dropFirst() {
                if dup.isSeen { survivor.isSeen = true }
                if survivor.notifiedAt == nil { survivor.notifiedAt = dup.notifiedAt }
                if survivor.artworkURL == nil { survivor.artworkURL = dup.artworkURL }
                if survivor.videoURL == nil { survivor.videoURL = dup.videoURL }
                context.delete(dup)
                deleted += 1
            }
        }
        return deleted
    }

    /// Group artists by `(provider, providerID)`. For each group with >1 row:
    /// pick a survivor (earliest `addedAt`), OR-merge `isTracked`, prefer the
    /// most recent `lastCheckedAt`, keep the richer `notificationPreference`
    /// when one says `inherit` and another says something specific.
    @MainActor
    private static func mergeArtists(in context: ModelContext) -> Int {
        guard let all = try? context.fetch(FetchDescriptor<ArtistData>()) else { return 0 }
        let groups = Dictionary(grouping: all) { "\($0.provider)|\($0.providerID)" }
        var deleted = 0
        for (_, rows) in groups where rows.count > 1 {
            let sorted = rows.sorted { $0.addedAt < $1.addedAt }
            let survivor = sorted[0]
            for dup in sorted.dropFirst() {
                if dup.isTracked { survivor.isTracked = true }
                if survivor.artworkURL == nil { survivor.artworkURL = dup.artworkURL }
                if survivor.catalogArtistID == nil { survivor.catalogArtistID = dup.catalogArtistID }
                if let dupChecked = dup.lastCheckedAt {
                    if let surChecked = survivor.lastCheckedAt {
                        survivor.lastCheckedAt = max(surChecked, dupChecked)
                    } else {
                        survivor.lastCheckedAt = dupChecked
                    }
                }
                if survivor.notificationPreference == ArtistNotificationPreference.inherit.rawValue,
                   dup.notificationPreference != ArtistNotificationPreference.inherit.rawValue {
                    survivor.notificationPreference = dup.notificationPreference
                }
                if (survivor.genres ?? []).isEmpty, let dupGenres = dup.genres, !dupGenres.isEmpty {
                    survivor.genres = dupGenres
                }
                context.delete(dup)
                deleted += 1
            }
        }
        return deleted
    }

    /// Second-pass artist dedup, keyed on `(provider, catalogArtistID)`.
    /// Catches duplicates that survived the providerID pass because the
    /// same human artist was added via two different import paths
    /// (library vs catalog search vs appears-on resolution), each of
    /// which produces a different `providerID` but the same resolved
    /// `catalogArtistID`.
    ///
    /// Survivor is the earliest `addedAt`. **`isTracked` is AND-merged**
    /// here — the user's intent in the cross-providerID case is almost
    /// always "I only want the visible copy; if I untracked one, the
    /// merged result should be untracked". The providerID-pass keeps
    /// OR-merge because that's a genuine sync race where preserving the
    /// "I tracked this once" decision is correct.
    ///
    /// Re-attributes `ReleaseData.artistProviderID` from the dup's
    /// providerID to the survivor's providerID so existing rows stay
    /// linked to the surviving artist instead of becoming orphans the
    /// feed silently drops.
    @MainActor
    private static func mergeArtistsByCatalogID(in context: ModelContext) -> Int {
        guard let all = try? context.fetch(FetchDescriptor<ArtistData>()) else { return 0 }
        let withCatalog = all.filter { artist in
            guard let cat = artist.catalogArtistID, !cat.isEmpty else { return false }
            return true
        }
        let groups = Dictionary(grouping: withCatalog) {
            "\($0.provider)|\($0.catalogArtistID ?? "")"
        }
        var deleted = 0
        for (_, rows) in groups where rows.count > 1 {
            let sorted = rows.sorted { $0.addedAt < $1.addedAt }
            let survivor = sorted[0]
            let survivorProviderID = survivor.providerID
            for dup in sorted.dropFirst() {
                let dupProviderID = dup.providerID
                if dupProviderID != survivorProviderID {
                    let predicate = #Predicate<ReleaseData> { $0.artistProviderID == dupProviderID }
                    if let orphans = try? context.fetch(FetchDescriptor<ReleaseData>(predicate: predicate)) {
                        for orphan in orphans {
                            orphan.artistProviderID = survivorProviderID
                        }
                    }
                }
                // AND-merge: only stay tracked if both rows agree.
                survivor.isTracked = survivor.isTracked && dup.isTracked
                if survivor.artworkURL == nil { survivor.artworkURL = dup.artworkURL }
                if let dupChecked = dup.lastCheckedAt {
                    if let surChecked = survivor.lastCheckedAt {
                        survivor.lastCheckedAt = max(surChecked, dupChecked)
                    } else {
                        survivor.lastCheckedAt = dupChecked
                    }
                }
                if survivor.notificationPreference == ArtistNotificationPreference.inherit.rawValue,
                   dup.notificationPreference != ArtistNotificationPreference.inherit.rawValue {
                    survivor.notificationPreference = dup.notificationPreference
                }
                if (survivor.genres ?? []).isEmpty, let dupGenres = dup.genres, !dupGenres.isEmpty {
                    survivor.genres = dupGenres
                }
                context.delete(dup)
                deleted += 1
            }
        }
        return deleted
    }

    /// Releases dedup by `(provider, providerID)`. Survivor is the earliest
    /// `firstSeenAt`. `isSeen`, `notifiedAt`, `dismissedAt` are OR-merged so
    /// a user who marked the release seen on one device doesn't see it
    /// resurface as unseen on another.
    @MainActor
    private static func mergeReleases(in context: ModelContext) -> Int {
        guard let all = try? context.fetch(FetchDescriptor<ReleaseData>()) else { return 0 }
        let groups = Dictionary(grouping: all) { "\($0.provider)|\($0.providerID)" }
        var deleted = 0
        for (_, rows) in groups where rows.count > 1 {
            let sorted = rows.sorted { $0.firstSeenAt < $1.firstSeenAt }
            let survivor = sorted[0]
            for dup in sorted.dropFirst() {
                if dup.isSeen { survivor.isSeen = true }
                if survivor.notifiedAt == nil { survivor.notifiedAt = dup.notifiedAt }
                if survivor.dismissedAt == nil { survivor.dismissedAt = dup.dismissedAt }
                if survivor.artworkURL == nil { survivor.artworkURL = dup.artworkURL }
                if survivor.albumURL == nil { survivor.albumURL = dup.albumURL }
                survivor.lastUpdatedAt = max(survivor.lastUpdatedAt, dup.lastUpdatedAt)
                context.delete(dup)
                deleted += 1
            }
        }
        return deleted
    }
}
