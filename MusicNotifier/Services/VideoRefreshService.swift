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
        let inputs = trackedArtists.map {
            ArtistFetchInput(
                providerID: $0.providerID,
                name: $0.name,
                provider: $0.provider,
                catalogArtistID: $0.catalogArtistID
            )
        }

        let fetched = await AppleMusicVideoService().fetchVideos(for: inputs)
        guard !fetched.isEmpty else { return VideoRefreshSummary(newVideoCount: 0) }

        let existing = (try? modelContext.fetch(FetchDescriptor<VideoData>())) ?? []
        var existingByID = Dictionary(uniqueKeysWithValues: existing.map { ($0.providerID, $0) })

        var newVideos: [VideoData] = []
        for video in fetched {
            if let row = existingByID[video.providerID] {
                row.title = video.title
                row.artistName = video.artistName
                row.sourceName = video.sourceName
                row.artworkURL = video.artworkURL
                row.videoURL = video.videoURL
                row.releaseDate = video.releaseDate
                row.durationMs = video.durationMs
                row.kind = video.kind.rawValue
            } else {
                let row = VideoData(
                    providerID: video.providerID,
                    artistProviderID: video.artistProviderID,
                    artistName: video.artistName,
                    title: video.title,
                    kind: video.kind,
                    sourceName: video.sourceName,
                    artworkURL: video.artworkURL,
                    videoURL: video.videoURL,
                    releaseDate: video.releaseDate,
                    durationMs: video.durationMs
                )
                modelContext.insert(row)
                existingByID[row.providerID] = row
                newVideos.append(row)
            }
        }

        try? modelContext.save()

        let defaults = UserDefaults.standard
        let videosEnabled = defaults.object(forKey: AppSettings.enableVideosTab) as? Bool ?? false
        let notificationsEnabled = defaults.object(forKey: AppSettings.notificationsEnabled) as? Bool ?? true
        let videoNotificationsEnabled = defaults.object(forKey: AppSettings.videoNotificationsEnabled) as? Bool ?? false

        if videosEnabled && notificationsEnabled && videoNotificationsEnabled {
            await scheduleNotifications(for: newVideos)
            try? modelContext.save()
        }

        return VideoRefreshSummary(newVideoCount: newVideos.count)
    }

    /// One quiet notification per newly discovered video. Music videos get a
    /// "🎬 New from <artist>" title; interviews get "🎤 New interview".
    private func scheduleNotifications(for videos: [VideoData]) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }

        for video in videos where video.notifiedAt == nil {
            let content = UNMutableNotificationContent()
            if VideoKind(rawValue: video.kind) == .interview {
                content.title = "🎤 New interview"
                content.body = "\(video.artistName) — \(video.title)"
            } else {
                content.title = "🎬 New from \(video.artistName)"
                content.body = video.title
            }
            content.sound = .default
            content.threadIdentifier = "video-\(video.artistProviderID)"
            content.userInfo = ["videoProviderID": video.providerID]

            let request = UNNotificationRequest(
                identifier: "video-\(video.providerID)",
                content: content,
                trigger: nil  // deliver immediately
            )
            try? await center.add(request)
            video.notifiedAt = Date()
        }
    }
}
