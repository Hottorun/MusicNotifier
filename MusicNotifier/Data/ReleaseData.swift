//
//  ReleaseData.swift
//  MusicNotifier
//

import Foundation
import SwiftData

enum ReleaseKind: String, CaseIterable, Identifiable, Codable {
    case album = "Album"
    case single = "Single"
    case ep = "EP"
    case compilation = "Compilation"
    case liveAlbum = "Live Album"
    case remix = "Remix"

    var id: String { rawValue }
}

@Model
class ReleaseData {
    // Defaults required for CloudKit-mirrored SwiftData — CloudKit can't enforce
    // required attributes, so absent fields need to fall back to a default.
    var providerID: String = ""
    var artistProviderID: String = ""
    var artistName: String = ""
    var title: String = ""
    var releaseDate: Date?
    var artworkURL: URL?
    var albumURL: URL?
    var provider: String = MusicProvider.appleMusic.rawValue
    var type: String = ReleaseKind.album.rawValue
    var isSeen: Bool = false
    var discoveredAt: Date = Date()
    var notifiedAt: Date?
    var dismissedAt: Date?
    var firstSeenAt: Date = Date()
    var lastUpdatedAt: Date = Date()

    init(
        providerID: String,
        artistProviderID: String,
        artistName: String,
        title: String,
        releaseDate: Date?,
        artworkURL: URL?,
        albumURL: URL?,
        provider: String = MusicProvider.appleMusic.rawValue,
        type: String = ReleaseKind.album.rawValue
    ) {
        self.providerID = providerID
        self.artistProviderID = artistProviderID
        self.artistName = artistName
        self.title = title
        self.releaseDate = releaseDate
        self.artworkURL = artworkURL
        self.albumURL = albumURL
        self.provider = provider
        self.type = type
        self.isSeen = false
        self.discoveredAt = Date()
        self.notifiedAt = nil
        self.dismissedAt = nil
        self.firstSeenAt = Date()
        self.lastUpdatedAt = Date()
    }
}
