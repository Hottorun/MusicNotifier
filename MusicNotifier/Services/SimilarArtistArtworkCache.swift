//
//  SimilarArtistArtworkCache.swift
//  MusicNotifier
//
//  ArtistDetailView's "similar artists" row resolves cover art for each name
//  via a MusicKit catalog search. Previously this map was rebuilt every
//  session and every navigation push, so the circular avatars faded in fresh
//  on every open. This cache persists the resolved name → URL map to disk
//  so the row paints instantly on revisits.
//

import Foundation
import os.lock

final class SimilarArtistArtworkCache: @unchecked Sendable {
    static let shared = SimilarArtistArtworkCache()

    private let lock = OSAllocatedUnfairLock(initialState: State())

    private struct State {
        var memory: [String: URL] = [:]
        var diskLoadAttempted = false
    }

    /// Synchronous: returns the entire name → URL map. Callers pluck the
    /// names they care about. First call lazy-loads from disk.
    func snapshot() -> [String: URL] {
        lock.withLock { state in
            if !state.diskLoadAttempted {
                state.diskLoadAttempted = true
                if let onDisk = Self.loadFromDisk() {
                    state.memory = onDisk
                }
            }
            return state.memory
        }
    }

    func store(_ url: URL, for name: String) {
        let snapshot: [String: URL] = lock.withLock { state in
            state.memory[name] = url
            return state.memory
        }
        Task.detached(priority: .utility) { Self.saveToDisk(snapshot) }
    }

    func prepare() { _ = snapshot() }

    // MARK: - Disk snapshot

    private static var snapshotURL: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("similar_artist_artwork.json")
    }

    private static func loadFromDisk() -> [String: URL]? {
        guard let data = try? Data(contentsOf: snapshotURL) else { return nil }
        guard let decoded = try? JSONDecoder().decode([String: URL].self, from: data) else { return nil }
        return decoded.isEmpty ? nil : decoded
    }

    private static func saveToDisk(_ index: [String: URL]) {
        guard let data = try? JSONEncoder().encode(index) else { return }
        try? data.write(to: snapshotURL, options: .atomic)
    }
}
