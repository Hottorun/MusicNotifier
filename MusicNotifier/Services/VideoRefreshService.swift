//
//  VideoRefreshService.swift
//  MusicNotifier
//

import Foundation
import SwiftData
import UserNotifications

struct VideoRefreshSummary {
    let newVideoCount: Int
}

@MainActor
struct VideoRefreshService {
    func refresh(
        trackedArtists: [ArtistData],
        modelContext: ModelContext
    ) async -> VideoRefreshSummary {
        // Labels (kind == "label") aren't fetchable via the artist endpoint —
        // MusicKit returns 404 for label IDs hit as artists. Strip them up
        // front so the videos pass only runs on real artist entries.
        let inputs = trackedArtists
            .filter { $0.kind != "label" }
            .map {
                ArtistFetchInput(
                    providerID: $0.providerID,
                    name: $0.name,
                    provider: $0.provider,
                    catalogArtistID: $0.catalogArtistID,
                    kind: $0.kind
                )
            }

        let fetched = await AppleMusicVideoService().fetchVideos(for: inputs)
        guard !fetched.isEmpty else { return VideoRefreshSummary(newVideoCount: 0) }

        let defaults = UserDefaults.standard
        let videosEnabled = defaults.object(forKey: AppSettings.enableVideosTab) as? Bool ?? false
        let notificationsEnabled = defaults.object(forKey: AppSettings.notificationsEnabled) as? Bool ?? true
        let videoNotificationsEnabled = defaults.object(forKey: AppSettings.videoNotificationsEnabled) as? Bool ?? false
        let shouldScheduleNotifications = videosEnabled && notificationsEnabled && videoNotificationsEnabled

        // Hand the heavy upsert off the main thread. The actor owns its own
        // ModelContext on a background executor; the shared ModelContainer
        // makes the save propagate back to MainActor's @Query observers.
        // Previously this loop + save ran on MainActor and is where the
        // "artist → videos" phase transition spike came from.
        let actor = VideoUpsertActor(modelContainer: modelContext.container)
        let output = await actor.apply(
            fetched: fetched,
            now: Date(),
            scheduleNotifications: shouldScheduleNotifications
        )

        if shouldScheduleNotifications && !output.notifySpecs.isEmpty {
            let specs = output.notifySpecs
            Task.detached(priority: .utility) {
                let center = UNUserNotificationCenter.current()
                let settings = await center.notificationSettings()
                let authorized = settings.authorizationStatus == .authorized
                    || settings.authorizationStatus == .provisional
                guard authorized else { return }

                for spec in specs {
                    let content = UNMutableNotificationContent()
                    if VideoKind(rawValue: spec.kind) == .interview {
                        content.title = "🎤 New interview"
                        content.body = "\(spec.artistName) — \(spec.title)"
                    } else {
                        content.title = "🎬 New from \(spec.artistName)"
                        content.body = spec.title
                    }
                    content.sound = .default
                    content.threadIdentifier = "video-\(spec.artistProviderID)"
                    content.userInfo = ["videoProviderID": spec.providerID]

                    let request = UNNotificationRequest(
                        identifier: "video-\(spec.providerID)",
                        content: content,
                        trigger: nil
                    )
                    try? await center.add(request)
                }
            }
        }

        return VideoRefreshSummary(newVideoCount: output.newVideoCount)
    }
}
