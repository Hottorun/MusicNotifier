//
//  TrackPrefetcher.swift
//  MusicNotifier
//
//  Pulls a release's tracklist from Apple Music and stores it in `TrackCache`.
//  Used both by AlbumView for the post-cache-hit background refresh and by
//  HomeView for top-of-feed prefetching, so the first tap on a visible release
//  is already a cache hit.
//

import Foundation
import MusicKit

enum TrackPrefetcher {
    /// Fetch the tracklist for a catalog album by ID and persist it to the
    /// shared cache. Silent on failure — prefetching is best-effort.
    static func prefetch(providerID: String) async {
        do {
            var request = MusicCatalogResourceRequest<Album>(matching: \.id, equalTo: MusicItemID(providerID))
            request.properties = [.tracks]
            let response = try await request.response()
            guard let album = response.items.first else { return }
            let rows: [CachedTrack] = (album.tracks.map(Array.init) ?? []).map { track in
                CachedTrack(
                    id: track.id.rawValue,
                    discNumber: track.discNumber ?? 1,
                    trackNumber: track.trackNumber ?? 0,
                    title: track.title,
                    artistName: track.artistName,
                    duration: track.duration
                )
            }
            TrackCache.shared.store(rows, for: providerID)
        } catch {
            // Best-effort — quota, network, or unknown ID. Silent.
        }
    }

    /// Prefetch up to `limit` releases concurrently, skipping any that already
    /// have a cache entry so we don't burn MusicKit quota for hot items.
    /// Capped concurrency keeps the request volume modest.
    static func prefetchBatch(providerIDs: [String], limit: Int = 10) async {
        let targets = providerIDs.prefix(limit).filter { id in
            TrackCache.shared.tracks(for: id) == nil
        }
        guard !targets.isEmpty else { return }

        await withTaskGroup(of: Void.self) { group in
            for id in targets {
                group.addTask { await prefetch(providerID: id) }
            }
        }
    }
}
