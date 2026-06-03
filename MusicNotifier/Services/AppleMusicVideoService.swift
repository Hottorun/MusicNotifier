//
//  AppleMusicVideoService.swift
//  MusicNotifier
//

import Foundation
import MusicKit

struct FetchedVideo: Sendable {
    let providerID: String
    let artistProviderID: String
    let artistName: String
    let title: String
    let kind: VideoKind
    let sourceName: String?
    let artworkURL: URL?
    let videoURL: URL?
    let releaseDate: Date?
    let durationMs: Int?
}

/// Two-pass video fetcher:
///  1. Per tracked artist → `Artist.with([.musicVideos])` returns their own
///     music videos (clips, sessions, lyric videos).
///  2. A small set of catalog searches against interview hosts/shows
///     ("Zane Lowe", "Apple Music Sessions", etc.). Results are filtered
///     locally to videos whose title mentions a tracked artist — this catches
///     interviews where the artist is the guest, not the primary credit.
struct AppleMusicVideoService {
    /// Cap per artist so a band with 200 lyric videos doesn't dominate the feed.
    private let videosPerArtist = 15

    /// Catalog search terms used to find interview-style content. Each term is
    /// one network round-trip; keep the list short.
    private let interviewSearchTerms = [
        "Zane Lowe interview",
        "Apple Music Sessions",
        "Apple Music Up Next",
        "Apple Music 1"
    ]

    /// Heuristic: catalog music videos with these tokens in the title are
    /// interviews/sessions rather than music clips.
    private static let interviewKeywords = [
        "interview", "talks", "in conversation", "sit down",
        "zane lowe", "apple music", "sessions", "up next", "behind the",
        "documentary", "story behind", "track by track", "speaks", "live from"
    ]

    static func classify(title: String, sourceName: String?) -> VideoKind {
        let haystack = "\(title) \(sourceName ?? "")".lowercased()
        return interviewKeywords.contains(where: { haystack.contains($0) }) ? .interview : .musicVideo
    }

    /// Fan-out fetch. Returns all newly observed videos across the tracked roster.
    func fetchVideos(for inputs: [ArtistFetchInput]) async -> [FetchedVideo] {
        let appleInputs = inputs.filter { MusicProvider.fromStoredName($0.provider) == .appleMusic }
        guard !appleInputs.isEmpty else { return [] }

        var collected: [FetchedVideo] = []
        var seenIDs: Set<String> = []

        // Per-artist music videos (sequential with light concurrency to avoid 429).
        await withTaskGroup(of: [FetchedVideo].self) { group in
            let maxConcurrent = 3
            var index = 0

            func enqueue(_ i: Int) {
                let input = appleInputs[i]
                group.addTask {
                    await self.fetchArtistVideos(input)
                }
            }

            while index < min(maxConcurrent, appleInputs.count) {
                enqueue(index)
                index += 1
            }

            while let batch = await group.next() {
                if Task.isCancelled { break }
                for video in batch where !seenIDs.contains(video.providerID) {
                    seenIDs.insert(video.providerID)
                    collected.append(video)
                }
                if index < appleInputs.count && !Task.isCancelled {
                    enqueue(index)
                    index += 1
                }
            }
        }

        // Interview pass — small set of catalog searches, filtered by tracked names.
        let trackedNames = appleInputs.map { ($0.providerID, $0.name) }
        let interviewMatches = await fetchInterviewMatches(trackedArtists: trackedNames)
        for video in interviewMatches where !seenIDs.contains(video.providerID) {
            seenIDs.insert(video.providerID)
            collected.append(video)
        }

        return collected
    }

    private func fetchArtistVideos(_ input: ArtistFetchInput) async -> [FetchedVideo] {
        guard let catalogID = input.catalogArtistID, !catalogID.isEmpty else { return [] }
        do {
            let request = MusicCatalogResourceRequest<Artist>(
                matching: \.id, equalTo: MusicItemID(catalogID)
            )
            guard let artist = try await request.response().items.first else { return [] }
            let detailed = try await artist.with([.musicVideos])
            let videos: [MusicVideo] = detailed.musicVideos.map(Array.init) ?? []
            return videos.prefix(videosPerArtist).map { mv in
                let title = mv.title
                let sourceName = mv.artistName
                return FetchedVideo(
                    providerID: mv.id.rawValue,
                    artistProviderID: input.providerID,
                    artistName: input.name,
                    title: title,
                    kind: Self.classify(title: title, sourceName: sourceName),
                    sourceName: sourceName,
                    artworkURL: mv.artwork?.url(width: 600, height: 600),
                    videoURL: mv.url,
                    releaseDate: mv.releaseDate,
                    durationMs: mv.duration.map { Int($0 * 1000) }
                )
            }
        } catch {
            Log.v("AppleMusicVideoService.fetchArtistVideos failed for \(input.name): \(error)")
            return []
        }
    }

    /// Search a handful of canonical interview terms; for each result, check if
    /// any tracked artist's name appears in the video title or its artistName.
    /// Returns one `FetchedVideo` per match, attributed to the tracked artist.
    private func fetchInterviewMatches(trackedArtists: [(providerID: String, name: String)]) async -> [FetchedVideo] {
        guard !trackedArtists.isEmpty else { return [] }
        // Lowercased lookup so contains() doesn't care about capitalization.
        let lookup: [(providerID: String, name: String, lowered: String)] = trackedArtists.map {
            ($0.providerID, $0.name, $0.name.lowercased())
        }
        var collected: [FetchedVideo] = []
        var seen: Set<String> = []

        for term in interviewSearchTerms {
            if Task.isCancelled { break }
            do {
                var request = MusicCatalogSearchRequest(term: term, types: [MusicVideo.self])
                request.limit = 25
                let response = try await request.response()
                for mv in response.musicVideos {
                    if seen.contains(mv.id.rawValue) { continue }
                    let titleLower = mv.title.lowercased()
                    let artistLower = mv.artistName.lowercased()
                    guard let match = lookup.first(where: {
                        titleLower.contains($0.lowered) || artistLower.contains($0.lowered)
                    }) else { continue }
                    seen.insert(mv.id.rawValue)
                    collected.append(FetchedVideo(
                        providerID: mv.id.rawValue,
                        artistProviderID: match.providerID,
                        artistName: match.name,
                        title: mv.title,
                        kind: .interview,
                        sourceName: mv.artistName,
                        artworkURL: mv.artwork?.url(width: 600, height: 600),
                        videoURL: mv.url,
                        releaseDate: mv.releaseDate,
                        durationMs: mv.duration.map { Int($0 * 1000) }
                    ))
                }
            } catch {
                Log.v("AppleMusicVideoService.fetchInterviewMatches(\(term)) failed: \(error)")
            }
        }
        return collected
    }
}
