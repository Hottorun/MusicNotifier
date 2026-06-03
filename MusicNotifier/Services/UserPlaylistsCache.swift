//
//  UserPlaylistsCache.swift
//  MusicNotifier
//
//  Session-scoped cache of the user's editable Apple Music playlists. Each
//  AlbumView used to lazy-fetch this list the first time the user opened
//  the "Add to Playlist" sheet — a noticeable spinner. With this cache, the
//  fetch runs once per session (warm-able from HomeView on launch) and
//  every subsequent picker open paints instantly.
//
//  Not persisted to disk: `MusicKit.Playlist` isn't Codable, and a session
//  scope is enough since playlists rarely change between picker opens within
//  a single app session.
//

import Foundation
import MusicKit

@MainActor
final class UserPlaylistsCache: ObservableObject {
    static let shared = UserPlaylistsCache()

    @Published private(set) var playlists: [Playlist] = []
    private var loadTask: Task<[Playlist], Never>?

    /// Returns the cached playlists, fetching once if needed. Concurrent
    /// callers share the same in-flight request.
    func get() async -> [Playlist] {
        if !playlists.isEmpty { return playlists }
        if let loadTask { return await loadTask.value }

        let task = Task<[Playlist], Never> { [weak self] in
            #if os(iOS) || os(visionOS) || targetEnvironment(macCatalyst)
            do {
                let request = MusicLibraryRequest<Playlist>()
                let response = try await request.response()
                // Match AlbumView's previous filter: only user-editable playlists.
                let editable = response.items.filter { $0.kind == .userShared }
                await MainActor.run { self?.playlists = editable }
                return editable
            } catch {
                return []
            }
            #else
            return []
            #endif
        }
        loadTask = task
        let result = await task.value
        loadTask = nil
        return result
    }

    /// Drop the cache (e.g. after the user creates a playlist outside the app).
    func invalidate() {
        playlists = []
        loadTask = nil
    }
}
