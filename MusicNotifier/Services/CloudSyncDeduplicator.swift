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
    @MainActor
    static func run(in context: ModelContext) {
        let artistMerges = mergeArtists(in: context)
        let releaseMerges = mergeReleases(in: context)
        let videoMerges = mergeVideos(in: context)
        let concertMerges = mergeConcerts(in: context)
        if artistMerges + releaseMerges + videoMerges + concertMerges > 0 {
            try? context.save()
            Log.v("[Dedup] merged \(artistMerges) artists, \(releaseMerges) releases, \(videoMerges) videos, \(concertMerges) concerts")
        }
    }

    @MainActor
    private static func mergeConcerts(in context: ModelContext) -> Int {
        guard let all = try? context.fetch(FetchDescriptor<ConcertData>()) else { return 0 }
        let groups = Dictionary(grouping: all) { "\($0.provider)|\($0.providerID)" }
        var deleted = 0
        for (_, rows) in groups where rows.count > 1 {
            let sorted = rows.sorted { $0.discoveredAt < $1.discoveredAt }
            let survivor = sorted[0]
            for dup in sorted.dropFirst() {
                if dup.savedAt != nil && survivor.savedAt == nil { survivor.savedAt = dup.savedAt }
                if dup.dismissedAt != nil && survivor.dismissedAt == nil { survivor.dismissedAt = dup.dismissedAt }
                if survivor.notifiedAt == nil { survivor.notifiedAt = dup.notifiedAt }
                if survivor.ticketURL == nil { survivor.ticketURL = dup.ticketURL }
                survivor.lastUpdatedAt = max(survivor.lastUpdatedAt, dup.lastUpdatedAt)
                context.delete(dup)
                deleted += 1
            }
        }
        return deleted
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
