//
//  TrackPopularityCache.swift
//  MusicNotifier
//
//  Caches the *computed* "top 25% popular tracks" set per album providerID.
//  Per-track Last.fm playcount results are already cached by LastFMService at
//  the request level, but the ranking + thresholding pass still ran on every
//  album open and only finished after the network round-trip. This cache
//  stores the final lowercased-title set so flame icons render on the first
//  paint of a previously-opened album, no fade-in.
//
//  Same disk-snapshot pattern as TrackCache: synchronous reads via lock, lazy
//  disk load on first access, background disk write on mutation.
//

import Foundation
import os.lock

final class TrackPopularityCache: @unchecked Sendable {
    static let shared = TrackPopularityCache()

    private let lock = OSAllocatedUnfairLock(initialState: State())

    private struct State {
        var memory: [String: [String]] = [:]
        var diskLoadAttempted = false
    }

    /// Synchronous read. Returns the lowercased titles previously marked as
    /// popular for `providerID`, or nil if we've never analysed that album.
    func popularTitles(for providerID: String) -> Set<String>? {
        lock.withLock { state in
            if !state.diskLoadAttempted {
                state.diskLoadAttempted = true
                if let onDisk = Self.loadFromDisk() {
                    state.memory = onDisk
                }
            }
            return state.memory[providerID].map(Set.init)
        }
    }

    func store(_ titles: Set<String>, for providerID: String) {
        guard !titles.isEmpty else { return }
        let snapshot: [String: [String]] = lock.withLock { state in
            state.memory[providerID] = Array(titles)
            return state.memory
        }
        Task.detached(priority: .utility) { Self.saveToDisk(snapshot) }
    }

    func invalidate(providerID: String) {
        let snapshot: [String: [String]] = lock.withLock { state in
            state.memory.removeValue(forKey: providerID)
            return state.memory
        }
        Task.detached(priority: .utility) { Self.saveToDisk(snapshot) }
    }

    func prepare() { _ = popularTitles(for: "") }

    // MARK: - Disk snapshot

    private static var snapshotURL: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("track_popularity_cache.json")
    }

    private static func loadFromDisk() -> [String: [String]]? {
        guard let data = try? Data(contentsOf: snapshotURL) else { return nil }
        guard let decoded = try? JSONDecoder().decode([String: [String]].self, from: data) else { return nil }
        return decoded.isEmpty ? nil : decoded
    }

    private static func saveToDisk(_ index: [String: [String]]) {
        guard let data = try? JSONEncoder().encode(index) else { return }
        try? data.write(to: snapshotURL, options: .atomic)
    }
}
