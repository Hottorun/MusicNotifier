//
//  LastFMService.swift
//  MusicNotifier
//

import Foundation

struct LastFMArtistInfo: Codable, Hashable {
    let listeners: String
    let playcount: String
    let bio: String
    let similarArtists: [String]
}

struct LastFMAlbumInfo: Codable, Hashable {
    let listeners: String?
    let playcount: String?
    let tags: [String]
}

struct LastFMTrackInfo: Codable, Hashable {
    let title: String
    let playcount: Int
}

struct LastFMService {
    private let apiKey: String
    private let cacheTTL: TimeInterval = 60 * 60 * 24

    init(apiKey: String) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isConfigured: Bool {
        !apiKey.isEmpty
    }

    /// Synchronous cache reads used to seed `@State` during view init. Returns
    /// nil if there's no cached value (or it's expired) — callers should then
    /// fall back to the async fetch path which will network + refresh the
    /// cache. No-network, no-await; safe to call from a SwiftUI initializer.
    func cachedArtistInfo(artistName: String) -> LastFMArtistInfo? {
        cachedValue(for: "artist:\(artistName.lowercased())")
    }

    func cachedAlbumInfo(artistName: String, albumTitle: String) -> LastFMAlbumInfo? {
        cachedValue(for: "album:\(artistName.lowercased()):\(albumTitle.lowercased())")
    }

    func fetchArtistInfo(artistName: String) async throws -> LastFMArtistInfo {
        let cacheKey = "artist:\(artistName.lowercased())"
        if let cached: LastFMArtistInfo = cachedValue(for: cacheKey) {
            return cached
        }

        let response: ArtistInfoResponse = try await request(method: "artist.getinfo", parameters: [
            "artist": artistName,
            "autocorrect": "1"
        ])

        let artist = response.artist
        let info = LastFMArtistInfo(
            listeners: artist.stats.listeners,
            playcount: artist.stats.playcount,
            bio: cleanSummary(artist.bio?.summary ?? ""),
            similarArtists: artist.similar?.artist.prefix(8).map(\.name) ?? []
        )
        cache(info, for: cacheKey)
        return info
    }

    func fetchTrackInfo(artistName: String, trackTitle: String) async throws -> LastFMTrackInfo {
        let cacheKey = "track:\(artistName.lowercased()):\(trackTitle.lowercased())"
        if let cached: LastFMTrackInfo = cachedValue(for: cacheKey) {
            return cached
        }

        let response: TrackInfoResponse = try await request(method: "track.getinfo", parameters: [
            "artist": artistName,
            "track": trackTitle,
            "autocorrect": "1"
        ])

        let info = LastFMTrackInfo(
            title: response.track.name,
            playcount: Int(response.track.playcount ?? "0") ?? 0
        )
        cache(info, for: cacheKey)
        return info
    }

    func fetchAlbumInfo(artistName: String, albumTitle: String) async throws -> LastFMAlbumInfo {
        let cacheKey = "album:\(artistName.lowercased()):\(albumTitle.lowercased())"
        if let cached: LastFMAlbumInfo = cachedValue(for: cacheKey) {
            return cached
        }

        let response: AlbumInfoResponse = try await request(method: "album.getinfo", parameters: [
            "artist": artistName,
            "album": albumTitle,
            "autocorrect": "1"
        ])

        let album = response.album
        let info = LastFMAlbumInfo(
            listeners: album.listeners,
            playcount: album.playcount,
            tags: album.tags?.tag.prefix(8).map(\.name) ?? []
        )
        cache(info, for: cacheKey)
        return info
    }

    private func request<Response: Decodable>(method: String, parameters: [String: String]) async throws -> Response {
        var components = URLComponents(string: "https://ws.audioscrobbler.com/2.0/")!
        var queryItems = [
            URLQueryItem(name: "method", value: method),
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "format", value: "json")
        ]
        queryItems.append(contentsOf: parameters.map { URLQueryItem(name: $0.key, value: $0.value) })
        components.queryItems = queryItems

        guard let url = components.url else {
            throw URLError(.badURL)
        }

        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }

        let decoder = JSONDecoder()
        if let apiError = try? decoder.decode(LastFMErrorResponse.self, from: data) {
            throw LastFMError.api(apiError.message)
        }
        return try decoder.decode(Response.self, from: data)
    }

    private func cachedValue<Value: Codable>(for key: String) -> Value? {
        guard let data = UserDefaults.standard.data(forKey: cacheStorageKey(key)),
              let wrapper = try? JSONDecoder().decode(CacheWrapper<Value>.self, from: data),
              Date().timeIntervalSince(wrapper.savedAt) < cacheTTL else {
            return nil
        }

        return wrapper.value
    }

    private func cache<Value: Codable>(_ value: Value, for key: String) {
        let wrapper = CacheWrapper(savedAt: Date(), value: value)
        guard let data = try? JSONEncoder().encode(wrapper) else { return }
        UserDefaults.standard.set(data, forKey: cacheStorageKey(key))
    }

    private func cacheStorageKey(_ key: String) -> String {
        "lastfm.cache.\(key)"
    }

    private func cleanSummary(_ summary: String) -> String {
        let withoutLinks = summary.replacingOccurrences(
            of: #"<a\b[^>]*>.*?</a>"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        let withoutTags = withoutLinks.replacingOccurrences(
            of: #"<[^>]+>"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        return withoutTags
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct CacheWrapper<Value: Codable>: Codable {
    let savedAt: Date
    let value: Value
}

private struct ArtistInfoResponse: Decodable {
    let artist: LastFMArtistPayload
}

private struct LastFMArtistPayload: Decodable {
    let stats: LastFMStats
    let bio: LastFMBio?
    let similar: LastFMSimilarArtists?
}

private struct LastFMStats: Decodable {
    let listeners: String
    let playcount: String
}

private struct LastFMBio: Decodable {
    let summary: String
}

private struct LastFMSimilarArtists: Decodable {
    let artist: [LastFMNamedItem]
}

private struct AlbumInfoResponse: Decodable {
    let album: LastFMAlbumPayload
}

private struct LastFMAlbumPayload: Decodable {
    let listeners: String?
    let playcount: String?
    let tags: LastFMTags?
}

private struct LastFMTags: Decodable {
    let tag: [LastFMNamedItem]
}

private struct LastFMNamedItem: Decodable {
    let name: String
}

private struct TrackInfoResponse: Decodable {
    let track: LastFMTrackPayload
}

private struct LastFMTrackPayload: Decodable {
    let name: String
    let playcount: String?
}

private struct LastFMErrorResponse: Decodable {
    let error: Int
    let message: String
}

enum LastFMError: LocalizedError {
    case api(String)

    var errorDescription: String? {
        switch self {
        case .api(let message):
            return message
        }
    }
}
