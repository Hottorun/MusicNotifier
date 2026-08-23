//
//  AppSchema.swift
//  MusicNotifier
//

import Foundation
import SwiftData

/// The single definition of what this app persists, and how the store is
/// opened. Every entry point — the app itself and the App Intents extension
/// point — must go through here.
///
/// This exists because they used to disagree. `IntentDataAccess.makeContainer`
/// built its own `Schema([Item, ArtistData, ReleaseData])` — a *subset*,
/// missing `VideoData` and `ConcertData` — and opened it with a plain local
/// `ModelConfiguration`, while pointing at the same default store file the app
/// uses. Two concrete problems fell out of that:
///
/// 1. SwiftData treats dropping a model from the schema as a routine
///    lightweight migration and silently deletes its table. (Verified
///    directly: removing the unused `Item` model dropped `ZITEM` with no
///    error and no warning.) So running a Shortcut would have taken the
///    user's video and concert rows with it, and the next app launch would
///    have recreated them empty.
/// 2. Opening a CloudKit-mirrored store with a non-CloudKit configuration
///    leaves the mirroring metadata inconsistent.
enum AppSchema {
    static let cloudKitContainerIdentifier = "iCloud.com.kern.functional.MusicNotifier"

    /// Every persisted model. Adding one here is the only place it needs
    /// declaring — and remember that any change to this list needs a matching
    /// CloudKit schema deploy before it reaches App Store users.
    static func make() -> Schema {
        Schema([
            ArtistData.self,
            ReleaseData.self,
            VideoData.self,
            ConcertData.self,
        ])
    }

    /// iCloud-backed configuration. SwiftData mirrors the local store to the
    /// user's private CloudKit DB so artists and releases sync across devices.
    static func cloudConfiguration(for schema: Schema) -> ModelConfiguration {
        ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            cloudKitDatabase: .private(cloudKitContainerIdentifier)
        )
    }

    /// Local-only fallback for when the CloudKit container isn't reachable.
    static func localConfiguration(for schema: Schema) -> ModelConfiguration {
        ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
    }

    // MARK: - Store backing diagnostics

    /// Whether the live `ModelContainer` actually came up CloudKit-backed.
    ///
    /// Container creation falls back to a local-only store when the CloudKit
    /// container can't be opened, and that fallback used to be completely
    /// invisible: the only log line was a `Log.v` (compiled to a no-op), and
    /// Settings derived its sync status purely from `CKAccountStatus`. So a
    /// user signed into iCloud was told "Syncing — mirrors across iPhone,
    /// iPad and Mac" while the app was writing to a store that would never
    /// sync anywhere. Recording the real outcome makes that state visible in
    /// Settings instead of silently wrong.
    private static let cloudBackedDefaultsKey = "storeIsCloudKitBacked"

    static func recordStoreBacking(isCloudKitBacked: Bool) {
        UserDefaults.standard.set(isCloudKitBacked, forKey: cloudBackedDefaultsKey)
    }

    /// `nil` until the first container creation has completed.
    static var storeIsCloudKitBacked: Bool? {
        UserDefaults.standard.object(forKey: cloudBackedDefaultsKey) as? Bool
    }
}
