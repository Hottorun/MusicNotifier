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
    /// True when the fetch path detected an Apple rate-limit (HTTP 429) for
    /// this artist. The coordinator uses this signal to halve the concurrent
    /// fan-out (AIMD) so we don't keep slamming the API.
    var wasRateLimited: Bool = false
}

struct AppleMusicReleaseService {
    /// Hard cap per artist so a prolific catalogue can't blow the time budget.
    private let albumsPerArtist = 24
    /// REST primary is the safety-net "what did Apple drop recently" call.
    /// 12 newest entries is plenty for catching last-week singles without
    /// dragging years of back-catalog into every refresh.
    private let restPrimaryLimit = 12
    private let restPrimaryRecentDays = 60

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
    /// `storefront` is plumbed through from the coordinator so we don't re-resolve
    /// the country code on every single REST call (was 2× per artist before).
    func fetchOne(
        _ input: ArtistFetchInput,
        preResolvedArtist: Artist? = nil,
        storefront: String? = nil,
        // Incremental refresh window. When non-nil, the primary REST fetch
        // only returns albums released within the last `daysSinceLastRefresh
        // + 3` days (3-day buffer for late-arriving catalog updates). A
        // first-ever refresh passes nil and gets the full default window.
        daysSinceLastRefresh: Int? = nil
    ) async -> ArtistFetchOutcome {
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
            let resolvedStorefront: String
            if let storefront {
                resolvedStorefront = storefront
            } else {
                resolvedStorefront = (await currentStorefrontCountryCode()) ?? "us"
            }
            let catalogID = catalogArtist.id.rawValue
            let artistProviderID = input.providerID

            // Two release paths concurrently:
            // - primary:    REST sorted by releaseDate desc (was MusicKit
            //               `.with([.albums])` — now REST since it's faster
            //               and already date-sorted). The previous "restRecent"
            //               safety-net path is redundant under REST primary.
            // - appearsOn:  REST appears-on, last 180 days
            // Incremental window: clamp the primary fetch to the period since
            // last refresh + a small buffer. Nil = first refresh = full window.
            let primaryWindowDays: Int? = daysSinceLastRefresh.map { max(7, $0 + 3) }
            async let primaryResult = self.fetchPrimaryAlbumsResult(
                catalogArtist: catalogArtist,
                artistProviderID: artistProviderID,
                storefront: resolvedStorefront,
                onlyWithinDays: primaryWindowDays
            )
            async let appearsOnResult: Result<[FetchedRelease], Error> = {
                do {
                    let result = try await self.fetchAppearsOnAlbumsViaREST(
                        catalogArtistID: catalogID,
                        artistProviderID: artistProviderID,
                        storefront: resolvedStorefront,
                        onlyWithinDays: 180
                    )
                    return .success(result)
                } catch {
                    return .failure(error)
                }
            }()

            let primary = await primaryResult
            let appearsOn = await appearsOnResult
            let primaryReleases = (try? primary.get()) ?? []
            let appearsOnReleases = (try? appearsOn.get()) ?? []
            let combined = primaryReleases + appearsOnReleases
            let releases = dedupedVariants(combined)

            let rateLimited = (primary.rateLimited) || (appearsOn.rateLimited)
            return ArtistFetchOutcome(
                input: input,
                releases: releases,
                catalogArtistID: catalogID,
                artworkURL: artworkURL,
                errorMessage: nil,
                wasRateLimited: rateLimited
            )
        } catch {
            let nsError = error as NSError
            let detail = "\(error.localizedDescription) [\(nsError.domain) \(nsError.code)]"
            print("fetchOne failed for \(input.name): \(error) — full: \(String(reflecting: error))")
            return ArtistFetchOutcome(
                input: input, releases: [], catalogArtistID: nil,
                artworkURL: nil, errorMessage: detail,
                wasRateLimited: Self.looksLikeRateLimit(error)
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
        // Background + "Refetch all" callers both hit this entry. The old body
        // was a serial loop with a 150ms inter-artist sleep and used the slow
        // MusicKit `.with([.albums])` primary path — meaning the BG refresh
        // checked ~5 artists/min in the worst case and frequently blew its 30s
        // time budget. This now reuses the same parallel fan-out the
        // foreground RefreshCoordinator uses (fixed concurrency = 4 here, no
        // AIMD bookkeeping; the BG path's small batch size makes adaptive
        // overhead pointless).
        let storefrontCountryCode = await currentStorefrontCountryCode()
        let storefront = storefrontCountryCode ?? "us"

        // Pre-resolve cached catalog IDs in one batch call.
        let cachedIDs = artists.compactMap { $0.catalogArtistID }.filter { !$0.isEmpty }
        let preResolved = await preResolveCachedArtists(catalogIDs: cachedIDs)

        var releases: [FetchedRelease] = []
        var failures: [String] = []
        var resolvedCatalogIDs: [String: String] = [:]
        var resolvedArtworkURLs: [String: URL] = [:]
        var checkedArtists = 0

        let concurrent = min(4, artists.count)
        guard concurrent > 0 else {
            return ReleaseFetchResult(
                releases: [], failures: [], checkedArtists: 0,
                totalArtists: artists.count, resolvedCatalogIDs: [:],
                resolvedArtworkURLs: [:], storefrontCountryCode: storefrontCountryCode
            )
        }

        await withTaskGroup(of: ArtistFetchOutcome.self) { group in
            var nextIndex = 0

            func enqueue(_ index: Int) {
                let input = artists[index]
                let cached = input.catalogArtistID.flatMap { preResolved[$0] }
                group.addTask {
                    return await self.fetchOne(input, preResolvedArtist: cached, storefront: storefront)
                }
            }

            while nextIndex < concurrent {
                enqueue(nextIndex)
                nextIndex += 1
            }

            while let outcome = await group.next() {
                if Task.isCancelled { break }
                checkedArtists += 1
                releases.append(contentsOf: outcome.releases)
                if let catID = outcome.catalogArtistID {
                    resolvedCatalogIDs[outcome.input.providerID] = catID
                }
                if let art = outcome.artworkURL {
                    resolvedArtworkURLs[outcome.input.providerID] = art
                }
                if let err = outcome.errorMessage {
                    failures.append("\(outcome.input.name): \(err)")
                }
                progress?(checkedArtists, artists.count, outcome.input.name)

                if nextIndex < artists.count && !Task.isCancelled {
                    enqueue(nextIndex)
                    nextIndex += 1
                }
            }
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

    /// Per-fetch-path diagnostic. Hits MusicKit's `.albums`, REST primary
    /// sorted-by-date, and REST appears-on for a single artist and returns a
    /// human-readable report listing the most recent releases each path saw.
    /// Lets users tell us "yesterday's single shows up in path X but not Y"
    /// when something is missing from the feed.
    func diagnoseArtistFetch(for input: ArtistFetchInput) async -> String {
        var report = "Artist: \(input.name)\n"
        report += "providerID: \(input.providerID)\n"
        if let cached = input.catalogArtistID { report += "cached catalogArtistID: \(cached)\n" }
        let storefront = (await currentStorefrontCountryCode()) ?? "us"
        report += "storefront: \(storefront)\n\n"

        let catalogArtist: Artist?
        do {
            catalogArtist = try await resolveCatalogArtist(for: input)
        } catch {
            return report + "FAILED to resolve catalog artist: \(error)"
        }
        guard let catalogArtist else {
            return report + "No catalog artist match for \"\(input.name)\""
        }
        report += "resolved: \(catalogArtist.name) [\(catalogArtist.id.rawValue)]\n\n"

        // Path 1: MusicKit .albums relationship
        report += "─ MusicKit .albums ─\n"
        do {
            let detailed = try await catalogArtist.with([.albums])
            let albums = detailed.albums.map(Array.init) ?? []
            report += "count: \(albums.count)\n"
            for a in albums.prefix(15) {
                let date = a.releaseDate?.formatted(date: .abbreviated, time: .omitted) ?? "no-date"
                report += "  • [\(date)] \(a.title)\n"
            }
        } catch {
            report += "ERROR: \(error)\n"
        }

        // Path 2: REST primary, sorted by date desc
        report += "\n─ REST primary (sort=-releaseDate) ─\n"
        do {
            let rest = try await fetchAlbumsViaREST(catalogArtistID: catalogArtist.id.rawValue, artistProviderID: input.providerID)
            report += "count: \(rest.count)\n"
            for r in rest.prefix(15) {
                let date = r.releaseDate?.formatted(date: .abbreviated, time: .omitted) ?? "no-date"
                report += "  • [\(date)] \(r.title)\n"
            }
        } catch {
            report += "ERROR: \(error)\n"
        }

        // Path 3: REST appears-on
        report += "\n─ REST appears-on (≤180d) ─\n"
        do {
            let app = try await fetchAppearsOnAlbumsViaREST(
                catalogArtistID: catalogArtist.id.rawValue,
                artistProviderID: input.providerID,
                storefront: storefront,
                onlyWithinDays: 180
            )
            report += "count: \(app.count)\n"
            for r in app.prefix(15) {
                let date = r.releaseDate?.formatted(date: .abbreviated, time: .omitted) ?? "no-date"
                report += "  • [\(date)] \(r.title) — \(r.artistName)\n"
            }
        } catch {
            report += "ERROR: \(error)\n"
        }

        return report
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
            // Skip promotional / placeholder catalog rows MusicKit occasionally
            // hands back with an empty id — they trigger the noisy
            // "No catalogID, libraryID, or deviceLocalID was found from
            // underlying identifier set <MPIdentifierSet EMPTY>" log line
            // and never resolve to a real album anyway.
            let rawID = album.id.rawValue
            guard !rawID.isEmpty else { return nil }

            let releaseDate = album.releaseDate
            if let releaseDate {
                let daysFromRelease = Calendar.current.dateComponents([.day], from: releaseDate, to: Date()).day ?? 0
                if releaseDate < Date() && daysFromRelease > 365 { return nil }
            }

            return FetchedRelease(
                providerID: rawID,
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

    /// Primary path: REST `sort=-releaseDate` returns newest-first reliably
    /// and is significantly faster than MusicKit's `.with([.albums])` (which
    /// makes a nested subrequest per album for relationship hydration).
    /// MusicKit is kept only as a fallback for the rare case where REST comes
    /// back empty (artist with locked-down storefront, etc.).
    ///
    /// `Result` variant preserves the throwing error so the coordinator can
    /// see rate-limit signals from this path; legacy callers use the
    /// non-throwing wrapper below.
    private func fetchPrimaryAlbumsResult(
        catalogArtist: Artist,
        artistProviderID: String,
        storefront: String,
        onlyWithinDays: Int? = nil
    ) async -> Result<[FetchedRelease], Error> {
        do {
            let rest = try await fetchAlbumsViaREST(
                catalogArtistID: catalogArtist.id.rawValue,
                artistProviderID: artistProviderID,
                storefront: storefront,
                limit: albumsPerArtist,
                onlyWithinDays: onlyWithinDays
            )
            if !rest.isEmpty { return .success(rest) }
        } catch {
            // Rate-limit (or any REST error) → fall through to MusicKit fallback,
            // but propagate the error if MusicKit also fails so coordinator sees signal.
            do {
                let detailed = try await withRetry({ try await catalogArtist.with([.albums]) })
                let allAlbums: [Album] = detailed.albums.map(Array.init) ?? []
                return .success(mapAlbums(Array(allAlbums.prefix(albumsPerArtist)), artistProviderID: artistProviderID))
            } catch {
                return .failure(error)
            }
        }
        // REST returned 0 — fall back to MusicKit relationship load.
        do {
            let detailed = try await withRetry({ try await catalogArtist.with([.albums]) })
            let allAlbums: [Album] = detailed.albums.map(Array.init) ?? []
            return .success(mapAlbums(Array(allAlbums.prefix(albumsPerArtist)), artistProviderID: artistProviderID))
        } catch {
            return .failure(error)
        }
    }

    private func fetchPrimaryAlbums(
        catalogArtist: Artist,
        artistProviderID: String,
        storefront: String
    ) async -> [FetchedRelease] {
        (try? await fetchPrimaryAlbumsResult(
            catalogArtist: catalogArtist,
            artistProviderID: artistProviderID,
            storefront: storefront
        ).get()) ?? []
    }

    /// REST fallback when MusicKit's `.with([.albums])` decode blows up on a bad
    /// item in the array. Decodes albums one-by-one; bad items are skipped so we
    /// still return everything that *did* decode for this artist.
    /// `sort=-releaseDate` is critical: MusicKit's relationship returns the
    /// artist's catalog in an unspecified order, which is why brand-new singles
    /// were silently falling outside the `albumsPerArtist` window for prolific
    /// artists. Sorting newest-first guarantees yesterday's drop is page 1.
    private func fetchAlbumsViaREST(
        catalogArtistID: String,
        artistProviderID: String,
        storefront: String? = nil,
        limit: Int? = nil,
        onlyWithinDays: Int? = nil
    ) async throws -> [FetchedRelease] {
        let resolvedStorefront: String
        if let storefront {
            resolvedStorefront = storefront
        } else {
            resolvedStorefront = (await currentStorefrontCountryCode()) ?? "us"
        }
        let storefront = resolvedStorefront
        let pageLimit = limit ?? albumsPerArtist
        let path = "/v1/catalog/\(storefront)/artists/\(catalogArtistID)/albums?limit=\(pageLimit)&sort=-releaseDate"
        guard let url = URL(string: "https://api.music.apple.com" + path) else { return [] }
        let dataRequest = MusicDataRequest(urlRequest: URLRequest(url: url))
        let response = try await dataRequest.response()
        if response.urlResponse.statusCode == 429 {
            throw AppleAPIError.rateLimited
        }
        let page = try sharedRESTDecoder.decode(RESTAlbumPage.self, from: response.data)

        // Recent-only cutoff for the always-on REST primary path. Past
        // releases older than `onlyWithinDays` are dropped so a refresh
        // doesn't keep dragging the entire back catalog into the feed.
        // Future-dated rows pass regardless (so upcoming drops still surface).
        let recentCutoff = onlyWithinDays.flatMap {
            Calendar.current.date(byAdding: .day, value: -$0, to: Date())
        }

        return page.data.compactMap { item -> FetchedRelease? in
            guard let attrs = item.attributes, let title = attrs.name else { return nil }
            let releaseDate = attrs.parsedReleaseDate
            if let releaseDate {
                let daysFromRelease = Calendar.current.dateComponents([.day], from: releaseDate, to: Date()).day ?? 0
                if releaseDate < Date() && daysFromRelease > 365 { return nil }
                if let cutoff = recentCutoff, releaseDate < cutoff { return nil }
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
                type: releaseKind(forREST: attrs).rawValue
            )
        }
    }

    /// Albums on which this artist appears as a feature/secondary credit.
    /// MusicKit's `Artist.albums` only returns primary-credit albums; feature
    /// spots (which are often the *new* drops users want to hear about) need
    /// the catalog `view/appears-on-albums` endpoint. Filters to recent
    /// releases so we don't import the artist's entire historical feature
    /// catalog on every refresh.
    private func fetchAppearsOnAlbumsViaREST(
        catalogArtistID: String,
        artistProviderID: String,
        storefront: String,
        onlyWithinDays: Int
    ) async throws -> [FetchedRelease] {
        let path = "/v1/catalog/\(storefront)/artists/\(catalogArtistID)/view/appears-on-albums?limit=\(albumsPerArtist)"
        guard let url = URL(string: "https://api.music.apple.com" + path) else { return [] }
        let dataRequest = MusicDataRequest(urlRequest: URLRequest(url: url))
        let response = try await dataRequest.response()
        if response.urlResponse.statusCode == 429 {
            throw AppleAPIError.rateLimited
        }
        let page = try sharedRESTDecoder.decode(RESTAlbumPage.self, from: response.data)

        let cutoff = Calendar.current.date(byAdding: .day, value: -onlyWithinDays, to: Date())

        return page.data.compactMap { item -> FetchedRelease? in
            guard let attrs = item.attributes, let title = attrs.name else { return nil }
            let releaseDate = attrs.parsedReleaseDate
            // Drop anything older than the cutoff (only need recent features).
            // Future-dated feature spots are kept regardless.
            if let releaseDate, let cutoff, releaseDate < cutoff { return nil }
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
                type: releaseKind(forREST: attrs).rawValue
            )
        }
    }

    /// Public so the refresh coordinator can resolve once per refresh and
    /// pass the result into `fetchOne`, avoiding 2× per-artist re-resolution.
    func resolveStorefrontCountryCode() async -> String {
        (await currentStorefrontCountryCode()) ?? "us"
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

    /// Same classification rules as `releaseKind(for: Album)`, but driven by
    /// what Apple's REST endpoint hands back. Hardcoding `.album` here was
    /// the reason every REST-fetched release showed up tagged ALBUM in the
    /// feed, even for singles.
    private func releaseKind(forREST attrs: RESTAlbumAttributes) -> ReleaseKind {
        let title = (attrs.name ?? "").lowercased()
        if attrs.isCompilation == true { return .compilation }
        if title.contains("remix") || title.contains("remixes") { return .remix }
        if title.contains("live") { return .liveAlbum }
        if attrs.isSingle == true { return .single }
        if let track = attrs.trackCount, track > 1, track <= 6 { return .ep }
        if title.contains(" ep") || title.hasSuffix("ep") { return .ep }
        return .album
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

                // Only back off hard for confirmed rate-limit signals. The old
                // path string-matched decode-failure-on-non-JSON, which made a
                // single malformed Apple response stall the artist for 40+s.
                // Now we trust `AppleAPIError.rateLimited` (set when the REST
                // helper sees an HTTP 429), and fall back to the historical
                // text markers only as a safety net for the MusicKit-typed
                // throw paths we can't inspect status on.
                let isRateLimited = Self.looksLikeRateLimit(error)
                let baseMs: UInt64 = isRateLimited ? 1500 : 250
                let delayMs = baseMs * UInt64(1 << attempt) // exponential: 1.5s,3s,6s,12s,24s
                try? await Task.sleep(nanoseconds: delayMs * 1_000_000)
            }
        }

        throw lastError ?? CancellationError()
    }

    private static func looksLikeRateLimit(_ error: Error) -> Bool {
        if case AppleAPIError.rateLimited = error { return true }
        // Conservative text fallback for MusicKit-thrown errors where we
        // don't have a typed status code. Decode-failure markers ("Unexpected
        // character 'A'") were dropped — they fired on every malformed body
        // regardless of cause.
        let description = String(reflecting: error)
        return description.contains("API capacity exceeded")
            || description.contains(" 429 ")
            || description.contains("statusCode = 429")
    }
}

enum AppleAPIError: Error {
    case rateLimited
}

private extension Result {
    /// True when the failure is an Apple 429 (or a recognized text marker for one).
    /// Used by the coordinator to drive AIMD concurrency adjustment.
    var rateLimited: Bool {
        if case .failure(let err) = self {
            if let apiErr = err as? AppleAPIError, case .rateLimited = apiErr { return true }
            let description = String(reflecting: err)
            return description.contains("API capacity exceeded")
                || description.contains("statusCode = 429")
        }
        return false
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
    // Decode the type signals Apple gives us so the REST path can classify
    // singles / EPs / compilations / remixes / live the same way MusicKit's
    // `Album` type does. Without these the REST fetch was hardcoding
    // `ReleaseKind.album` and every new row got an ALBUM tag regardless.
    let isSingle: Bool?
    let isCompilation: Bool?
    let trackCount: Int?

    // Shared formatters — allocating two DateFormatters per album decoded
    // (12 albums × N artists) was a measurable allocation hotspot during
    // refresh. Static instances are thread-safe for read-only parsing.
    private static let isoFullFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }()
    private static let yearOnlyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }()

    var parsedReleaseDate: Date? {
        guard let releaseDate else { return nil }
        if let date = Self.isoFullFormatter.date(from: releaseDate) { return date }
        return Self.yearOnlyFormatter.date(from: releaseDate)
    }
}

/// Shared JSON decoder — `JSONDecoder()` is allocated fresh on every REST
/// response otherwise. Stateless for our decode shape.
private let sharedRESTDecoder = JSONDecoder()

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
