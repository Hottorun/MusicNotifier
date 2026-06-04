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

        // Per-artist music videos AND the interview search pass run concurrently —
        // they hit independent endpoints so there's no reason to serialize them.
        async let perArtistTask: [FetchedVideo] = {
            var local: [FetchedVideo] = []
            var localSeen: Set<String> = []
            await withTaskGroup(of: [FetchedVideo].self) { group in
                let maxConcurrent = 4
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
                    for video in batch where !localSeen.contains(video.providerID) {
                        localSeen.insert(video.providerID)
                        local.append(video)
                    }
                    if index < appleInputs.count && !Task.isCancelled {
                        enqueue(index)
                        index += 1
                    }
                }
            }
            return local
        }()

        let trackedNames = appleInputs.map { ($0.providerID, $0.name) }
        // Opt-in: interview discovery costs 4 extra catalog searches. Users who
        // don't want their feed cluttered with Zane Lowe clips can keep it off
        // and the refresh runs that much faster.
        let includeInterviews = UserDefaults.standard.object(forKey: AppSettings.includeInterviewVideos) as? Bool ?? false
        async let interviewTask: [FetchedVideo] = includeInterviews
            ? self.fetchInterviewMatches(trackedArtists: trackedNames)
            : []

        let (perArtist, interviews) = await (perArtistTask, interviewTask)

        for video in perArtist where !seenIDs.contains(video.providerID) {
            seenIDs.insert(video.providerID)
            collected.append(video)
        }
        for video in interviews where !seenIDs.contains(video.providerID) {
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
        // Fire all 4 catalog searches in parallel — they're independent and previously
        // ran back-to-back (the dominant cost in the videos tail). Each task returns
        // a list of (videoID, MusicVideo); we then dedupe + match against tracked names
        // sequentially on the gathered union.
        let terms = interviewSearchTerms
        struct CandidateBatch: Sendable {
            let items: [(id: String, title: String, artistName: String, artworkURL: URL?, videoURL: URL?, releaseDate: Date?, durationMs: Int?)]
        }

        let batches = await withTaskGroup(of: CandidateBatch.self) { group -> [CandidateBatch] in
            for term in terms {
                group.addTask {
                    do {
                        var request = MusicCatalogSearchRequest(term: term, types: [MusicVideo.self])
                        request.limit = 25
                        let response = try await request.response()
                        let items = response.musicVideos.map { mv in
                            (id: mv.id.rawValue,
                             title: mv.title,
                             artistName: mv.artistName,
                             artworkURL: mv.artwork?.url(width: 600, height: 600),
                             videoURL: mv.url,
                             releaseDate: mv.releaseDate,
                             durationMs: mv.duration.map { Int($0 * 1000) })
                        }
                        return CandidateBatch(items: items)
                    } catch {
                        Log.v("AppleMusicVideoService.fetchInterviewMatches(\(term)) failed: \(error)")
                        return CandidateBatch(items: [])
                    }
                }
            }
            var collected: [CandidateBatch] = []
            for await batch in group { collected.append(batch) }
            return collected
        }

        var collected: [FetchedVideo] = []
        var seen: Set<String> = []
        for batch in batches {
            for item in batch.items {
                if seen.contains(item.id) { continue }
                let titleLower = item.title.lowercased()
                let artistLower = item.artistName.lowercased()
                guard let match = lookup.first(where: {
                    titleLower.contains($0.lowered) || artistLower.contains($0.lowered)
                }) else { continue }
                seen.insert(item.id)
                collected.append(FetchedVideo(
                    providerID: item.id,
                    artistProviderID: match.providerID,
                    artistName: match.name,
                    title: item.title,
                    kind: .interview,
                    sourceName: item.artistName,
                    artworkURL: item.artworkURL,
                    videoURL: item.videoURL,
                    releaseDate: item.releaseDate,
                    durationMs: item.durationMs
                ))
            }
        }
        return collected
    }
}
