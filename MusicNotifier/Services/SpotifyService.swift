//
//  SpotifyService.swift
//  MusicNotifier
//

import AuthenticationServices
import CryptoKit
import Foundation
import SwiftData
import UIKit

enum SpotifyServiceError: LocalizedError {
    case missingClientID
    case missingRedirectURI
    case authenticationCancelled
    case authenticationFailed
    case missingAccessToken
    case invalidResponse
    case httpStatus(code: Int, body: String)

    var errorDescription: String? {
        switch self {
        case .missingClientID:
            "Spotify is not configured for this build."
        case .missingRedirectURI:
            "Spotify redirect URI is not configured for this build."
        case .authenticationCancelled:
            "Spotify sign-in was cancelled."
        case .authenticationFailed:
            "Spotify sign-in failed."
        case .missingAccessToken:
            "Connect Spotify first."
        case .invalidResponse:
            "Spotify returned an unexpected response."
        case .httpStatus(let code, let body):
            "Spotify error \(code): \(body.prefix(200))"
        }
    }
}

struct SpotifyService {
    private let defaults: UserDefaults
    private let apiBaseURL = URL(string: "https://api.spotify.com/v1")!
    private let accountsBaseURL = URL(string: "https://accounts.spotify.com")!

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isConfigured: Bool {
        !clientID.isEmpty && !redirectURIString.isEmpty
    }

    var isConnected: Bool {
        !(defaults.string(forKey: AppSettings.spotifyRefreshToken) ?? "").isEmpty
            || !(defaults.string(forKey: AppSettings.spotifyAccessToken) ?? "").isEmpty
    }

    var clientID: String {
        let stored = defaults.string(forKey: AppSettings.spotifyClientID)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return stored.isEmpty ? AppSettings.defaultSpotifyClientID : stored
    }

    var redirectURIString: String {
        let stored = defaults.string(forKey: AppSettings.spotifyRedirectURI)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return stored.isEmpty ? AppSettings.defaultSpotifyRedirectURI : stored
    }

    @MainActor
    func authenticate() async throws {
        guard !clientID.isEmpty else { throw SpotifyServiceError.missingClientID }
        guard let redirectURI = URL(string: redirectURIString), !redirectURIString.isEmpty else {
            throw SpotifyServiceError.missingRedirectURI
        }

        let verifier = Self.makeCodeVerifier()
        let challenge = Self.codeChallenge(for: verifier)
        let state = UUID().uuidString

        var components = URLComponents(url: accountsBaseURL.appending(path: "authorize"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "scope", value: "user-follow-read"),
            URLQueryItem(name: "redirect_uri", value: redirectURIString),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: challenge)
        ]

        guard let authURL = components?.url else { throw SpotifyServiceError.authenticationFailed }
        let callbackURL = try await WebAuthenticationBroker.shared.authenticate(
            url: authURL,
            callbackScheme: redirectURI.scheme ?? "musicnotifier"
        )

        guard let callbackComponents = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
              callbackComponents.queryItems?.first(where: { $0.name == "state" })?.value == state,
              let code = callbackComponents.queryItems?.first(where: { $0.name == "code" })?.value else {
            throw SpotifyServiceError.authenticationFailed
        }

        let token = try await requestToken(
            body: [
                "client_id": clientID,
                "grant_type": "authorization_code",
                "code": code,
                "redirect_uri": redirectURI.absoluteString,
                "code_verifier": verifier
            ]
        )
        store(token: token)
    }

    func importFollowedArtists(into modelContext: ModelContext) async throws -> Int {
        let artists = try await followedArtists()

        for artist in artists {
            let scopedID = MusicProvider.spotify.scopedID(artist.id)
            let descriptor = FetchDescriptor<ArtistData>(
                predicate: #Predicate { storedArtist in
                    storedArtist.providerID == scopedID
                }
            )

            if let existing = try modelContext.fetch(descriptor).first {
                existing.name = artist.name
                existing.artworkURL = artist.bestImageURL
                existing.provider = MusicProvider.spotify.rawValue
            } else {
                modelContext.insert(
                    ArtistData(
                        providerID: scopedID,
                        name: artist.name,
                        artworkURL: artist.bestImageURL,
                        isTracked: false,
                        provider: MusicProvider.spotify.rawValue
                    )
                )
            }
        }

        try modelContext.save()
        return artists.count
    }

    func searchArtists(term: String) async throws -> [ProviderArtistSearchResult] {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let response: SpotifySearchResponse = try await apiRequest(
            path: "search",
            queryItems: [
                URLQueryItem(name: "q", value: trimmed),
                URLQueryItem(name: "type", value: "artist"),
                URLQueryItem(name: "limit", value: "15")
            ]
        )

        return response.artists.items.map {
            ProviderArtistSearchResult(
                id: MusicProvider.spotify.scopedID($0.id),
                provider: .spotify,
                name: $0.name,
                artworkURL: $0.bestImageURL
            )
        }
    }

    @MainActor
    func importArtist(_ artist: ProviderArtistSearchResult, into modelContext: ModelContext, tracked: Bool = true) throws {
        let providerID = artist.id
        let descriptor = FetchDescriptor<ArtistData>(
            predicate: #Predicate { storedArtist in
                storedArtist.providerID == providerID
            }
        )

        if let existing = try modelContext.fetch(descriptor).first {
            existing.name = artist.name
            existing.artworkURL = artist.artworkURL
            existing.provider = artist.provider.rawValue
            existing.isTracked = tracked || existing.isTracked
        } else {
            modelContext.insert(
                ArtistData(
                    providerID: artist.id,
                    name: artist.name,
                    artworkURL: artist.artworkURL,
                    isTracked: tracked,
                    provider: artist.provider.rawValue
                )
            )
        }

        try modelContext.save()
    }

    func fetchOne(_ input: ArtistFetchInput) async -> ArtistFetchOutcome {
        do {
            let rawArtistID = MusicProvider.spotify.rawID(from: input.providerID)
            let response: SpotifyAlbumsResponse = try await apiRequest(
                path: "artists/\(rawArtistID)/albums",
                queryItems: [
                    URLQueryItem(name: "include_groups", value: "album,single,compilation"),
                    URLQueryItem(name: "market", value: Locale.current.region?.identifier ?? "US"),
                    URLQueryItem(name: "limit", value: "50")
                ]
            )

            let mapped = response.items.compactMap { album -> FetchedRelease? in
                let releaseDate = Self.parseReleaseDate(album.releaseDate, precision: album.releaseDatePrecision)
                if let releaseDate {
                    let daysFromRelease = Calendar.current.dateComponents([.day], from: releaseDate, to: Date()).day ?? 0
                    if releaseDate < Date() && daysFromRelease > 365 { return nil }
                }

                return FetchedRelease(
                    providerID: MusicProvider.spotify.scopedID(album.id),
                    artistProviderID: input.providerID,
                    artistName: album.artists.first?.name ?? input.name,
                    title: album.name,
                    releaseDate: releaseDate,
                    artworkURL: album.bestImageURL,
                    albumURL: album.externalURLs.spotify.flatMap(URL.init(string:)),
                    provider: MusicProvider.spotify.rawValue,
                    type: Self.releaseKind(for: album).rawValue
                )
            }

            return ArtistFetchOutcome(
                input: input,
                releases: dedupedVariants(mapped),
                catalogArtistID: nil,
                artworkURL: nil,
                errorMessage: nil
            )
        } catch {
            return ArtistFetchOutcome(
                input: input,
                releases: [],
                catalogArtistID: nil,
                artworkURL: nil,
                errorMessage: error.localizedDescription
            )
        }
    }

    func accessToken() async throws -> String {
        let now = Date().timeIntervalSince1970
        if let token = defaults.string(forKey: AppSettings.spotifyAccessToken),
           now < defaults.double(forKey: AppSettings.spotifyTokenExpiresAt) - 60 {
            return token
        }

        guard let refreshToken = defaults.string(forKey: AppSettings.spotifyRefreshToken), !refreshToken.isEmpty else {
            throw SpotifyServiceError.missingAccessToken
        }

        guard !clientID.isEmpty else { throw SpotifyServiceError.missingClientID }

        let token = try await requestToken(
            body: [
                "client_id": clientID,
                "grant_type": "refresh_token",
                "refresh_token": refreshToken
            ]
        )
        store(token: token)

        guard let accessToken = token.accessToken ?? defaults.string(forKey: AppSettings.spotifyAccessToken) else {
            throw SpotifyServiceError.missingAccessToken
        }
        return accessToken
    }

    private func followedArtists() async throws -> [SpotifyArtist] {
        var collected: [SpotifyArtist] = []
        var after: String?

        repeat {
            var queryItems = [
                URLQueryItem(name: "type", value: "artist"),
                URLQueryItem(name: "limit", value: "50")
            ]
            if let after {
                queryItems.append(URLQueryItem(name: "after", value: after))
            }

            let response: SpotifyFollowedArtistsResponse = try await apiRequest(
                path: "me/following",
                queryItems: queryItems
            )
            collected.append(contentsOf: response.artists.items)
            after = response.artists.cursors.after
        } while after != nil

        return collected
    }

    private func apiRequest<T: Decodable>(path: String, queryItems: [URLQueryItem] = []) async throws -> T {
        try await apiRequest(path: path, queryItems: queryItems, attempt: 0)
    }

    private func apiRequest<T: Decodable>(path: String, queryItems: [URLQueryItem], attempt: Int) async throws -> T {
        let token = try await accessToken()
        var components = URLComponents(url: apiBaseURL.appending(path: path), resolvingAgainstBaseURL: false)
        components?.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components?.url else { throw SpotifyServiceError.invalidResponse }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SpotifyServiceError.invalidResponse
        }

        if (200..<300).contains(http.statusCode) {
            return try JSONDecoder.spotify.decode(T.self, from: data)
        }

        let bodyPreview = String(data: data.prefix(500), encoding: .utf8) ?? "<binary>"
        print("[Spotify] \(path) → HTTP \(http.statusCode), body=\(bodyPreview)")

        // 401 → token expired/invalid. Drop the cached token so accessToken() forces a refresh,
        // then retry once. After the retry, give up so we don't loop.
        if http.statusCode == 401, attempt == 0 {
            defaults.removeObject(forKey: AppSettings.spotifyAccessToken)
            defaults.set(0.0, forKey: AppSettings.spotifyTokenExpiresAt)
            return try await apiRequest(path: path, queryItems: queryItems, attempt: 1)
        }

        throw SpotifyServiceError.httpStatus(code: http.statusCode, body: bodyPreview)
    }

    private func requestToken(body: [String: String]) async throws -> SpotifyTokenResponse {
        var request = URLRequest(url: accountsBaseURL.appending(path: "api/token"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
            .map { key, value in
                "\(Self.formEncode(key))=\(Self.formEncode(value))"
            }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SpotifyServiceError.authenticationFailed
        }
        return try JSONDecoder.spotify.decode(SpotifyTokenResponse.self, from: data)
    }

    private func store(token: SpotifyTokenResponse) {
        if let accessToken = token.accessToken {
            defaults.set(accessToken, forKey: AppSettings.spotifyAccessToken)
        }
        if let refreshToken = token.refreshToken {
            defaults.set(refreshToken, forKey: AppSettings.spotifyRefreshToken)
        }
        if let expiresIn = token.expiresIn {
            defaults.set(Date().timeIntervalSince1970 + Double(expiresIn), forKey: AppSettings.spotifyTokenExpiresAt)
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

    private static func releaseKind(for album: SpotifyAlbum) -> ReleaseKind {
        switch album.albumType {
        case "single":
            return .single
        case "compilation":
            return .compilation
        default:
            if album.name.localizedCaseInsensitiveContains(" ep") || album.name.localizedCaseInsensitiveContains("- ep") {
                return .ep
            }
            return .album
        }
    }

    private static func parseReleaseDate(_ value: String, precision: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)

        switch precision {
        case "day":
            formatter.dateFormat = "yyyy-MM-dd"
        case "month":
            formatter.dateFormat = "yyyy-MM"
        case "year":
            formatter.dateFormat = "yyyy"
        default:
            formatter.dateFormat = "yyyy-MM-dd"
        }

        return formatter.date(from: value)
    }

    private static func makeCodeVerifier() -> String {
        let characters = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        var bytes = [UInt8](repeating: 0, count: 64)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return String(bytes.map { characters[Int($0) % characters.count] })
    }

    private static func codeChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64URLEncodedString()
    }

    private static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

private final class WebAuthenticationBroker: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = WebAuthenticationBroker()

    private var continuation: CheckedContinuation<URL, Error>?

    @MainActor
    func authenticate(url: URL, callbackScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { callbackURL, error in
                if let callbackURL {
                    continuation.resume(returning: callbackURL)
                } else if let error = error as? ASWebAuthenticationSessionError,
                          error.code == .canceledLogin {
                    continuation.resume(throwing: SpotifyServiceError.authenticationCancelled)
                } else {
                    continuation.resume(throwing: error ?? SpotifyServiceError.authenticationFailed)
                }
                self.continuation = nil
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            if !session.start() {
                continuation.resume(throwing: SpotifyServiceError.authenticationFailed)
                self.continuation = nil
            }
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow } ?? ASPresentationAnchor()
    }
}

private struct SpotifyTokenResponse: Decodable {
    let accessToken: String?
    let tokenType: String?
    let scope: String?
    let expiresIn: Int?
    let refreshToken: String?
}

private struct SpotifyImage: Decodable {
    let url: String
}

private struct SpotifyExternalURLs: Decodable {
    let spotify: String?
}

private struct SpotifyArtist: Decodable {
    let id: String
    let name: String
    let images: [SpotifyImage]?

    var bestImageURL: URL? {
        images?.first.flatMap { URL(string: $0.url) }
    }
}

private struct SpotifyAlbumArtist: Decodable {
    let name: String
}

private struct SpotifyAlbum: Decodable {
    let id: String
    let name: String
    let albumType: String
    let releaseDate: String
    let releaseDatePrecision: String
    let images: [SpotifyImage]?
    let externalURLs: SpotifyExternalURLs
    let artists: [SpotifyAlbumArtist]

    var bestImageURL: URL? {
        images?.first.flatMap { URL(string: $0.url) }
    }
}

private struct SpotifySearchResponse: Decodable {
    let artists: SpotifyArtistPage
}

private struct SpotifyFollowedArtistsResponse: Decodable {
    let artists: SpotifyArtistCursorPage
}

private struct SpotifyAlbumsResponse: Decodable {
    let items: [SpotifyAlbum]
}

private struct SpotifyArtistPage: Decodable {
    let items: [SpotifyArtist]
}

private struct SpotifyArtistCursorPage: Decodable {
    let items: [SpotifyArtist]
    let cursors: SpotifyCursor
}

private struct SpotifyCursor: Decodable {
    let after: String?
}

private extension JSONDecoder {
    static var spotify: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
