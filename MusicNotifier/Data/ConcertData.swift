//
//  ConcertData.swift
//  MusicNotifier
//

import Foundation
import SwiftData

@Model
class ConcertData {
    // CloudKit-mirrored — all optional/defaulted.
    var providerID: String = ""           // Bandsintown event id
    var artistProviderID: String = ""     // ID of the tracked artist this came from
    var artistName: String = ""

    var venueName: String = ""
    var city: String = ""
    var region: String?                   // US state / country region when present
    var country: String = ""
    var latitude: Double?
    var longitude: Double?

    var date: Date?                       // event datetime
    var ticketURL: URL?
    /// Headliner + supports as they appeared in the Bandsintown lineup.
    var lineup: [String]? = nil

    var savedAt: Date?                    // user explicitly hearted it
    var dismissedAt: Date?
    var notifiedAt: Date?
    var discoveredAt: Date = Date()
    var lastUpdatedAt: Date = Date()

    var provider: String = "bandsintown"

    init(
        providerID: String,
        artistProviderID: String,
        artistName: String,
        venueName: String,
        city: String,
        region: String? = nil,
        country: String,
        latitude: Double? = nil,
        longitude: Double? = nil,
        date: Date?,
        ticketURL: URL? = nil,
        lineup: [String]? = nil
    ) {
        self.providerID = providerID
        self.artistProviderID = artistProviderID
        self.artistName = artistName
        self.venueName = venueName
        self.city = city
        self.region = region
        self.country = country
        self.latitude = latitude
        self.longitude = longitude
        self.date = date
        self.ticketURL = ticketURL
        self.lineup = lineup
        self.discoveredAt = Date()
        self.lastUpdatedAt = Date()
    }
}
