//
//  ConcertUpsertActor.swift
//  MusicNotifier
//
//  Background-thread upsert pipeline for `ConcertData`. Mirror of
//  `VideoUpsertActor`. Concerts can be a large list (many tracked artists ×
//  many tour dates each), so keeping the upsert + save off MainActor matters
//  even more than for videos.
//

import Foundation
import SwiftData

/// Sendable projection used by the post-actor detached notification scheduler.
/// Coordinates included so the distance-from-user filter can run off-main too.
struct ConcertNotificationSpec: Sendable {
    let providerID: String
    let artistProviderID: String
    let artistName: String
    let city: String
    let venueName: String
    let date: Date?
    let latitude: Double
    let longitude: Double
}

@ModelActor
actor ConcertUpsertActor {
    struct Output: Sendable {
        var newConcertCount: Int = 0
        var notifySpecs: [ConcertNotificationSpec] = []
        var storageFailure: String?
    }

    func apply(fetched: [FetchedConcert], now: Date, scheduleNotifications: Bool) -> Output {
        guard !fetched.isEmpty else { return Output() }
        var output = Output()

        do {
            let existing = try modelContext.fetch(FetchDescriptor<ConcertData>())
            var existingByID = Dictionary(
                existing.map { ($0.providerID, $0) },
                uniquingKeysWith: { a, _ in a }
            )

            var newConcertsData: [ConcertData] = []

            for concert in fetched {
                if let row = existingByID[concert.providerID] {
                    // Coalesce writes — most refreshes find no changes on
                    // existing tour dates, so suppressing redundant writes
                    // removes a substantial chunk of SwiftData notifications.
                    var changed = false
                    if row.artistName != concert.artistName { row.artistName = concert.artistName; changed = true }
                    if row.venueName != concert.venueName { row.venueName = concert.venueName; changed = true }
                    if row.city != concert.city { row.city = concert.city; changed = true }
                    if row.region != concert.region { row.region = concert.region; changed = true }
                    if row.country != concert.country { row.country = concert.country; changed = true }
                    if row.latitude != concert.latitude { row.latitude = concert.latitude; changed = true }
                    if row.longitude != concert.longitude { row.longitude = concert.longitude; changed = true }
                    if row.date != concert.date { row.date = concert.date; changed = true }
                    if row.ticketURL != concert.ticketURL { row.ticketURL = concert.ticketURL; changed = true }
                    if row.lineup != concert.lineup { row.lineup = concert.lineup; changed = true }
                    if changed { row.lastUpdatedAt = now }
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
                    newConcertsData.append(row)
                    output.newConcertCount += 1
                }
            }

            if scheduleNotifications {
                for concert in newConcertsData where concert.notifiedAt == nil {
                    guard let lat = concert.latitude, let lon = concert.longitude else { continue }
                    output.notifySpecs.append(
                        ConcertNotificationSpec(
                            providerID: concert.providerID,
                            artistProviderID: concert.artistProviderID,
                            artistName: concert.artistName,
                            city: concert.city,
                            venueName: concert.venueName,
                            date: concert.date,
                            latitude: lat,
                            longitude: lon
                        )
                    )
                    concert.notifiedAt = now
                }
            }

            try modelContext.save()
        } catch {
            output.storageFailure = error.localizedDescription
        }

        return output
    }
}
