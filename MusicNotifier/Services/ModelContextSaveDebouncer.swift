//
//  ModelContextSaveDebouncer.swift
//  MusicNotifier
//
//  Trailing-edge debouncer for `ModelContext.save()`. SwiftUI surfaces that
//  flip a `@Model` property (mark seen, dismiss, unfollow) traditionally
//  called `try? modelContext.save()` immediately — each save flushes the
//  WAL and round-trips through SQLite. In quick succession that adds up
//  to visible jank on the main actor. The debouncer coalesces saves
//  inside a short window (default 250ms) and also exposes `flush()`
//  for callers that need a synchronous commit (e.g. scenePhase = .background).
//

import Foundation
import SwiftData

@MainActor
final class ModelContextSaveDebouncer {
    static let shared = ModelContextSaveDebouncer()
    private init() {}

    private var pendingTask: Task<Void, Never>?
    private weak var pendingContext: ModelContext?
    private let delay: UInt64 = 250_000_000 // 250ms

    /// Schedule a trailing-edge save. Repeated calls within the window
    /// collapse to one save at the end of the quiet period.
    func scheduleSave(_ context: ModelContext) {
        pendingContext = context
        pendingTask?.cancel()
        pendingTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: delay)
            if Task.isCancelled { return }
            self.commit()
        }
    }

    /// Synchronous flush of any pending save. Call on scene-phase transitions
    /// to background so we never lose a debounced write.
    func flush() {
        pendingTask?.cancel()
        pendingTask = nil
        commit()
    }

    private func commit() {
        guard let context = pendingContext else { return }
        try? context.save()
        pendingContext = nil
    }
}
