//
//  AppleMusicLibraryImportService.swift
//  MusicNotifier
//

import Foundation
import MusicKit
import SwiftData

enum ArtistImportMode: String, CaseIterable, Identifiable {
    case all = "All Artists"
    case skipCollaborations = "No & Names"
    case favoritesOnly = "Favorites Only"

    var id: String { rawValue }

    var description: String {
        switch self {
        case .all:
            "Import every artist found in your Apple Music library."
        case .skipCollaborations:
            "Skip artist names containing &, which often represent collaborations."
        case .favoritesOnly:
            "Import only artists you've favorited (hearted) in Apple Music."
        }
    }
}

struct AppleMusicLibraryImportService {
    @MainActor
    func importArtists(mode: ArtistImportMode, into modelContext: ModelContext) async throws -> Int {
        let authorization = await MusicAuthorization.request()
        guard authorization == .authorized else {
            throw ArtistImportError.notAuthorized
        }

        let fetchedArtists: [Artist]
        if mode == .favoritesOnly {
            fetchedArtists = try await fetchFavoriteArtists()
        } else {
            fetchedArtists = try await fetchAllLibraryArtists()
        }
        Log.v("[Favorites] fetched \(fetchedArtists.count) artists, applying filter for mode=\(mode.rawValue)")
        let filteredArtists = fetchedArtists.filter { artist in
            let keep = ArtistImportFilter.shouldImport(name: artist.name, mode: mode)
            if !keep { Log.v("[Favorites] filter rejected: \(artist.name)") }
            return keep
        }
        Log.v("[Favorites] after filter: \(filteredArtists.count) artists will be imported")

        for artist in filteredArtists {
            let providerID = artist.id.rawValue
            let descriptor = FetchDescriptor<ArtistData>(
                predicate: #Predicate { storedArtist in
                    storedArtist.providerID == providerID
                }
            )

            if let existingArtist = try modelContext.fetch(descriptor).first {
                existingArtist.name = artist.name
                existingArtist.artworkURL = artist.artwork?.url(width: 300, height: 300)
            } else {
                modelContext.insert(
                    ArtistData(
                        providerID: providerID,
                        name: artist.name,
                        artworkURL: artist.artwork?.url(width: 300, height: 300)
                    )
                )
            }
        }

        try modelContext.save()

        // Kick off background artwork backfill — library API often returns nil artwork.
        Task { await backfillMissingArtwork(in: modelContext) }

        return filteredArtists.count
    }

    /// Look up catalog artist by name for every stored artist with nil/missing artwork
    /// and persist the catalog artwork URL. Runs in parallel off-main for speed.
    @MainActor
    func backfillMissingArtwork(in modelContext: ModelContext) async {
        let descriptor = FetchDescriptor<ArtistData>()
        guard let allArtists = try? modelContext.fetch(descriptor) else { return }

        let lookups: [ArtworkLookup] = allArtists
            .filter { artist in
                // Also refetch when we don't have genres yet so existing artists
                // get their genre metadata populated on the next backfill pass.
                artist.artworkURL == nil
                    || artist.catalogArtistID == nil
                    || (artist.genres?.isEmpty ?? true)
            }
            .map { ArtworkLookup(providerID: $0.providerID, name: $0.name, catalogArtistID: $0.catalogArtistID) }

        guard !lookups.isEmpty else { return }

        // Run lookups off-main on the cooperative pool.
        let results = await Task.detached(priority: .utility) {
            await runArtworkLookups(lookups)
        }.value

        for result in results {
            guard let artist = allArtists.first(where: { $0.providerID == result.providerID }) else { continue }
            if let catalogID = result.catalogID {
                artist.catalogArtistID = catalogID
            }
            if let artwork = result.artworkURL {
                artist.artworkURL = artwork
            }
            if !result.genres.isEmpty {
                artist.genres = result.genres
            }
        }
        try? modelContext.save()
    }

    fileprivate static func fetchArtwork(for lookup: ArtworkLookup) async -> ArtworkResult {
        do {
            // Cached catalog ID path
            if let cachedID = lookup.catalogArtistID, !cachedID.isEmpty {
                let request = MusicCatalogResourceRequest<Artist>(
                    matching: \.id, equalTo: MusicItemID(cachedID)
                )
                if let artist = try await request.response().items.first {
                    return ArtworkResult(
                        providerID: lookup.providerID,
                        catalogID: artist.id.rawValue,
                        artworkURL: artist.artwork?.url(width: 300, height: 300),
                        genres: artist.genreNames ?? []
                    )
                }
            }

            // Search by name
            let name = lookup.name.trimmingCharacters(in: .whitespacesAndNewlines)
            var search = MusicCatalogSearchRequest(term: name, types: [Artist.self])
            search.limit = 5
            let response = try await search.response()
            let match = response.artists.first(where: {
                $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
            }) ?? response.artists.first

            guard let artist = match else {
                return ArtworkResult(providerID: lookup.providerID, catalogID: nil, artworkURL: nil, genres: [])
            }
            return ArtworkResult(
                providerID: lookup.providerID,
                catalogID: artist.id.rawValue,
                artworkURL: artist.artwork?.url(width: 300, height: 300),
                genres: artist.genreNames ?? []
            )
        } catch {
            return ArtworkResult(providerID: lookup.providerID, catalogID: nil, artworkURL: nil)
        }
    }

    /// Search Apple Music for record labels matching the term. Used by the
    /// "Follow label" flow in the Artists tab — returns up to 15 candidates.
    func searchCatalogLabels(term: String) async throws -> [RecordLabel] {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var request = MusicCatalogSearchRequest(term: trimmed, types: [RecordLabel.self])
        request.limit = 15
        let response = try await request.response()
        return Array(response.recordLabels)
    }

    /// Persist a label as an `ArtistData` row with `kind = "label"`. Reuses the
    /// same model and refresh pipeline as artists.
    @MainActor
    func importLabel(_ label: RecordLabel, into modelContext: ModelContext, tracked: Bool = true) throws {
        let providerID = label.id.rawValue
        let descriptor = FetchDescriptor<ArtistData>(
            predicate: #Predicate { stored in
                stored.providerID == providerID
            }
        )

        if let existing = try modelContext.fetch(descriptor).first {
            existing.name = label.name
            existing.artworkURL = label.artwork?.url(width: 300, height: 300)
            existing.isTracked = tracked || existing.isTracked
            existing.kind = "label"
        } else {
            let row = ArtistData(
                providerID: providerID,
                name: label.name,
                artworkURL: label.artwork?.url(width: 300, height: 300),
                isTracked: tracked
            )
            row.catalogArtistID = providerID
            row.kind = "label"
            modelContext.insert(row)
        }
        try modelContext.save()
    }

    func searchCatalogArtists(term: String) async throws -> [Artist] {
        let trimmedTerm = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTerm.isEmpty else {
            return []
        }

        var request = MusicCatalogSearchRequest(term: trimmedTerm, types: [Artist.self])
        request.limit = 15

        let response = try await request.response()
        return Array(response.artists)
    }

    @MainActor
    func importCatalogArtist(_ artist: Artist, into modelContext: ModelContext, tracked: Bool = true) throws {
        let providerID = artist.id.rawValue
        let descriptor = FetchDescriptor<ArtistData>(
            predicate: #Predicate { storedArtist in
                storedArtist.providerID == providerID
            }
        )

        if let existingArtist = try modelContext.fetch(descriptor).first {
            existingArtist.name = artist.name
            existingArtist.artworkURL = artist.artwork?.url(width: 300, height: 300)
            existingArtist.isTracked = tracked || existingArtist.isTracked
        } else {
            modelContext.insert(
                ArtistData(
                    providerID: providerID,
                    name: artist.name,
                    artworkURL: artist.artwork?.url(width: 300, height: 300),
                    isTracked: tracked
                )
            )
        }

        try modelContext.save()
    }

    @MainActor
    func importCatalogArtist(_ artist: ProviderArtistSearchResult, into modelContext: ModelContext, tracked: Bool = true) throws {
        let providerID = artist.id
        let descriptor = FetchDescriptor<ArtistData>(
            predicate: #Predicate { storedArtist in
                storedArtist.providerID == providerID
            }
        )

        if let existingArtist = try modelContext.fetch(descriptor).first {
            existingArtist.name = artist.name
            existingArtist.artworkURL = artist.artworkURL
            existingArtist.provider = MusicProvider.appleMusic.rawValue
            existingArtist.isTracked = tracked || existingArtist.isTracked
        } else {
            modelContext.insert(
                ArtistData(
                    providerID: providerID,
                    name: artist.name,
                    artworkURL: artist.artworkURL,
                    isTracked: tracked,
                    provider: MusicProvider.appleMusic.rawValue
                )
            )
        }

        try modelContext.save()
    }

    private func fetchAllLibraryArtists() async throws -> [Artist] {
        let request = MusicLibraryRequest<Artist>()
        let response = try await request.response()
        return Array(response.items)
    }

    /// Fetch every catalog artist the user has favorited (hearted) in Apple Music.
    /// MusicKit Swift has no direct favorites API, so we hit the REST endpoint
    /// `/v1/me/library/artists` with `extend=inFavorites` to surface the favorite flag
    /// and `include=catalog` so each item carries its catalog artist ID. We paginate,
    /// keep only `inFavorites == true`, then batch-resolve catalog IDs to `Artist`s.
    private func fetchFavoriteArtists() async throws -> [Artist] {
        Log.v("[Favorites] === starting favorites fetch ===")
        let probes: [(label: String, path: String)] = [
            ("library inFavorites", "/v1/me/library/artists?limit=100&extend=inFavorites&include=catalog"),
            ("library inFavorites no-include", "/v1/me/library/artists?limit=100&extend=inFavorites"),
            ("favorites types=library-artists", "/v1/me/favorites?types=library-artists&limit=100&include=catalog"),
            ("favorites types=artists", "/v1/me/favorites?types=artists&limit=100"),
            ("library all artists (sanity)", "/v1/me/library/artists?limit=5"),
        ]

        for probe in probes {
            Log.v("[Favorites] >>> trying probe: \(probe.label) — \(probe.path)")
            do {
                let ids = try await collectFavoriteCatalogIDs(startPath: probe.path, label: probe.label)
                Log.v("[Favorites] <<< probe '\(probe.label)' returned \(ids.count) catalog IDs")
                if !ids.isEmpty {
                    return try await resolveCatalogArtists(catalogIDs: ids)
                }
            } catch {
                let ns = error as NSError
                Log.v("[Favorites] <<< probe '\(probe.label)' threw: \(error) [\(ns.domain) \(ns.code)] — full: \(String(reflecting: error))")
                // continue to next probe
            }
        }
        Log.v("[Favorites] no probe yielded favorited artists")
        return []
    }

    private func collectFavoriteCatalogIDs(startPath: String, label: String) async throws -> [String] {
        var catalogIDs: [String] = []
        var nextPath: String? = startPath
        var pageNum = 0

        // Apple strips query params (extend, include) from the `next` URLs it returns.
        // We have to splice them back on every page or only page 1 carries inFavorites
        // and the catalog relationship.
        let requiredQuery = startPath.split(separator: "?", maxSplits: 1).dropFirst().first.map(String.init) ?? ""

        while let path = nextPath {
            let pathWithQuery = mergedQuery(path: path, required: requiredQuery)
            guard let url = URL(string: "https://api.music.apple.com" + pathWithQuery) else { break }
            let dataRequest = MusicDataRequest(urlRequest: URLRequest(url: url))
            let dataResponse = try await dataRequest.response()
            pageNum += 1

            let httpStatus = dataResponse.urlResponse.statusCode
            let bodyPreview = String(data: dataResponse.data.prefix(2000), encoding: .utf8) ?? "<binary \(dataResponse.data.count) bytes>"
            Log.v("[Favorites] probe '\(label)' page \(pageNum): HTTP \(httpStatus), body=\(bodyPreview)")

            let page: FavoritesPage
            do {
                page = try JSONDecoder().decode(FavoritesPage.self, from: dataResponse.data)
            } catch {
                Log.v("[Favorites] probe '\(label)' page \(pageNum) DECODE FAILED: \(String(reflecting: error))")
                throw error
            }

            Log.v("[Favorites] probe '\(label)' page \(pageNum) decoded: items=\(page.data.count), next=\(page.next ?? "nil")")
            for (idx, item) in page.data.enumerated() {
                let inFav = item.attributes?.inFavorites
                let catRef = item.relationships?.catalog?.data.first?.id
                if idx < 3 {
                    Log.v("[Favorites]   item[\(idx)]: id=\(item.id), type=\(item.type), inFavorites=\(String(describing: inFav)), catalogRef=\(catRef ?? "nil")")
                }
                // For /favorites endpoints, presence in the response implies favorited.
                let isFavorited = item.attributes?.inFavorites ?? path.contains("/favorites")
                guard isFavorited else { continue }
                if let catalogID = catRef {
                    catalogIDs.append(catalogID)
                } else if item.type == "artists" {
                    catalogIDs.append(item.id)
                }
            }
            nextPath = page.next
        }
        return catalogIDs
    }

    /// Splice `required` query params into `path`, preferring values already present
    /// in `path` (so a `next` cursor like `offset=100` is preserved while `extend` /
    /// `include` get re-added).
    private func mergedQuery(path: String, required: String) -> String {
        guard !required.isEmpty else { return path }
        let parts = path.split(separator: "?", maxSplits: 1)
        let base = String(parts.first ?? Substring(path))
        let existing = parts.dropFirst().first.map(String.init) ?? ""

        func parse(_ q: String) -> [(String, String)] {
            q.split(separator: "&").compactMap { pair in
                let kv = pair.split(separator: "=", maxSplits: 1)
                guard let k = kv.first else { return nil }
                return (String(k), kv.dropFirst().first.map(String.init) ?? "")
            }
        }

        var merged: [(String, String)] = parse(existing)
        let existingKeys = Set(merged.map(\.0))
        for (k, v) in parse(required) where !existingKeys.contains(k) {
            merged.append((k, v))
        }
        let joined = merged.map { "\($0.0)=\($0.1)" }.joined(separator: "&")
        return joined.isEmpty ? base : "\(base)?\(joined)"
    }

    private func resolveCatalogArtists(catalogIDs: [String]) async throws -> [Artist] {
        Log.v("[Favorites] resolving \(catalogIDs.count) catalog IDs to Artist objects")
        var resolved: [Artist] = []
        for (idx, chunk) in catalogIDs.chunked(into: 25).enumerated() {
            do {
                let request = MusicCatalogResourceRequest<Artist>(
                    matching: \.id, memberOf: chunk.map { MusicItemID($0) }
                )
                let response = try await request.response()
                Log.v("[Favorites] resolve chunk \(idx): requested=\(chunk.count), got=\(response.items.count)")
                resolved.append(contentsOf: response.items)
            } catch {
                Log.v("[Favorites] resolve chunk \(idx) FAILED: \(String(reflecting: error)) — ids=\(chunk)")
            }
        }
        Log.v("[Favorites] resolution complete: \(resolved.count)/\(catalogIDs.count) artists")
        return resolved
    }
}

private struct FavoritesPage: Decodable {
    let data: [FavoritesItem]
    let next: String?
}

private struct FavoritesItem: Decodable {
    let id: String
    let type: String
    let attributes: FavoritesAttributes?
    let relationships: FavoritesRelationships?
}

private struct FavoritesAttributes: Decodable {
    let inFavorites: Bool?
}

private struct FavoritesRelationships: Decodable {
    let catalog: FavoritesCatalogRelationship?
}

private struct FavoritesCatalogRelationship: Decodable {
    let data: [FavoritesCatalogRef]
}

private struct FavoritesCatalogRef: Decodable {
    let id: String
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}

private struct ArtworkLookup: Sendable {
    let providerID: String
    let name: String
    let catalogArtistID: String?
}

private struct ArtworkResult: Sendable {
    let providerID: String
    let catalogID: String?
    let artworkURL: URL?
    let genres: [String]

    init(providerID: String, catalogID: String?, artworkURL: URL?, genres: [String] = []) {
        self.providerID = providerID
        self.catalogID = catalogID
        self.artworkURL = artworkURL
        self.genres = genres
    }
}

/// Top-level helper so it stays off any actor. Called from a detached task.
private func runArtworkLookups(_ lookups: [ArtworkLookup]) async -> [ArtworkResult] {
    await withTaskGroup(of: ArtworkResult.self) { group in
        let maxConcurrent = 4
        var nextIndex = 0
        var collected: [ArtworkResult] = []

        while nextIndex < min(maxConcurrent, lookups.count) {
            let lookup = lookups[nextIndex]
            nextIndex += 1
            group.addTask { await AppleMusicLibraryImportService.fetchArtwork(for: lookup) }
        }

        while let result = await group.next() {
            collected.append(result)
            if nextIndex < lookups.count {
                let lookup = lookups[nextIndex]
                nextIndex += 1
                group.addTask { await AppleMusicLibraryImportService.fetchArtwork(for: lookup) }
            }
        }
        return collected
    }
}

enum ArtistImportError: LocalizedError {
    case notAuthorized

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            "Apple Music access is needed to import your library artists."
        }
    }
}
