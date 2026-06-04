//
//  Log.swift
//  MusicNotifier
//
//  Gate for diagnostic prints. `Log.v(...)` is a no-op unless `verbose` is
//  flipped on, so the console stays clean for normal use but the diagnostic
//  scaffolding remains in place for when something breaks.
//

import Foundation

enum Log {
    /// Flip to `true` to re-enable [AppGroup], [Refresh], [Favorites],
    /// [Spotify], [Dedup], and AppleMusicVideoService verbose prints.
    static let verbose = false
    @inline(__always)
    static func v(_ message: @autoclosure () -> String) {
        if verbose { print(message()) }
    }
}
