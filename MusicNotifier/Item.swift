//
//  Item.swift
//  MusicNotifier
//
//  Created by Dimitris Kern on 28.07.25.
//

import Foundation
import SwiftData

@Model
final class Item {
    // CloudKit-mirrored SwiftData requires every persistent attribute to be
    // optional or have a default. Without this default, the store refuses to
    // load.
    var timestamp: Date = Date()

    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
