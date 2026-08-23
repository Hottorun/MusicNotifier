//
//  CloudSyncMonitor.swift
//  MusicNotifier
//

import Foundation
import CoreData

/// Observes what CloudKit mirroring is *actually* doing.
///
/// This exists because every cheaper signal lies:
///
/// - `CKAccountStatus` only says an iCloud account exists. It says nothing
///   about whether this app's container is reachable or whether its schema has
///   been deployed, so Settings happily reported "Syncing — mirrors across
///   iPhone, iPad and Mac" while nothing was mirroring at all.
/// - Whether `ModelContainer(for:configurations:)` succeeded with the CloudKit
///   configuration is also not it: that call succeeds even with **no iCloud
///   account signed in** (verified — the simulator, which has no account,
///   records it as CloudKit-backed). Mirroring fails asynchronously afterwards.
///
/// `NSPersistentCloudKitContainer` publishes the real outcome through
/// `eventChangedNotification`: setup, import and export events, each with an
/// end date and an optional error. That's the only trustworthy source, and a
/// failing setup event is exactly what a missing/undeployed CloudKit schema
/// looks like from inside the app.
@MainActor
final class CloudSyncMonitor: ObservableObject {
    static let shared = CloudSyncMonitor()

    /// Localised description of the most recent failed mirroring event.
    @Published private(set) var lastErrorDescription: String?
    /// When a mirroring event last completed cleanly.
    @Published private(set) var lastSuccessAt: Date?
    /// False until CloudKit has reported anything at all — distinguishes
    /// "healthy" from "we simply haven't heard from CloudKit yet".
    @Published private(set) var hasObservedEvent = false

    private var observer: NSObjectProtocol?

    private init() {}

    func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let event = note.userInfo?[
                NSPersistentCloudKitContainer.eventNotificationUserInfoKey
            ] as? NSPersistentCloudKitContainer.Event else { return }
            // In-flight events have no end date; only completions carry a verdict.
            guard event.endDate != nil else { return }

            MainActor.assumeIsolated {
                guard let self else { return }
                self.hasObservedEvent = true
                if let error = event.error {
                    self.lastErrorDescription = error.localizedDescription
                } else {
                    self.lastErrorDescription = nil
                    self.lastSuccessAt = Date()
                }
            }
        }
    }
}
