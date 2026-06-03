//
//  LibraryMembershipIndex.swift
//  MusicNotifier
//
//  Session-scoped, deduplicated cache of the user's Apple Music library indexed
//  by `artistName.lowercased() → Set<title.lowercased()>`. AlbumView used to
//  rebuild this index from scratch every time the user opened a release, which
//  meant a full `MusicLibraryRequest<Song>` fetch + iteration on every push —
//  measured at ~1.75s for a moderately-sized library. With this actor the index
//  is built once per session and reused; concurrent first-time callers share
//  the same in-flight task instead of triggering N parallel library fetches.
//

import Foundation
import MusicKit

actor LibraryMembershipIndex {
    static let shared = LibraryMembershipIndex()

    private var index: [String: Set<String>]?
    private var loadingTask: Task<[String: Set<String>], Never>?
    private var diskLoadAttempted = false

    /// Returns the cached index. Order:
    ///   1. In-memory cache (post-warm or post-load).
    ///   2. Persisted snapshot from disk — populates the in-memory cache and
    ///      kicks off a background refresh so we drift back into sync if the
    ///      user added/removed songs in another app.
    ///   3. Awaits an in-flight build, or starts one.
    /// Never throws — failures yield an empty index so "no checkmarks" rather
    /// than an error path.
    func get() async -> [String: Set<String>] {
        if let index { return index }

        // Try the persisted snapshot once per process. If it succeeds, future
        // album opens are instant from cold launch.
        if !diskLoadAttempted {
            diskLoadAttempted = true
            if let onDisk = Self.loadFromDisk() {
                index = onDisk
                // Refresh against live library so the next session reflects
                // anything that changed since this snapshot was written.
                scheduleBackgroundRefresh()
                return onDisk
            }
        }

        if let loadingTask { return await loadingTask.value }

        let task = Task<[String: Set<String>], Never> {
            let built = await Self.build()
            Self.saveToDisk(built)
            return built
        }
        loadingTask = task
        let result = await task.value
        index = result
        loadingTask = nil
        return result
    }

    /// Drop the cache, e.g. after the user adds songs in-app so subsequent
    /// album opens reflect the new state. Also nukes the disk snapshot.
    func invalidate() {
        index = nil
        loadingTask = nil
        try? FileManager.default.removeItem(at: Self.snapshotURL)
    }

    private func scheduleBackgroundRefresh() {
        let task = Task<[String: Set<String>], Never> {
            let built = await Self.build()
            Self.saveToDisk(built)
            return built
        }
        loadingTask = task
        Task {
            let refreshed = await task.value
            self.applyRefreshed(refreshed)
        }
    }

    private func applyRefreshed(_ refreshed: [String: Set<String>]) {
        // Don't clobber with an empty result from a failed refresh — that
        // would invalidate a perfectly good disk snapshot just because the
        // library API hiccuped.
        if !refreshed.isEmpty { index = refreshed }
        loadingTask = nil
    }

    // MARK: - Build

    private static func build() async -> [String: Set<String>] {
        #if os(iOS) || os(visionOS) || targetEnvironment(macCatalyst)
        do {
            let request = MusicLibraryRequest<Song>()
            let response = try await request.response()
            var indexed: [String: Set<String>] = [:]
            indexed.reserveCapacity(response.items.count / 4)
            for song in response.items {
                indexed[song.artistName.lowercased(), default: []].insert(song.title.lowercased())
            }
            return indexed
        } catch {
            return [:]
        }
        #else
        return [:]
        #endif
    }

    // MARK: - Disk snapshot

    private static var snapshotURL: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("library_membership_index.json")
    }

    private static func loadFromDisk() -> [String: Set<String>]? {
        guard let data = try? Data(contentsOf: snapshotURL) else { return nil }
        guard let decoded = try? JSONDecoder().decode([String: [String]].self, from: data) else { return nil }
        guard !decoded.isEmpty else { return nil }
        return decoded.mapValues(Set.init)
    }

    private static func saveToDisk(_ index: [String: Set<String>]) {
        guard !index.isEmpty else { return }
        let encoded = index.mapValues(Array.init)
        guard let data = try? JSONEncoder().encode(encoded) else { return }
        try? data.write(to: snapshotURL, options: .atomic)
    }
}
