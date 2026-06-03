//
//  AppleMusicPlaylistSync.swift
//  MusicNotifier
//
//  Maintains an Apple Music library playlist that mirrors newly-discovered
//  releases from tracked artists. Lets the user listen to "what's new" from
//  CarPlay, HomePod, Watch, or the Music app without ever opening this app.
//
//  The playlist is created on first sync and its ID persisted. Each refresh
//  appends new release songs that aren't already in the playlist (tracked via
//  the existing `notifiedAt` flag — same items we send notifications for).
//

import Foundation
import MusicKit

/// Lightweight projection of a release used by playlist routing. Carries
/// everything the rule engine needs (kind, artist genres) so the sync can
/// run without re-fetching SwiftData.
struct PlaylistSyncCandidate {
    let albumProviderID: String
    let kind: String
    let artistGenres: [String]
}

#if os(iOS) || os(visionOS) || targetEnvironment(macCatalyst)

struct AppleMusicPlaylistSync {
    private static let defaultName = "Music Notifier"
    private static let defaultDescription = "New releases from artists you track"

    /// Two-phase sync: (1) the default "Music Notifier" playlist if the toggle
    /// is on; (2) each user-defined `PlaylistRule` that matches a candidate.
    /// Both phases are best-effort — individual failures don't abort the batch.
    @MainActor
    func sync(candidates: [PlaylistSyncCandidate]) async {
        guard !candidates.isEmpty else { return }
        let albumIDs = candidates.map(\.albumProviderID).filter { !$0.isEmpty }
        guard !albumIDs.isEmpty else { return }

        if UserDefaults.standard.bool(forKey: AppSettings.syncToApplePlaylist) {
            do {
                let playlist = try await ensureDefaultPlaylist()
                for id in albumIDs {
                    await addAlbumTracks(albumID: id, to: playlist)
                }
            } catch {
                print("[PlaylistSync] default playlist failed: \(String(reflecting: error))")
            }
        }

        // Rule-based routing. Each rule owns its own playlist — we create one
        // by the rule's name on first match and persist the resulting ID back
        // to the rule so we don't recreate on every refresh.
        var rules = PlaylistRulesStore.load()
        var rulesChanged = false
        for index in rules.indices where rules[index].enabled {
            let rule = rules[index]
            let matching = candidates.filter { matches($0, rule: rule) }
            guard !matching.isEmpty else { continue }
            do {
                let (playlist, newlyCreatedID) = try await ensureRulePlaylist(rule)
                if let newID = newlyCreatedID {
                    rules[index].targetPlaylistID = newID
                    rulesChanged = true
                }
                for candidate in matching {
                    await addAlbumTracks(albumID: candidate.albumProviderID, to: playlist)
                }
            } catch {
                print("[PlaylistSync] rule '\(rule.name)' failed: \(String(reflecting: error))")
            }
        }
        if rulesChanged {
            PlaylistRulesStore.save(rules)
        }
    }

    /// Resolve or create the playlist for a rule. Returns the playlist and,
    /// when a new playlist was created, its ID so the caller can persist it.
    @MainActor
    private func ensureRulePlaylist(_ rule: PlaylistRule) async throws -> (Playlist, String?) {
        // Cached path: rule already has an ID from a previous sync.
        if !rule.targetPlaylistID.isEmpty,
           let existing = try? await fetchPlaylist(id: rule.targetPlaylistID) {
            return (existing, nil)
        }
        // Otherwise create fresh, named after the rule.
        let title = rule.name.trimmingCharacters(in: .whitespaces).isEmpty ? "Untitled rule" : rule.name
        let created = try await MusicLibrary.shared.createPlaylist(
            name: title,
            description: "Auto-managed by Music Notifier"
        )
        return (created, created.id.rawValue)
    }

    /// True when this candidate satisfies every condition the rule sets.
    /// Empty conditions are wildcards.
    private func matches(_ candidate: PlaylistSyncCandidate, rule: PlaylistRule) -> Bool {
        let genreOK: Bool
        if rule.matchGenres.isEmpty {
            genreOK = true
        } else {
            let ruleSet = Set(rule.matchGenres.map { $0.lowercased() })
            let candidateSet = Set(candidate.artistGenres.map { $0.lowercased() })
            genreOK = !ruleSet.intersection(candidateSet).isEmpty
        }

        let kindOK = rule.matchKinds.isEmpty
            || rule.matchKinds.contains { $0.caseInsensitiveCompare(candidate.kind) == .orderedSame }

        return genreOK && kindOK
    }

    /// Resolve (or create) the default managed playlist. Stores the resulting
    /// ID so we don't recreate on every refresh.
    @MainActor
    private func ensureDefaultPlaylist() async throws -> Playlist {
        if let storedID = UserDefaults.standard.string(forKey: AppSettings.appleMusicPlaylistID),
           !storedID.isEmpty,
           let existing = try? await fetchPlaylist(id: storedID) {
            return existing
        }
        let created = try await MusicLibrary.shared.createPlaylist(
            name: Self.defaultName,
            description: Self.defaultDescription
        )
        UserDefaults.standard.set(created.id.rawValue, forKey: AppSettings.appleMusicPlaylistID)
        return created
    }

    private func fetchPlaylist(id: String) async throws -> Playlist? {
        let request = MusicLibraryRequest<Playlist>()
        let response = try await request.response()
        return response.items.first { $0.id.rawValue == id }
    }

    /// Fetch tracks for the album and append them to the playlist via MusicLibrary.
    /// Failures here are non-fatal — we'd rather skip a track than abort the sync.
    private func addAlbumTracks(albumID: String, to playlist: Playlist) async {
        do {
            let albumRequest = MusicCatalogResourceRequest<Album>(matching: \.id, equalTo: MusicItemID(albumID))
            let albumResponse = try await albumRequest.response()
            guard let album = albumResponse.items.first else { return }
            // Adding the album itself is one call and pulls every song with it —
            // more efficient than adding tracks individually, and the user gets the
            // album as a unit in their library / playlist.
            try await MusicLibrary.shared.add(album, to: playlist)
        } catch {
            print("[PlaylistSync] album \(albumID) skipped: \(error.localizedDescription)")
        }
    }
}

#else

// Stub for non-iOS targets (macOS-only builds without Catalyst): MusicLibrary
// writes aren't available, so the sync becomes a no-op.
struct AppleMusicPlaylistSync {
    @MainActor
    func sync(candidates: [PlaylistSyncCandidate]) async {}
}

#endif
