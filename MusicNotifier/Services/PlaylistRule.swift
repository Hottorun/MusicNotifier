//
//  PlaylistRule.swift
//  MusicNotifier
//
//  User-defined routing rules for new releases. Each rule maps a filter
//  (by genre, release kind, or both) to a target Apple Music playlist. When a
//  refresh discovers new releases, AppleMusicPlaylistSync evaluates the rules
//  in order and routes each release to whichever playlists it matches.
//
//  Stored as JSON in UserDefaults (simple, syncs to iCloud via NSUbiquitous if
//  ever needed; no SwiftData schema migration).
//

import Foundation

struct PlaylistRule: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    /// User-visible name. Also used as the playlist title — each rule creates
    /// (and owns) its own Apple Music playlist with this name.
    var name: String
    /// Cached `Playlist.id.rawValue` after the playlist has been created. Empty
    /// until the first sync, then populated so we don't re-create on every run.
    var targetPlaylistID: String
    /// Genre names the release's artist must include to match. Empty = any genre.
    var matchGenres: [String]
    /// Release kinds (album, single, etc.) to match. Empty = any kind.
    var matchKinds: [String]
    var enabled: Bool = true
}

enum PlaylistRulesStore {
    private static let key = "playlistRules.v1"

    static func load() -> [PlaylistRule] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let rules = try? JSONDecoder().decode([PlaylistRule].self, from: data) else {
            return []
        }
        return rules
    }

    static func save(_ rules: [PlaylistRule]) {
        guard let data = try? JSONEncoder().encode(rules) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
