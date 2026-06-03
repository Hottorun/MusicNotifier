//
//  BandsintownService.swift
//  MusicNotifier
//
//  Bandsintown REST API client. No auth — just send app_id with each request.
//  Endpoint: https://rest.bandsintown.com/artists/{name}/events?app_id=...&date=...
//

import Foundation

struct FetchedConcert: Sendable {
    let providerID: String
    let artistProviderID: String
    let artistName: String
    let venueName: String
    let city: String
    let region: String?
    let country: String
    let latitude: Double?
    let longitude: Double?
    let date: Date?
    let ticketURL: URL?
    let lineup: [String]
}

struct BandsintownService {
    /// Public app id sent with every request — not a secret, just attribution.
    private let appID = "MusicNotifier"

    /// How far back we accept past events. Anything older is filtered server-side
    /// via the `date=YYYY-MM-DD,YYYY-MM-DD` range param.
    private let pastDaysWindow = 30

    /// Hard cap per artist so a stadium act doesn't dump 200 shows into the feed.
    private let eventsPerArtist = 60

    /// Fan-out fetch — one request per tracked artist, capped concurrency.
    func fetchConcerts(for inputs: [ArtistFetchInput]) async -> [FetchedConcert] {
        guard !inputs.isEmpty else { return [] }
        var collected: [FetchedConcert] = []
        var seenIDs: Set<String> = []

        await withTaskGroup(of: [FetchedConcert].self) { group in
            let maxConcurrent = 3
            var nextIndex = 0

            func enqueue(_ i: Int) {
                let input = inputs[i]
                group.addTask {
                    await self.fetchOne(input)
                }
            }

            while nextIndex < min(maxConcurrent, inputs.count) {
                enqueue(nextIndex)
                nextIndex += 1
            }

            while let batch = await group.next() {
                if Task.isCancelled { break }
                for c in batch where !seenIDs.contains(c.providerID) {
                    seenIDs.insert(c.providerID)
                    collected.append(c)
                }
                if nextIndex < inputs.count && !Task.isCancelled {
                    enqueue(nextIndex)
                    nextIndex += 1
                }
            }
        }

        return collected
    }

    private func fetchOne(_ input: ArtistFetchInput) async -> [FetchedConcert] {
        guard !input.name.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        do {
            // Bandsintown documents specific double-escaping for `/ ? *` in the
            // artist path segment (e.g. AC/DC → AC%252FDC). Do that substitution
            // FIRST, then percent-encode the rest of the string normally.
            let preEscaped = input.name
                .replacingOccurrences(of: "/", with: "%252F")
                .replacingOccurrences(of: "?", with: "%253F")
                .replacingOccurrences(of: "*", with: "%252A")
                .replacingOccurrences(of: "\"", with: "%2522")
            guard let encoded = preEscaped.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
                return []
            }
            let start = ISO8601DateFormatter.dateOnly.string(from: Date().addingTimeInterval(-Double(pastDaysWindow) * 86_400))
            let end = "2099-12-31"
            let urlString = "https://rest.bandsintown.com/artists/\(encoded)/events?app_id=\(appID)&date=\(start)%2C\(end)"
            guard let url = URL(string: urlString) else { return [] }

            var request = URLRequest(url: url)
            request.timeoutInterval = 10
            request.addValue("application/json", forHTTPHeaderField: "Accept")

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                Log.v("[Bandsintown] non-2xx for \(input.name): \(response)")
                return []
            }

            let events = try JSONDecoder.bandsintown.decode([BandsintownEvent].self, from: data)
            return events.prefix(eventsPerArtist).map { event in
                FetchedConcert(
                    providerID: event.id,
                    artistProviderID: input.providerID,
                    artistName: input.name,
                    venueName: event.venue.name ?? "",
                    city: event.venue.city ?? "",
                    region: event.venue.region,
                    country: event.venue.country ?? "",
                    latitude: event.venue.latitude.flatMap(Double.init),
                    longitude: event.venue.longitude.flatMap(Double.init),
                    date: parseDatetime(event.datetime),
                    ticketURL: event.offers?.compactMap({ URL(string: $0.url ?? "") }).first,
                    lineup: event.lineup ?? []
                )
            }
        } catch {
            Log.v("[Bandsintown] fetch failed for \(input.name): \(error)")
            return []
        }
    }

    /// Bandsintown sends naive local datetime ("2025-12-15T20:00:00"). Treat as
    /// UTC for storage — close enough for "what month/day is this on" display.
    private func parseDatetime(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        return ISO8601DateFormatter.naive.date(from: s + "Z") ?? ISO8601DateFormatter.naive.date(from: s)
    }
}

// MARK: - Decoding shapes

private struct BandsintownEvent: Decodable {
    let id: String
    let datetime: String?
    let venue: BandsintownVenue
    let offers: [BandsintownOffer]?
    let lineup: [String]?
}

private struct BandsintownVenue: Decodable {
    let name: String?
    let city: String?
    let region: String?
    let country: String?
    let latitude: String?
    let longitude: String?
}

private struct BandsintownOffer: Decodable {
    let type: String?
    let url: String?
    let status: String?
}

private extension ISO8601DateFormatter {
    static let dateOnly: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        return f
    }()

    /// Bandsintown timestamps like "2025-12-15T20:00:00" — no timezone suffix.
    static let naive: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}

private extension JSONDecoder {
    static let bandsintown: JSONDecoder = {
        let d = JSONDecoder()
        return d
    }()
}
