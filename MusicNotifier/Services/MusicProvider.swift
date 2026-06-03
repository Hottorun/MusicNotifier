//
//  MusicProvider.swift
//  MusicNotifier
//

import Foundation

enum MusicProvider: String, CaseIterable, Identifiable, Codable {
    case appleMusic = "Apple Music"
    case spotify = "Spotify"

    var id: String { rawValue }

    var storagePrefix: String {
        switch self {
        case .appleMusic:
            "apple"
        case .spotify:
            "spotify"
        }
    }

    static func fromStoredName(_ value: String) -> MusicProvider {
        MusicProvider(rawValue: value) ?? .appleMusic
    }

    func scopedID(_ id: String) -> String {
        if id.hasPrefix("\(storagePrefix):") {
            return id
        }
        return "\(storagePrefix):\(id)"
    }

    func rawID(from scopedID: String) -> String {
        let prefix = "\(storagePrefix):"
        guard scopedID.hasPrefix(prefix) else { return scopedID }
        return String(scopedID.dropFirst(prefix.count))
    }
}

struct ProviderArtistSearchResult: Identifiable, Hashable {
    let id: String
    let provider: MusicProvider
    let name: String
    let artworkURL: URL?
}
