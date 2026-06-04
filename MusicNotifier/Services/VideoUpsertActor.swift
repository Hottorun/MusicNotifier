//
//  VideoUpsertActor.swift
//  MusicNotifier
//
//  Background-thread upsert pipeline for `VideoData`. Same shape as
//  `ReleaseUpsertActor`: heavy SwiftData work happens on a dedicated executor
//  with its own ModelContext so the main thread stays responsive during the
//  videos phase of a refresh. Returns Sendable specs for notification
//  scheduling so MainActor never has to crack open a non-Sendable @Model
//  after the actor returns.
//

import Foundation
import SwiftData

/// Sendable projection of the few fields a video notification needs. The
/// scheduler reads from these on a detached task so UNUserNotificationCenter
/// adds never block the main thread.
struct VideoNotificationSpec: Sendable {
    let providerID: String
    let artistProviderID: String
    let artistName: String
    let title: String
    let kind: String
}

@ModelActor
actor VideoUpsertActor {
    struct Output: Sendable {
        var newVideoCount: Int = 0
        var notifySpecs: [VideoNotificationSpec] = []
        var storageFailure: String?
    }

    func apply(fetched: [FetchedVideo], now: Date, scheduleNotifications: Bool) -> Output {
        guard !fetched.isEmpty else { return Output() }
        var output = Output()

        do {
            let existing = try modelContext.fetch(FetchDescriptor<VideoData>())
            // `uniquingKeysWith` — defensive against duplicate rows that can
            // exist after a CloudKit sync collision.
            var existingByID = Dictionary(
                existing.map { ($0.providerID, $0) },
                uniquingKeysWith: { a, _ in a }
            )

            var newVideosData: [VideoData] = []

            for video in fetched {
                if let row = existingByID[video.providerID] {
                    // Coalesce — only write when a property actually changed
                    // so we don't fire a SwiftData change notification for
                    // every byte-identical incoming video (the common case
                    // on subsequent refreshes).
                    if row.title != video.title { row.title = video.title }
                    if row.artistName != video.artistName { row.artistName = video.artistName }
                    if row.sourceName != video.sourceName { row.sourceName = video.sourceName }
                    if row.artworkURL != video.artworkURL { row.artworkURL = video.artworkURL }
                    if row.videoURL != video.videoURL { row.videoURL = video.videoURL }
                    if row.releaseDate != video.releaseDate { row.releaseDate = video.releaseDate }
                    if row.durationMs != video.durationMs { row.durationMs = video.durationMs }
                    if row.kind != video.kind.rawValue { row.kind = video.kind.rawValue }
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
                    newVideosData.append(row)
                    output.newVideoCount += 1
                }
            }

            // Build notification specs + mark notifiedAt before the single
            // save call, so the commit captures everything atomically and
            // the actual UNUserNotificationCenter.add calls happen detached.
            if scheduleNotifications {
                let notificationCap = 12
                let sorted = newVideosData.sorted { ($0.releaseDate ?? .distantPast) > ($1.releaseDate ?? .distantPast) }
                for video in sorted.prefix(notificationCap) where video.notifiedAt == nil {
                    output.notifySpecs.append(
                        VideoNotificationSpec(
                            providerID: video.providerID,
                            artistProviderID: video.artistProviderID,
                            artistName: video.artistName,
                            title: video.title,
                            kind: video.kind
                        )
                    )
                    video.notifiedAt = now
                }
            }

            try modelContext.save()
        } catch {
            output.storageFailure = error.localizedDescription
        }

        return output
    }
}
