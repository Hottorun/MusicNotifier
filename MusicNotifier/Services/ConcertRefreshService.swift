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
    /// Inputs that should be fed to `BandsintownService.fetchConcerts`.
    /// Exposed so callers (e.g. the foreground coordinator) can kick the
    /// network work off in parallel with the release fetch.
    nonisolated static func fetchInputs(from trackedArtists: [ArtistData]) -> [ArtistFetchInput] {
        trackedArtists.map {
            ArtistFetchInput(
                providerID: $0.providerID,
                name: $0.name,
                provider: $0.provider,
                catalogArtistID: $0.catalogArtistID
            )
        }
    }

    func refresh(
        trackedArtists: [ArtistData],
        modelContext: ModelContext,
        prefetched: [FetchedConcert]? = nil
    ) async -> ConcertRefreshSummary {
        let fetched: [FetchedConcert]
        if let prefetched {
            fetched = prefetched
        } else {
            let inputs = Self.fetchInputs(from: trackedArtists)
            fetched = await BandsintownService().fetchConcerts(for: inputs)
        }
        guard !fetched.isEmpty else { return ConcertRefreshSummary(newConcertCount: 0) }

        let defaults = UserDefaults.standard
        let concertsEnabled = defaults.object(forKey: AppSettings.enableConcertsTab) as? Bool ?? false
        let notificationsEnabled = defaults.object(forKey: AppSettings.notificationsEnabled) as? Bool ?? true
        let concertNotificationsEnabled = defaults.object(forKey: AppSettings.concertNotificationsEnabled) as? Bool ?? false
        let shouldScheduleNotifications = concertsEnabled && notificationsEnabled && concertNotificationsEnabled

        // Background upsert. The concerts table is one of the larger ones
        // after long-running use, so moving this off MainActor avoids a
        // visible end-of-refresh hitch.
        let actor = ConcertUpsertActor(modelContainer: modelContext.container)
        let output = await actor.apply(
            fetched: fetched,
            now: Date(),
            scheduleNotifications: shouldScheduleNotifications
        )

        if shouldScheduleNotifications && !output.notifySpecs.isEmpty {
            // Distance filter + notification adds — both fully detached.
            let radiusKm = defaults.object(forKey: AppSettings.nearbyRadiusKm) as? Double ?? 50.0
            let userLat = defaults.double(forKey: AppSettings.cachedLatitude)
            let userLon = defaults.double(forKey: AppSettings.cachedLongitude)
            guard userLat != 0 || userLon != 0 else { return ConcertRefreshSummary(newConcertCount: output.newConcertCount) }
            let specs = output.notifySpecs

            Task.detached(priority: .utility) {
                let userLocation = CLLocation(latitude: userLat, longitude: userLon)
                let center = UNUserNotificationCenter.current()
                let settings = await center.notificationSettings()
                let authorized = settings.authorizationStatus == .authorized
                    || settings.authorizationStatus == .provisional
                guard authorized else { return }

                for spec in specs {
                    let venue = CLLocation(latitude: spec.latitude, longitude: spec.longitude)
                    let distanceKm = userLocation.distance(from: venue) / 1000.0
                    guard distanceKm <= radiusKm else { continue }

                    let venuePart = spec.venueName.isEmpty ? spec.city : "\(spec.venueName), \(spec.city)"
                    let distancePart = " · \(Int(distanceKm))km away"
                    let body: String = {
                        if let date = spec.date {
                            return "\(date.formatted(date: .abbreviated, time: .omitted)) · \(venuePart)\(distancePart)"
                        }
                        return "\(venuePart)\(distancePart)"
                    }()

                    let content = UNMutableNotificationContent()
                    content.title = "🎫 \(spec.artistName) — \(spec.city)"
                    content.body = body
                    content.sound = .default
                    content.threadIdentifier = "concert-\(spec.artistProviderID)"
                    content.userInfo = ["concertProviderID": spec.providerID]

                    let request = UNNotificationRequest(
                        identifier: "concert-\(spec.providerID)",
                        content: content,
                        trigger: nil
                    )
                    try? await center.add(request)
                }
            }
        }

        return ConcertRefreshSummary(newConcertCount: output.newConcertCount)
    }
}
