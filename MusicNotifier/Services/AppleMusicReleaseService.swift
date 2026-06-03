//
//  AppleMusicReleaseService.swift
//  MusicNotifier
//

import Foundation
import MusicKit

/// Plain-data input so the fetcher can run off the MainActor without touching SwiftData models.
struct ArtistFetchInput: Sendable, Hashable {
    let providerID: String
    let name: String
    let provider: String
    let catalogArtistID: String?
    /// "artist" or "label" — labels fetch via RecordLabel.latestReleases instead
    /// of the artist's albums relationship.
    let kind: String

    init(providerID: String, name: String, provider: String, catalogArtistID: String?, kind: String = "artist") {
        self.providerID = providerID
        self.name = name
        self.provider = provider
        self.catalogArtistID = catalogArtistID
        self.kind = kind
    }
}

/// Plain-data output. Translated into `ReleaseData` on MainActor by the refresh service.
struct FetchedRelease: Sendable {
    let providerID: String
    let artistProviderID: String
    let artistName: String
    let title: String
    let releaseDate: Date?
    let artworkURL: URL?
    let albumURL: URL?
    let provider: String
    let type: String
}

struct ReleaseFetchResult: Sendable {
    let releases: [FetchedRelease]
    let failures: [String]
    let checkedArtists: Int
    let totalArtists: Int
    let resolvedCatalogIDs: [String: String]
    let resolvedArtworkURLs: [String: URL]
    let storefrontCountryCode: String?
}

struct ArtistFetchOutcome: Sendable {
    let input: ArtistFetchInput
    let releases: [FetchedRelease]
    let catalogArtistID: String?
    let artworkURL: URL?
    let errorMessage: String?
}

struct AppleMusicReleaseService {
    /// Hard cap per artist so a prolific catalogue can't blow the time budget.
    private let albumsPerArtist = 24

    /// Pre-resolve a batch of cached catalog IDs in a single network request.
    /// Returns a map of catalog ID → Artist for the IDs that resolved.
    func preResolveCachedArtists(catalogIDs: [String]) async -> [String: Artist] {
        guard !catalogIDs.isEmpty else { return [:] }

        var resolved: [String: Artist] = [:]

        // MusicKit caps batch requests; chunk to keep URL length reasonable.
        let chunkSize = 25
        for chunk in catalogIDs.chunked(into: chunkSize) {
            do {
                let request = MusicCatalogResourceRequest<Artist>(
                    matching: \.id,
                    memberOf: chunk.map { MusicItemID($0) }
                )
                let response = try await request.response()
                for artist in response.items {
                    resolved[artist.id.rawValue] = artist
                }
            } catch {
                // Fall through — individual fetchOne calls will re-resolve via search.
                continue
            }
        }

        return resolved
    }

    /// Fetch albums + catalog metadata for one artist. Used by the parallel refresh.
    /// When `preResolvedArtist` is supplied (from preResolveCachedArtists), we skip
    /// the resolution round-trip and go straight to fetching the albums relationship.
    func fetchOne(_ input: ArtistFetchInput, preResolvedArtist: Artist? = nil) async -> ArtistFetchOutcome {
        if input.kind == "label" {
            return await fetchLabelReleases(input)
        }
        do {
            let catalogArtist: Artist?
            if let preResolvedArtist {
                catalogArtist = preResolvedArtist
            } else {
                catalogArtist = try await withRetry { try await resolveCatalogArtist(for: input) }
            }

            guard let catalogArtist else {
                return ArtistFetchOutcome(
                    input: input, releases: [], catalogArtistID: nil,
                    artworkURL: nil, errorMessage: "no catalog match"
                )
            }

            let artworkURL = catalogArtist.artwork?.url(width: 300, height: 300)

            // Primary path: MusicKit relationship decode. Fast and gives full Album types.
            // Falls back to REST + lenient per-item decoding when MusicKit chokes on a
            // single bad album in the response (NSCocoaError 4864 / typeMismatch),
            // which kills the whole array.
            let mapped: [FetchedRelease]
            do {
                let detailed = try await withRetry({ try await catalogArtist.with([.albums]) })
                let allAlbums: [Album] = detailed.albums.map(Array.init) ?? []
                mapped = mapAlbums(Array(allAlbums.prefix(albumsPerArtist)), artistProviderID: input.providerID)
            } catch {
                print("MusicKit .with([.albums]) failed for \(input.name), falling back to REST: \(String(reflecting: error))")
                mapped = try await fetchAlbumsViaREST(
                    catalogArtistID: catalogArtist.id.rawValue,
                    artistProviderID: input.providerID
                )
            }

            return ArtistFetchOutcome(
                input: input,
                releases: dedupedVariants(mapped),
                catalogArtistID: catalogArtist.id.rawValue,
                artworkURL: artworkURL,
                errorMessage: nil
            )
        } catch {
            let nsError = error as NSError
            let detail = "\(error.localizedDescription) [\(nsError.domain) \(nsError.code)]"
            print("fetchOne failed for \(input.name): \(error) — full: \(String(reflecting: error))")
            return ArtistFetchOutcome(
                input: input, releases: [], catalogArtistID: nil,
                artworkURL: nil, errorMessage: detail
            )
        }
    }

    /// Label release fetcher. Resolves the catalog `RecordLabel` by ID then
    /// pulls its `latestReleases` relationship. Falls back gracefully when the
    /// label isn't found.
    private func fetchLabelReleases(_ input: ArtistFetchInput) async -> ArtistFetchOutcome {
        do {
            let labelID = input.catalogArtistID?.isEmpty == false ? input.catalogArtistID! : input.providerID
            guard !labelID.isEmpty else {
                return ArtistFetchOutcome(input: input, releases: [], catalogArtistID: nil, artworkURL: nil, errorMessage: "no label ID")
            }
            let request = MusicCatalogResourceRequest<RecordLabel>(
                matching: \.id, equalTo: MusicItemID(labelID)
            )
            guard let label = try await withRetry({ try await request.response() }).items.first else {
                return ArtistFetchOutcome(input: input, releases: [], catalogArtistID: nil, artworkURL: nil, errorMessage: "label not found")
            }
            let detailed = try await withRetry { try await label.with([.latestReleases]) }
            let albums: [Album] = detailed.latestReleases.map(Array.init) ?? []
            let mapped = mapAlbums(Array(albums.prefix(albumsPerArtist)), artistProviderID: input.providerID)
            return ArtistFetchOutcome(
                input: input,
                releases: dedupedVariants(mapped),
                catalogArtistID: label.id.rawValue,
                artworkURL: label.artwork?.url(width: 300, height: 300),
                errorMessage: nil
            )
        } catch {
            let nsError = error as NSError
            let detail = "\(error.localizedDescription) [\(nsError.domain) \(nsError.code)]"
            print("fetchLabelReleases failed for \(input.name): \(String(reflecting: error))")
            return ArtistFetchOutcome(input: input, releases: [], catalogArtistID: nil, artworkURL: nil, errorMessage: detail)
        }
    }

    func fetchReleases(
        for artists: [ArtistFetchInput],
        progress: (@Sendable (_ checkedArtists: Int, _ totalArtists: Int, _ currentArtistName: String) -> Void)? = nil
    ) async -> ReleaseFetchResult {
        var releases: [FetchedRelease] = []
        var failures: [String] = []
        var resolvedCatalogIDs: [String: String] = [:]
        var resolvedArtworkURLs: [String: URL] = [:]
        var checkedArtists = 0
        let storefrontCountryCode = await currentStorefrontCountryCode()

        for artist in artists {
            if Task.isCancelled { break }

            let displayName = artist.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !displayName.isEmpty else {
                checkedArtists += 1
                continue
            }

            progress?(checkedArtists, artists.count, artist.name)

            do {
                let catalogArtist = try await withRetry({ try await resolveCatalogArtist(for: artist) })

                guard let catalogArtist else {
                    failures.append("\(artist.name): no catalog match")
                    checkedArtists += 1
                    continue
                }

                resolvedCatalogIDs[artist.providerID] = catalogArtist.id.rawValue
                if let artwork = catalogArtist.artwork?.url(width: 300, height: 300) {
                    resolvedArtworkURLs[artist.providerID] = artwork
                }

                let detailed = try await withRetry({ try await catalogArtist.with([.albums]) })
                let allAlbums: [Album] = detailed.albums.map(Array.init) ?? []
                let albums = Array(allAlbums.prefix(albumsPerArtist))

                let mapped = albums.compactMap { album -> FetchedRelease? in
                    let releaseDate = album.releaseDate
                    if let releaseDate {
                        let daysFromRelease = Calendar.current.dateComponents([.day], from: releaseDate, to: Date()).day ?? 0
                        if releaseDate < Date() && daysFromRelease > 365 { return nil }
                    }

                    return FetchedRelease(
                        providerID: album.id.rawValue,
                        artistProviderID: artist.providerID,
                        artistName: album.artistName,
                        title: album.title,
                        releaseDate: releaseDate,
                        artworkURL: album.artwork?.url(width: 600, height: 600),
                        albumURL: album.url,
                        provider: MusicProvider.appleMusic.rawValue,
                        type: releaseKind(for: album).rawValue
                    )
                }

                releases.append(contentsOf: dedupedVariants(mapped))
            } catch {
                let nsError = error as NSError
                let detail = "\(error.localizedDescription) [\(nsError.domain) \(nsError.code)]"
                failures.append("\(artist.name): \(detail)")
                print("Apple Music release fetch failed for \(artist.name): \(error) — full: \(String(reflecting: error))")
            }

            checkedArtists += 1
            progress?(checkedArtists, artists.count, artist.name)

            if Task.isCancelled { break }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }

        return ReleaseFetchResult(
            releases: releases,
            failures: failures,
            checkedArtists: checkedArtists,
            totalArtists: artists.count,
            resolvedCatalogIDs: resolvedCatalogIDs,
            resolvedArtworkURLs: resolvedArtworkURLs,
            storefrontCountryCode: storefrontCountryCode
        )
    }

    func fetchDiagnosticRelease(for artistName: String) async -> String {
        do {
            var request = MusicCatalogSearchRequest(term: artistName, types: [Artist.self])
            request.limit = 1

            let response = try await request.response()
            if let artist = response.artists.first {
                let detailed = try await artist.with([.albums])
                let firstAlbum = detailed.albums?.first
                if let firstAlbum {
                    return "MusicKit OK. Artist \(artist.name) — first album: \(firstAlbum.title)."
                }
                return "MusicKit OK. Found artist \(artist.name) but no albums returned."
            } else {
                return "MusicKit search worked, but returned no artist for \(artistName)."
            }
        } catch {
            return "MusicKit search failed for \(artistName): \(error.localizedDescription). Debug: \(String(describing: error))"
        }
    }

    // MARK: - Private

    private func resolveCatalogArtist(for artist: ArtistFetchInput) async throws -> Artist? {
        if let cachedID = artist.catalogArtistID, !cachedID.isEmpty {
            let request = MusicCatalogResourceRequest<Artist>(
                matching: \.id,
                equalTo: MusicItemID(cachedID)
            )
            let response = try await request.response()
            if let catalogArtist = response.items.first {
                return catalogArtist
            }
        }

        let name = artist.name.trimmingCharacters(in: .whitespacesAndNewlines)
        var search = MusicCatalogSearchRequest(term: name, types: [Artist.self])
        search.limit = 5
        let searchResponse = try await search.response()

        if let exact = searchResponse.artists.first(where: { matches(name: $0.name, target: name) }) {
            return exact
        }
        return searchResponse.artists.first
    }

    private func matches(name: String, target: String) -> Bool {
        name.compare(target, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }

    private func mapAlbums(_ albums: [Album], artistProviderID: String) -> [FetchedRelease] {
        albums.compactMap { album in
            let releaseDate = album.releaseDate
            if let releaseDate {
                let daysFromRelease = Calendar.current.dateComponents([.day], from: releaseDate, to: Date()).day ?? 0
                if releaseDate < Date() && daysFromRelease > 365 { return nil }
            }

            return FetchedRelease(
                providerID: album.id.rawValue,
                artistProviderID: artistProviderID,
                artistName: album.artistName,
                title: album.title,
                releaseDate: releaseDate,
                artworkURL: album.artwork?.url(width: 600, height: 600),
                albumURL: album.url,
                provider: MusicProvider.appleMusic.rawValue,
                type: releaseKind(for: album).rawValue
            )
        }
    }

    /// REST fallback when MusicKit's `.with([.albums])` decode blows up on a bad
    /// item in the array. Decodes albums one-by-one; bad items are skipped so we
    /// still return everything that *did* decode for this artist.
    private func fetchAlbumsViaREST(catalogArtistID: String, artistProviderID: String) async throws -> [FetchedRelease] {
        let storefront = await currentStorefrontCountryCode() ?? "us"
        let path = "/v1/catalog/\(storefront)/artists/\(catalogArtistID)/albums?limit=\(albumsPerArtist)"
        guard let url = URL(string: "https://api.music.apple.com" + path) else { return [] }
        let dataRequest = MusicDataRequest(urlRequest: URLRequest(url: url))
        let response = try await dataRequest.response()
        let page = try JSONDecoder().decode(RESTAlbumPage.self, from: response.data)

        return page.data.compactMap { item -> FetchedRelease? in
            guard let attrs = item.attributes, let title = attrs.name else { return nil }
            let releaseDate = attrs.parsedReleaseDate
            if let releaseDate {
                let daysFromRelease = Calendar.current.dateComponents([.day], from: releaseDate, to: Date()).day ?? 0
                if releaseDate < Date() && daysFromRelease > 365 { return nil }
            }
            let artworkURL = attrs.artwork?.templatedURL(width: 600, height: 600)
            let albumURL = attrs.url.flatMap { URL(string: $0) }
            return FetchedRelease(
                providerID: item.id,
                artistProviderID: artistProviderID,
                artistName: attrs.artistName ?? "",
                title: title,
                releaseDate: releaseDate,
                artworkURL: artworkURL,
                albumURL: albumURL,
                provider: MusicProvider.appleMusic.rawValue,
                type: ReleaseKind.album.rawValue
            )
        }
    }

    private func currentStorefrontCountryCode() async -> String? {
        do {
            return try await MusicDataRequest.currentCountryCode
        } catch {
            return Locale.current.region?.identifier
        }
    }

    private func dedupedVariants(_ releases: [FetchedRelease]) -> [FetchedRelease] {
        var bestByKey: [String: FetchedRelease] = [:]
        for release in releases {
            let key = ReleaseTitleNormalizer.normalized(release.title)
            if let existing = bestByKey[key] {
                let existingDate = existing.releaseDate ?? .distantFuture
                let newDate = release.releaseDate ?? .distantFuture
                if newDate < existingDate || (newDate == existingDate && release.title.count < existing.title.count) {
                    bestByKey[key] = release
                }
            } else {
                bestByKey[key] = release
            }
        }
        return Array(bestByKey.values)
    }

    private func releaseKind(for album: Album) -> ReleaseKind {
        let title = album.title.lowercased()

        if album.isCompilation == true {
            return .compilation
        }
        if title.contains("remix") || title.contains("remixes") {
            return .remix
        }
        if title.contains("live") {
            return .liveAlbum
        }
        if album.isSingle == true {
            return .single
        }
        if title.contains(" ep") || title.hasSuffix("ep") || (album.trackCount > 1 && album.trackCount <= 6) {
            return .ep
        }

        return .album
    }

    private func withRetry<T>(_ operation: @escaping () async throws -> T) async throws -> T {
        var lastError: Error?
        let maxAttempts = 5

        for attempt in 0..<maxAttempts {
            do {
                return try await operation()
            } catch {
                lastError = error
                if Task.isCancelled { throw error }

                // Treat decode-failure-on-non-JSON as a rate-limit response (Apple
                // returns "API capacity exceeded" as plain text on 429). Back off
                // hard. For other errors, a short delay is fine.
                let isRateLimited = Self.looksLikeRateLimit(error)
                let baseMs: UInt64 = isRateLimited ? 1500 : 250
                let delayMs = baseMs * UInt64(1 << attempt) // exponential: 1.5s,3s,6s,12s,24s
                try? await Task.sleep(nanoseconds: delayMs * 1_000_000)
            }
        }

        throw lastError ?? CancellationError()
    }

    private static func looksLikeRateLimit(_ error: Error) -> Bool {
        let description = String(reflecting: error)
        return description.contains("Unexpected character 'A'")
            || description.contains("API capacity exceeded")
            || description.contains("429")
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}

// MARK: - Lenient album REST decoding

/// Wrapper that swallows decode failures for a single element so one bad
/// item in an array doesn't abort the entire array decode.
private struct FailableItem<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}

private struct RESTAlbumPage: Decodable {
    let data: [RESTAlbumItem]

    private enum CodingKeys: String, CodingKey { case data }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let items = try container.decode([FailableItem<RESTAlbumItem>].self, forKey: .data)
        self.data = items.compactMap(\.value)
    }
}

private struct RESTAlbumItem: Decodable {
    let id: String
    let attributes: RESTAlbumAttributes?
}

private struct RESTAlbumAttributes: Decodable {
    let name: String?
    let artistName: String?
    let releaseDate: String?
    let url: String?
    let artwork: RESTAlbumArtwork?

    var parsedReleaseDate: Date? {
        guard let releaseDate else { return nil }
        let isoFull = DateFormatter()
        isoFull.dateFormat = "yyyy-MM-dd"
        isoFull.locale = Locale(identifier: "en_US_POSIX")
        isoFull.timeZone = TimeZone(secondsFromGMT: 0)
        if let date = isoFull.date(from: releaseDate) { return date }
        let yearOnly = DateFormatter()
        yearOnly.dateFormat = "yyyy"
        yearOnly.locale = Locale(identifier: "en_US_POSIX")
        yearOnly.timeZone = TimeZone(secondsFromGMT: 0)
        return yearOnly.date(from: releaseDate)
    }
}

private struct RESTAlbumArtwork: Decodable {
    let url: String?

    /// Apple Music artwork URLs include `{w}` and `{h}` placeholders.
    func templatedURL(width: Int, height: Int) -> URL? {
        guard let url else { return nil }
        let resolved = url
            .replacingOccurrences(of: "{w}", with: String(width))
            .replacingOccurrences(of: "{h}", with: String(height))
        return URL(string: resolved)
    }
}
