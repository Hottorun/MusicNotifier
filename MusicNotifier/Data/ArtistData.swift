//
//  ArtistData.swift
//  MusicNotifier
//
//  Created by Dimitris Kern on 28.07.25.
//

import Foundation
import SwiftData

enum ArtistNotificationPreference: String, CaseIterable, Identifiable, Codable {
    case inherit = "Inherit"
    case all = "All Releases"
    case albumsOnly = "Albums Only"
    case singlesOnly = "Singles Only"
    case muted = "Muted"

    var id: String { rawValue }
}

@Model
class ArtistData {
    // Every property needs a default value or to be optional so the SwiftData
    // CloudKit mirroring layer can hydrate records that lack a field after
    // schema changes (CloudKit requires all fields be optional/defaulted).
    var providerID: String = ""
    var name: String = ""
    var artworkURL: URL?
    var isTracked: Bool = false
    var provider: String = MusicProvider.appleMusic.rawValue
    var addedAt: Date = Date()
    var catalogArtistID: String?
    var lastCheckedAt: Date?
    var notificationPreference: String = ArtistNotificationPreference.inherit.rawValue
    /// Primary genre names pulled from Apple Music's catalog Artist (e.g.
    /// ["Hip-Hop/Rap"]). Optional — empty when we haven't been able to resolve
    /// the artist via MusicKit yet.
    var genres: [String]? = nil
    /// "artist" (default) or "label". Labels are followed the same way as
    /// artists but their release fetch uses MusicKit's RecordLabel.latestReleases
    /// relationship instead of the artist's catalog albums.
    var kind: String = "artist"

    init(providerID: String, name: String, artworkURL: URL? = nil, isTracked: Bool = false, provider: String = MusicProvider.appleMusic.rawValue, catalogArtistID: String? = nil) {
        self.providerID = providerID
        self.name = name
        self.artworkURL = artworkURL
        self.isTracked = isTracked
        self.provider = provider
        self.addedAt = Date()
        self.catalogArtistID = catalogArtistID
        self.lastCheckedAt = nil
        self.notificationPreference = ArtistNotificationPreference.inherit.rawValue
        self.genres = nil
    }
}
