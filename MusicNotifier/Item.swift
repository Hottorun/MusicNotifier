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
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
