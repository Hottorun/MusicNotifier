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

    /// Build the Sendable snapshot + artwork request list from a list of
    /// `ReleaseData` instances. Safe to call from any actor as long as the
    /// supplied releases all belong to the caller's `ModelContext` (so the
    /// property reads are on the right executor). Caller hands the returned
    /// snapshot to `persist(_:)` from a detached task — JSON encoding + disk
    /// write are the expensive parts.
    static func captureSnapshot(from releases: [ReleaseData]?) -> (snapshot: WidgetSnapshot, requests: [WidgetArtworkRequest]) {
        guard let releases else {
            return (WidgetSnapshot(generatedAt: Date(), releases: []), [])
        }
        let now = Date()
        let withDates = releases.filter { $0.dismissedAt == nil && $0.releaseDate != nil }
        let withoutDates = releases.filter { $0.dismissedAt == nil && $0.releaseDate == nil }
        let sortedByProximity = withDates.sorted { lhs, rhs in
            let l = abs(lhs.releaseDate!.timeIntervalSince(now))
            let r = abs(rhs.releaseDate!.timeIntervalSince(now))
            return l < r
        }
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
        let snapshot = WidgetSnapshot(generatedAt: now, releases: snapshots)
        let requests = snapshots.map { WidgetArtworkRequest(id: $0.id, artworkURL: $0.artworkURL) }
        return (snapshot, requests)
    }

    /// Off-main JSON encode + atomic disk write + widget timeline reload.
    /// Safe to call from a detached task — touches neither SwiftUI nor
    /// SwiftData state.
    static func persist(snapshot: WidgetSnapshot) {
        guard let url = snapshotURL() else { return }
        do {
            let data = try JSONEncoder.widgetSnapshotEncoder.encode(snapshot)
            try data.write(to: url, options: [.atomic])
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            print("Failed to write widget snapshot: \(error)")
        }
    }

    /// Legacy entrypoint kept for any callers outside of the refresh pipeline.
    /// New callers in performance-sensitive paths should split via
    /// `captureSnapshot` + a detached `persist`.
    @MainActor
    @discardableResult
    static func write(releases: [ReleaseData]?) -> [WidgetArtworkRequest] {
        let (snapshot, requests) = captureSnapshot(from: releases)
        persist(snapshot: snapshot)
        return requests
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
