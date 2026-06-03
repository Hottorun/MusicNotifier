//
//  VideoData.swift
//  MusicNotifier
//

import Foundation
import SwiftData

enum VideoKind: String, CaseIterable, Identifiable, Codable {
    case musicVideo = "Music Video"
    case interview = "Interview"

    var id: String { rawValue }
}

@Model
class VideoData {
    // All optional/defaulted for CloudKit mirroring compatibility.
    var providerID: String = ""
    var artistProviderID: String = ""
    var artistName: String = ""
    var title: String = ""
    var kind: String = VideoKind.musicVideo.rawValue
    /// `artistName` of the catalog `MusicVideo` — for interviews this is often
    /// "Zane Lowe" / "Apple Music 1" rather than the followed artist. Stored so
    /// the Videos tab can show "via Zane Lowe" subtitle.
    var sourceName: String?
    var artworkURL: URL?
    var videoURL: URL?
    var releaseDate: Date?
    var durationMs: Int?
    var provider: String = MusicProvider.appleMusic.rawValue
    var discoveredAt: Date = Date()
    var notifiedAt: Date?
    var isSeen: Bool = false

    init(
        providerID: String,
        artistProviderID: String,
        artistName: String,
        title: String,
        kind: VideoKind,
        sourceName: String? = nil,
        artworkURL: URL? = nil,
        videoURL: URL? = nil,
        releaseDate: Date? = nil,
        durationMs: Int? = nil,
        provider: String = MusicProvider.appleMusic.rawValue
    ) {
        self.providerID = providerID
        self.artistProviderID = artistProviderID
        self.artistName = artistName
        self.title = title
        self.kind = kind.rawValue
        self.sourceName = sourceName
        self.artworkURL = artworkURL
        self.videoURL = videoURL
        self.releaseDate = releaseDate
        self.durationMs = durationMs
        self.provider = provider
        self.discoveredAt = Date()
    }
}
