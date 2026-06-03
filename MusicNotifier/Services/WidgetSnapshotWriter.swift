//
//  WidgetSnapshotWriter.swift
//  MusicNotifier
//

import Foundation
import WidgetKit

struct WidgetReleaseSnapshot: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let artistName: String
    let title: String
    let releaseDate: Date?
    let artworkURL: URL?
    let artworkFileName: String?
    let albumURL: URL?
    let type: String
}

struct WidgetSnapshot: Codable, Sendable {
    let generatedAt: Date
    let releases: [WidgetReleaseSnapshot]
}

struct WidgetArtworkRequest: Sendable {
    let id: String
    let artworkURL: URL?
}

enum WidgetSnapshotWriter {
    static let fileName = "widget-releases.json"

    @discardableResult
    static func write(releases: [ReleaseData]?) -> [WidgetArtworkRequest] {
        guard let releases else { return [] }
        // Widget views care about "upcoming" + "today" + "very recent past".
        // Sort by absolute distance from today so soonest-future and most-recent-past
        // appear first; old historical releases fall off the end of the 40-item budget.
        let now = Date()
        let withDates = releases.filter { $0.dismissedAt == nil && $0.releaseDate != nil }
        let withoutDates = releases.filter { $0.dismissedAt == nil && $0.releaseDate == nil }
        let sortedByProximity = withDates.sorted { lhs, rhs in
            let l = abs(lhs.releaseDate!.timeIntervalSince(now))
            let r = abs(rhs.releaseDate!.timeIntervalSince(now))
            return l < r
        }
        // Within the 40-item budget: prioritize dated releases, then any
        // unknown-date entries at the end as filler.
        let limitedReleases = Array((sortedByProximity + withoutDates).prefix(40))

        let snapshots = limitedReleases.map { release in
            WidgetReleaseSnapshot(
                id: release.providerID,
                artistName: release.artistName,
                title: release.title,
                releaseDate: release.releaseDate,
                artworkURL: release.artworkURL,
                artworkFileName: artworkFileName(for: release.providerID),
                albumURL: release.albumURL,
                type: release.type
            )
        }

        let snapshot = WidgetSnapshot(
            generatedAt: Date(),
            releases: snapshots
        )

        guard let url = snapshotURL() else { return [] }

        do {
            let data = try JSONEncoder.widgetSnapshotEncoder.encode(snapshot)
            try data.write(to: url, options: [.atomic])
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            print("Failed to write widget snapshot: \(error)")
        }

        return snapshots.map { WidgetArtworkRequest(id: $0.id, artworkURL: $0.artworkURL) }
    }

    static func cacheArtwork(for requests: [WidgetArtworkRequest]) async {
        guard !requests.isEmpty else { return }

        await withTaskGroup(of: Void.self) { group in
            for request in requests.prefix(20) {
                group.addTask {
                    await cachedArtworkFileName(for: request)
                }
            }
        }

        WidgetCenter.shared.reloadAllTimelines()
    }

    private static func snapshotURL() -> URL? {
        let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppSettings.appGroupIdentifier)
        let directory = container ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        return directory?.appendingPathComponent(fileName)
    }

    private static func cachedArtworkFileName(for request: WidgetArtworkRequest) async {
        guard let artworkURL = request.artworkURL,
              let directory = artworkDirectory() else {
            return
        }

        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileName = artworkFileName(for: request.id)
        let fileURL = directory.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            return
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: artworkURL)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return
            }

            try data.write(to: fileURL, options: [.atomic])
        } catch {
            return
        }
    }

    private static func artworkFileName(for providerID: String) -> String {
        "\(providerID.replacingOccurrences(of: "/", with: "-")).jpg"
    }

    private static func artworkDirectory() -> URL? {
        let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppSettings.appGroupIdentifier)
        let directory = container ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        return directory?.appendingPathComponent("WidgetArtwork", isDirectory: true)
    }
}

extension JSONEncoder {
    static var widgetSnapshotEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static var widgetSnapshotDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
