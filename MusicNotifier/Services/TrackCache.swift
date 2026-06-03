//
//  TrackCache.swift
//  MusicNotifier
//
//  Per-album tracklist cache, keyed by Apple Music catalog providerID. Album
//  tracklists almost never change after release, so we keep cached entries
//  indefinitely and rely on a background refresh on each open to catch the
//  rare edits (track removed for licensing, deluxe edition added).
//
//  Implemented as a synchronized class rather than an actor so reads are
//  truly synchronous. AlbumView seeds its `@State tracks` from this cache
//  during init, before the first body render — no actor hop, no await, no
//  resume-queued-behind-the-navigation-animation latency. Writes also happen
//  synchronously to memory; disk persistence is hopped to a background task
//  inside `store(_:for:)` so the calling site doesn't block on JSON encoding.
//

import Foundation
import os.lock

/// Codable, Sendable mirror of `AlbumTrackRow` so the cache stays decoupled
/// from the view layer.
struct CachedTrack: Codable, Sendable, Hashable {
    let id: String
    let discNumber: Int
    let trackNumber: Int
    let title: String
    let artistName: String
    let duration: Double?

    init(id: String, discNumber: Int, trackNumber: Int, title: String, artistName: String, duration: Double?) {
        self.id = id
        self.discNumber = discNumber
        self.trackNumber = trackNumber
        self.title = title
        self.artistName = artistName
        self.duration = duration
    }

    init(row: AlbumTrackRow) {
        self.init(
            id: row.id,
            discNumber: row.discNumber,
            trackNumber: row.trackNumber,
            title: row.title,
            artistName: row.artistName,
            duration: row.duration
        )
    }
}

final class TrackCache: @unchecked Sendable {
    static let shared = TrackCache()

    private let lock = OSAllocatedUnfairLock(initialState: State())

    private struct State {
        var memory: [String: [CachedTrack]] = [:]
        var diskLoadAttempted = false
    }

    /// Synchronous cache read. Safe to call from anywhere, no await required.
    /// First call lazy-loads the persisted snapshot under the lock so future
    /// calls are just a dictionary lookup.
    func tracks(for providerID: String) -> [CachedTrack]? {
        lock.withLock { state in
            if !state.diskLoadAttempted {
                state.diskLoadAttempted = true
                if let onDisk = Self.loadFromDisk() {
                    state.memory = onDisk
                }
            }
            return state.memory[providerID]
        }
    }

    /// Persist a freshly-fetched tracklist. In-memory update is sync; disk
    /// write hops to a background task so callers don't block on JSON encoding.
    func store(_ tracks: [CachedTrack], for providerID: String) {
        guard !tracks.isEmpty else { return }
        let snapshot: [String: [CachedTrack]] = lock.withLock { state in
            state.memory[providerID] = tracks
            return state.memory
        }
        Task.detached(priority: .utility) {
            Self.saveToDisk(snapshot)
        }
    }

    func invalidate(providerID: String) {
        let snapshot: [String: [CachedTrack]] = lock.withLock { state in
            state.memory.removeValue(forKey: providerID)
            return state.memory
        }
        Task.detached(priority: .utility) {
            Self.saveToDisk(snapshot)
        }
    }

    func invalidateAll() {
        lock.withLock { state in
            state.memory = [:]
        }
        try? FileManager.default.removeItem(at: Self.snapshotURL)
    }

    /// Eagerly populate the in-memory snapshot from disk. Safe to call at any
    /// point — subsequent calls are no-ops since `diskLoadAttempted` latches.
    /// Calling this from app launch / feed appearance means the first album
    /// tap has zero disk I/O.
    func prepare() {
        _ = tracks(for: "")  // Triggers the lazy disk load if needed.
    }

    // MARK: - Disk snapshot

    private static var snapshotURL: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("track_cache.json")
    }

    private static func loadFromDisk() -> [String: [CachedTrack]]? {
        guard let data = try? Data(contentsOf: snapshotURL) else { return nil }
        guard let decoded = try? JSONDecoder().decode([String: [CachedTrack]].self, from: data) else { return nil }
        return decoded.isEmpty ? nil : decoded
    }

    private static func saveToDisk(_ index: [String: [CachedTrack]]) {
        guard let data = try? JSONEncoder().encode(index) else { return }
        try? data.write(to: snapshotURL, options: .atomic)
    }
}
