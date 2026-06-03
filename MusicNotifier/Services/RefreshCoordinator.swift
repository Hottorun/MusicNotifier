//
//  RefreshCoordinator.swift
//  MusicNotifier
//

import Foundation
import SwiftData
import Combine
import WidgetKit
import MusicKit

/// Owns the refresh task and exposes live progress. ObservableObject + @Published
/// is more reliable across SwiftUI's TabView appearance lifecycle than @Observable.
@MainActor
final class RefreshCoordinator: ObservableObject {
    @Published var isRefreshing: Bool = false
    @Published var progress: ReleaseRefreshProgress?
    @Published var message: String?

    private var task: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?

    /// Apple Music returns HTTP 429 ("API capacity exceeded") well before 16-way
    /// fan-out, especially when `.with([.albums])` triggers nested subrequests.
    /// Keep this low to stay below the rate limit; the retry/backoff in
    /// AppleMusicReleaseService.withRetry absorbs the occasional spike.
    private let maxConcurrent = 4

    /// Hard cap on foreground refresh duration. Anything beyond this almost certainly
    /// means a network stall — surface it instead of letting the user stare at a frozen bar.
    private let watchdogTimeout: TimeInterval = 300

    /// Start a new refresh, cancelling any in-flight one. Supports both initial start
    /// and explicit restart from pull-to-refresh / tap-to-restart.
    func refresh(
        trackedArtists: [ArtistData],
        modelContext: ModelContext,
        notificationHour: Int,
        notificationMinute: Int
    ) {
        // DIAGNOSTIC: if this prints nil, the App Group capability isn't
        // authorized on the App ID and widget writes are landing in the main
        // app's documents directory (where the widget can't see them).
        let groupID = AppSettings.appGroupIdentifier
        let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)
        let defaults = UserDefaults(suiteName: groupID)
        Log.v("[AppGroup] id=\(groupID)")
        Log.v("[AppGroup] container=\(container?.path ?? "nil")")
        Log.v("[AppGroup] suiteUserDefaults=\(defaults == nil ? "nil" : "ok")")

        task?.cancel()
        task = nil
        watchdog?.cancel()
        watchdog = nil

        guard !trackedArtists.isEmpty else {
            message = "No tracked artists."
            isRefreshing = false
            progress = nil
            return
        }

        isRefreshing = true
        Self.setWidgetRefreshFlag(true)
        message = nil
        progress = ReleaseRefreshProgress(
            checkedArtists: 0,
            totalArtists: trackedArtists.count,
            currentArtistName: "Starting"
        )

        // Capture pure-Sendable inputs so the off-main work never touches SwiftData models.
        let inputs = trackedArtists.map {
            ArtistFetchInput(providerID: $0.providerID, name: $0.name, provider: $0.provider, catalogArtistID: $0.catalogArtistID, kind: $0.kind)
        }
        let totalCount = inputs.count
        let concurrent = min(maxConcurrent, totalCount)

        let timeout = watchdogTimeout
        watchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard let self, self.isRefreshing else { return }
            self.task?.cancel()
            self.message = "Refresh timed out after \(Int(timeout / 60)) min — try again."
        }

        // Detached, .userInitiated — runs on cooperative pool, fully independent of any
        // SwiftUI view lifecycle. The fetch loop is therefore not affected by tab switches.
        task = Task.detached(priority: .userInitiated) { [weak self] in
            Log.v("[Refresh] detached task started, inputs=\(inputs.count)")
            let warmupStart = Date()
            await Self.warmUpMusicKitIdentity(timeout: 8)
            Log.v("[Refresh] warmup done in \(String(format: "%.2f", Date().timeIntervalSince(warmupStart)))s")

            let appleService = AppleMusicReleaseService()
            let spotifyService = SpotifyService()

            // Speed win: batch-resolve all cached catalog IDs in one call (chunked by 25)
            // instead of doing a separate network round-trip per artist.
            let appleInputs = inputs.filter { MusicProvider.fromStoredName($0.provider) == .appleMusic }
            let cachedIDs = appleInputs.compactMap { $0.catalogArtistID }.filter { !$0.isEmpty }
            Log.v("[Refresh] apple=\(appleInputs.count), cachedIDs=\(cachedIDs.count), about to preResolve")
            let preResolveStart = Date()
            let preResolved = await appleService.preResolveCachedArtists(catalogIDs: cachedIDs)
            Log.v("[Refresh] preResolve done in \(String(format: "%.2f", Date().timeIntervalSince(preResolveStart)))s, resolved=\(preResolved.count)")

            var collected: [FetchedRelease] = []
            var failures: [String] = []
            var resolvedCatalogIDs: [String: String] = [:]
            var resolvedArtworkURLs: [String: URL] = [:]
            var checkedCount = 0
            var lastProgressDispatch = Date.distantPast

            await withTaskGroup(of: ArtistFetchOutcome.self) { group in
                var nextIndex = 0

                func enqueue(_ index: Int) {
                    let input = inputs[index]
                    let cached = input.catalogArtistID.flatMap { preResolved[$0] }
                    group.addTask {
                        let started = Date()
                        let outcome: ArtistFetchOutcome
                        switch MusicProvider.fromStoredName(input.provider) {
                        case .appleMusic:
                            outcome = await appleService.fetchOne(input, preResolvedArtist: cached)
                        case .spotify:
                            outcome = await spotifyService.fetchOne(input)
                        }
                        let elapsed = Date().timeIntervalSince(started)
                        if elapsed > 5 || outcome.errorMessage != nil {
                            Log.v("[Refresh] fetchOne(\(input.name)) elapsed=\(String(format: "%.2f", elapsed))s, releases=\(outcome.releases.count), error=\(outcome.errorMessage ?? "nil")")
                        }
                        return outcome
                    }
                }

                while nextIndex < min(concurrent, totalCount) {
                    enqueue(nextIndex)
                    nextIndex += 1
                }

                while let outcome = await group.next() {
                    if Task.isCancelled { break }

                    checkedCount += 1
                    collected.append(contentsOf: outcome.releases)
                    if let catID = outcome.catalogArtistID {
                        resolvedCatalogIDs[outcome.input.providerID] = catID
                    }
                    if let art = outcome.artworkURL {
                        resolvedArtworkURLs[outcome.input.providerID] = art
                    }
                    if let err = outcome.errorMessage {
                        failures.append("\(outcome.input.name): \(err)")
                    }

                    // Throttle progress updates to at most one every 150ms (plus final).
                    // Without this the MainActor gets spammed with progress micro-tasks
                    // when many fetches complete near-simultaneously.
                    let now = Date()
                    let isFinal = checkedCount == totalCount
                    if isFinal || now.timeIntervalSince(lastProgressDispatch) > 0.15 {
                        lastProgressDispatch = now
                        let checkedSnapshot = checkedCount
                        let currentName = outcome.input.name
                        Task { @MainActor [weak self] in
                            self?.progress = ReleaseRefreshProgress(
                                checkedArtists: checkedSnapshot,
                                totalArtists: totalCount,
                                currentArtistName: currentName
                            )
                        }
                    }

                    if nextIndex < totalCount && !Task.isCancelled {
                        enqueue(nextIndex)
                        nextIndex += 1
                    }
                }
            }

            if Task.isCancelled {
                await MainActor.run { [weak self] in
                    self?.isRefreshing = false
                    self?.progress = nil
                    self?.task = nil
                    self?.watchdog?.cancel()
                    self?.watchdog = nil
                    Self.setWidgetRefreshFlag(false)
                }
                return
            }

            let fetchResult = ReleaseFetchResult(
                releases: collected,
                failures: failures,
                checkedArtists: checkedCount,
                totalArtists: totalCount,
                resolvedCatalogIDs: resolvedCatalogIDs,
                resolvedArtworkURLs: resolvedArtworkURLs,
                storefrontCountryCode: nil
            )

            // service.apply is @MainActor → automatic hop to main for SwiftData + notifications.
            let summary = await ReleaseRefreshService().apply(
                result: fetchResult,
                trackedArtists: trackedArtists,
                modelContext: modelContext,
                scheduleNotifications: true,
                notificationHour: notificationHour,
                notificationMinute: notificationMinute
            )

            // Videos pass — only runs when the user has opted in via Settings.
            // Uses the catalog artist IDs that release refresh just resolved.
            let videosEnabled = UserDefaults.standard.object(forKey: AppSettings.enableVideosTab) as? Bool ?? false
            if videosEnabled && !Task.isCancelled {
                _ = await VideoRefreshService().refresh(
                    trackedArtists: trackedArtists,
                    modelContext: modelContext
                )
            }

            // Concerts pass — Bandsintown lookup per tracked artist when opted in.
            let concertsEnabled = UserDefaults.standard.object(forKey: AppSettings.enableConcertsTab) as? Bool ?? false
            if concertsEnabled && !Task.isCancelled {
                _ = await ConcertRefreshService().refresh(
                    trackedArtists: trackedArtists,
                    modelContext: modelContext
                )
            }

            await MainActor.run { [weak self] in
                guard let self else { return }
                if summary.failures.isEmpty {
                    self.message = summary.message
                } else {
                    let firstFailure = summary.failures.first ?? "Unknown error"
                    self.message = "\(summary.message) First: \(firstFailure)"
                }
                self.progress = nil
                self.isRefreshing = false
                self.task = nil
                self.watchdog?.cancel()
                self.watchdog = nil
                Self.setWidgetRefreshFlag(false)
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        watchdog?.cancel()
        watchdog = nil
        isRefreshing = false
        progress = nil
        Self.setWidgetRefreshFlag(false)
    }

    /// Race a MusicSubscription.current lookup against a timeout, so a hung
    /// identity-resolution can't block the refresh indefinitely.
    private static func warmUpMusicKitIdentity(timeout seconds: Double) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                _ = try? await MusicSubscription.current
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            }
            _ = await group.next()
            group.cancelAll()
        }
    }

    /// Toggles the App Group flag the widget checks to decide whether to render its
    /// "refreshing now" indicator, then nudges WidgetKit to redraw soon.
    static func setWidgetRefreshFlag(_ isRefreshing: Bool) {
        UserDefaults(suiteName: AppSettings.appGroupIdentifier)?
            .set(isRefreshing, forKey: "appIsRefreshing")
        WidgetCenter.shared.reloadAllTimelines()
    }
}
