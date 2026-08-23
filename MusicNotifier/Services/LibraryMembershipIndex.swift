//
//  LibraryMembershipIndex.swift
//  MusicNotifier
//
//  Session-scoped, deduplicated cache of which songs are already in the user's
//  Apple Music library. AlbumView used to rebuild this from scratch every time
//  the user opened a release, which meant a full `MusicLibraryRequest<Song>`
//  fetch + iteration on every push — measured at ~1.75s for a moderately-sized
//  library. With this actor the index is built once per session and reused;
//  concurrent first-time callers share the same in-flight task instead of
//  triggering N parallel library fetches.
//
//  Membership is keyed on the **catalog song ID**, not on artist + title text.
//  Matching on text meant a single and the album that later collects the same
//  recording were indistinguishable: adding "Opalite" as a single marked the
//  album's "Opalite" as already in the library, and the `+` button vanished so
//  the album version could never be added. They are separate catalog items with
//  separate IDs, and the UI has to treat them that way.
//

import Foundation
import MusicKit

/// What the index knows about the user's library.
struct LibraryMembershipSnapshot: Codable, Sendable {
    /// Catalog song IDs for every library song that maps to a catalog item.
    /// This is the authoritative membership check.
    var catalogSongIDs: Set<String> = []

    /// Fallback for library songs with *no* catalog equivalent — iTunes-matched
    /// or user-uploaded files. Those have nothing to match an ID against, so
    /// they keep the old `artist → titles` behaviour. Catalog songs never land
    /// here, so they can't collide across editions.
    var titlesByArtistWithoutCatalogID: [String: Set<String>] = [:]

    var isEmpty: Bool {
        catalogSongIDs.isEmpty && titlesByArtistWithoutCatalogID.isEmpty
    }

    /// True when `catalogSongID` is in the library, or — only for songs with no
    /// catalog identity — when an entry matches on artist + title.
    func contains(catalogSongID: String, title: String, artistName: String) -> Bool {
        if catalogSongIDs.contains(catalogSongID) { return true }
        guard !titlesByArtistWithoutCatalogID.isEmpty else { return false }
        return titlesByArtistWithoutCatalogID[artistName.lowercased()]?
            .contains(title.lowercased()) == true
    }
}

actor LibraryMembershipIndex {
    static let shared = LibraryMembershipIndex()

    private var index: LibraryMembershipSnapshot?
    private var loadingTask: Task<LibraryMembershipSnapshot, Never>?
    private var diskLoadAttempted = false

    /// Returns the cached snapshot. Order:
    ///   1. In-memory cache (post-warm or post-load).
    ///   2. Persisted snapshot from disk — populates the in-memory cache and
    ///      kicks off a background refresh so we drift back into sync if the
    ///      user added/removed songs in another app.
    ///   3. Awaits an in-flight build, or starts one.
    /// Never throws — failures yield an empty snapshot so "no checkmarks"
    /// rather than an error path.
    func get() async -> LibraryMembershipSnapshot {
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

        let task = Task<LibraryMembershipSnapshot, Never> {
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

    /// Fold songs the user just added in-app into the cached snapshot, so
    /// reopening the album in the same session shows them as present without
    /// waiting for a full library re-fetch.
    func record(catalogSongIDs newIDs: some Sequence<String>) {
        guard var current = index else { return }
        current.catalogSongIDs.formUnion(newIDs)
        index = current
        Self.saveToDisk(current)
    }

    /// Drop the cache, e.g. after the user adds songs in-app so subsequent
    /// album opens reflect the new state. Also nukes the disk snapshot.
    func invalidate() {
        index = nil
        loadingTask = nil
        try? FileManager.default.removeItem(at: Self.snapshotURL)
    }

    private func scheduleBackgroundRefresh() {
        let task = Task<LibraryMembershipSnapshot, Never> {
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

    private func applyRefreshed(_ refreshed: LibraryMembershipSnapshot) {
        // Don't clobber with an empty result from a failed refresh — that
        // would invalidate a perfectly good disk snapshot just because the
        // library API hiccuped.
        if !refreshed.isEmpty { index = refreshed }
        loadingTask = nil
    }

    // MARK: - Build

    private static func build() async -> LibraryMembershipSnapshot {
        #if os(iOS) || os(visionOS) || targetEnvironment(macCatalyst)
        do {
            let request = MusicLibraryRequest<Song>()
            let response = try await request.response()
            var snapshot = LibraryMembershipSnapshot()
            snapshot.catalogSongIDs.reserveCapacity(response.items.count)
            for song in response.items {
                if let catalogID = catalogID(of: song) {
                    snapshot.catalogSongIDs.insert(catalogID)
                } else {
                    // No catalog identity (uploaded / matched file) — the only
                    // thing left to match on is the text.
                    snapshot.titlesByArtistWithoutCatalogID[
                        song.artistName.lowercased(), default: []
                    ].insert(song.title.lowercased())
                }
            }
            return snapshot
        } catch {
            return LibraryMembershipSnapshot()
        }
        #else
        return LibraryMembershipSnapshot()
        #endif
    }

    /// MusicKit models `playParameters` as an opaque `Codable` blob, but the
    /// underlying JSON carries the catalog ID for any library song that came
    /// from the Apple Music catalog. Round-tripping through JSON is the
    /// supported way to read it — a library `Song.id` is the *library*
    /// identifier and never matches a catalog track ID.
    private struct PlayParametersPayload: Decodable {
        let id: String?
        let catalogId: String?
        let isLibrary: Bool?
    }

    private static func catalogID(of song: Song) -> String? {
        guard let parameters = song.playParameters,
              let data = try? JSONEncoder().encode(parameters),
              let payload = try? JSONDecoder().decode(PlayParametersPayload.self, from: data)
        else { return nil }

        if let catalogId = payload.catalogId, !catalogId.isEmpty { return catalogId }
        // Catalog-sourced entries can instead carry the catalog id directly in
        // `id` with `isLibrary` absent/false.
        if payload.isLibrary != true, let id = payload.id, !id.isEmpty { return id }
        return nil
    }

    // MARK: - Disk snapshot

    private static var snapshotURL: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        // v2: the v1 file held `[artist: [title]]`, which this type can't decode
        // and whose text-matching semantics were the bug. A new name lets stale
        // v1 snapshots be ignored instead of half-decoded.
        return dir.appendingPathComponent("library_membership_index_v2.json")
    }

    private static func loadFromDisk() -> LibraryMembershipSnapshot? {
        guard let data = try? Data(contentsOf: snapshotURL) else { return nil }
        guard let decoded = try? JSONDecoder().decode(LibraryMembershipSnapshot.self, from: data) else { return nil }
        return decoded.isEmpty ? nil : decoded
    }

    private static func saveToDisk(_ snapshot: LibraryMembershipSnapshot) {
        guard !snapshot.isEmpty else { return }
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: snapshotURL, options: .atomic)
    }
}
