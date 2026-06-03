//
//  ConcertRefreshService.swift
//  MusicNotifier
//

import Foundation
import SwiftData
import UserNotifications
import CoreLocation

struct ConcertRefreshSummary {
    let newConcertCount: Int
}

@MainActor
struct ConcertRefreshService {
    func refresh(
        trackedArtists: [ArtistData],
        modelContext: ModelContext
    ) async -> ConcertRefreshSummary {
        let inputs = trackedArtists.map {
            ArtistFetchInput(
                providerID: $0.providerID,
                name: $0.name,
                provider: $0.provider,
                catalogArtistID: $0.catalogArtistID
            )
        }

        let fetched = await BandsintownService().fetchConcerts(for: inputs)
        guard !fetched.isEmpty else { return ConcertRefreshSummary(newConcertCount: 0) }

        let existing = (try? modelContext.fetch(FetchDescriptor<ConcertData>())) ?? []
        var existingByID = Dictionary(uniqueKeysWithValues: existing.map { ($0.providerID, $0) })

        var newConcerts: [ConcertData] = []
        let now = Date()

        for concert in fetched {
            if let row = existingByID[concert.providerID] {
                row.artistName = concert.artistName
                row.venueName = concert.venueName
                row.city = concert.city
                row.region = concert.region
                row.country = concert.country
                row.latitude = concert.latitude
                row.longitude = concert.longitude
                row.date = concert.date
                row.ticketURL = concert.ticketURL
                row.lineup = concert.lineup
                row.lastUpdatedAt = now
            } else {
                let row = ConcertData(
                    providerID: concert.providerID,
                    artistProviderID: concert.artistProviderID,
                    artistName: concert.artistName,
                    venueName: concert.venueName,
                    city: concert.city,
                    region: concert.region,
                    country: concert.country,
                    latitude: concert.latitude,
                    longitude: concert.longitude,
                    date: concert.date,
                    ticketURL: concert.ticketURL,
                    lineup: concert.lineup
                )
                modelContext.insert(row)
                existingByID[row.providerID] = row
                newConcerts.append(row)
            }
        }

        try? modelContext.save()

        let defaults = UserDefaults.standard
        let concertsEnabled = defaults.object(forKey: AppSettings.enableConcertsTab) as? Bool ?? false
        let notificationsEnabled = defaults.object(forKey: AppSettings.notificationsEnabled) as? Bool ?? true
        let concertNotificationsEnabled = defaults.object(forKey: AppSettings.concertNotificationsEnabled) as? Bool ?? false

        if concertsEnabled && notificationsEnabled && concertNotificationsEnabled {
            await scheduleNotifications(for: newConcerts)
            try? modelContext.save()
        }

        return ConcertRefreshSummary(newConcertCount: newConcerts.count)
    }

    /// One notification per newly-discovered concert whose venue lies within
    /// the user's `nearbyRadiusKm`. Concerts without coordinates are skipped —
    /// the radius filter can't classify them.
    private func scheduleNotifications(for concerts: [ConcertData]) async {
        let defaults = UserDefaults.standard
        let radiusKm = defaults.object(forKey: AppSettings.nearbyRadiusKm) as? Double ?? 50.0
        let userLat = defaults.double(forKey: AppSettings.cachedLatitude)
        let userLon = defaults.double(forKey: AppSettings.cachedLongitude)
        guard userLat != 0 || userLon != 0 else { return }
        let userLocation = CLLocation(latitude: userLat, longitude: userLon)

        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }

        for concert in concerts where concert.notifiedAt == nil {
            guard let lat = concert.latitude, let lon = concert.longitude else { continue }
            let venue = CLLocation(latitude: lat, longitude: lon)
            let distanceKm = userLocation.distance(from: venue) / 1000.0
            guard distanceKm <= radiusKm else { continue }

            let content = UNMutableNotificationContent()
            content.title = "🎫 \(concert.artistName) — \(concert.city)"
            content.body = concertBody(concert: concert, distanceKm: distanceKm)
            content.sound = .default
            content.threadIdentifier = "concert-\(concert.artistProviderID)"
            content.userInfo = ["concertProviderID": concert.providerID]

            let request = UNNotificationRequest(
                identifier: "concert-\(concert.providerID)",
                content: content,
                trigger: nil
            )
            try? await center.add(request)
            concert.notifiedAt = Date()
        }
    }

    private func concertBody(concert: ConcertData, distanceKm: Double) -> String {
        let venuePart = concert.venueName.isEmpty ? concert.city : "\(concert.venueName), \(concert.city)"
        let distancePart = " · \(Int(distanceKm))km away"
        if let date = concert.date {
            return "\(date.formatted(date: .abbreviated, time: .omitted)) · \(venuePart)\(distancePart)"
        }
        return "\(venuePart)\(distancePart)"
    }
}
