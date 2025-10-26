//
//  ArtistData.swift
//  MusicNotifier
//
//  Created by Dimitris Kern on 28.07.25.
//

import Foundation
import SwiftData

@Model
class ArtistData {
    var Name: String
   // var isFavourite: bool = false

    init(Name: String) {
        self.Name = Name
        
    }
}
