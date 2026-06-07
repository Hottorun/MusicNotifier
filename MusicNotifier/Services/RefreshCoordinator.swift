//
//  RefreshCoordinator.swift
//  MusicNotifier
//

import Foundation
import SwiftData
import Combine
import WidgetKit
import MusicKit

/// Owns the refresh task and exposes live progress.
///
/// Switched from `ObservableObject + @Published` to `@Observable` because the
/// progress field updates ~6 Hz during a refresh, and `@Published` broadcasts
/// `objectWillChange` to every observing view on every change — even ones
/// that only read `isRefreshing`. That made `HomeView.body` re-run on every
/// tick, dragging the `derived` walk over thousands of `ReleaseData` rows
/// through the main thread and producing the visible refresh-time lag.
/// `@Observable` does per-property change tracking, so a view that only
/// touches `isRefreshing` is unaffected by `progress` flips.
@MainActor
@Observable
final class RefreshCoordinator {
    var isRefreshing: Bool = false
    var progress: ReleaseRefreshProgress?
    var message: String?

    private var task: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?

    /// Concurrency cap is now adaptive (AIMD). Start higher than the old
    /// fixed `4` since the primary path is now REST `sort=-releaseDate`
    /// (no nested MusicKit subrequests). Halve on detected 429, bump by 1
    /// after 10 consecutive rate-limit-free outcomes.
    private let initialConcurrent = 6
    private let minConcurrent = 2
    private let maxConcurrentCap = 10

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
            currentArtistName: "Starting",
            phase: .warming,
            isIndeterminate: true
        )

        // Capture pure-Sendable inputs so the off-main work never touches SwiftData models.
        let inputs = trackedArtists.map {
            ArtistFetchInput(providerID: $0.providerID, name: $0.name, provider: $0.provider, catalogArtistID: $0.catalogArtistID, kind: $0.kind)
        }
        let totalCount = inputs.count
        let initialCap = min(initialConcurrent, totalCount)
        let minCap = min(minConcurrent, max(1, totalCount))
        let maxCap = min(maxConcurrentCap, totalCount)

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

            // Compute incremental-fetch window from the last successful refresh.
            // First refresh ever → nil (full default window). Otherwise pass
            // days-since-last-refresh; the service tacks on a 3-day buffer.
            let lastSuccess = UserDefaults.standard.double(forKey: AppSettings.lastSuccessfulRefreshAt)
            let daysSinceLastRefresh: Int? = {
                guard lastSuccess > 0 else { return nil }
                let elapsedSeconds = Date().timeIntervalSince1970 - lastSuccess
                guard elapsedSeconds > 0 else { return nil }
                return max(1, Int(elapsedSeconds / 86_400))
            }()
            if let days = daysSinceLastRefresh {
                Log.v("[Refresh] incremental window: \(days) days since last refresh")
            } else {
                Log.v("[Refresh] first refresh — using full default window")
            }

            // Kick off videos + concerts fetches in parallel with releases so the
            // network legs overlap. They were previously sequential (videos after
            // releases, then concerts after videos), which left the progress bar
            // sitting on indeterminate spinners for the whole tail of the refresh.
            let videosEnabled = UserDefaults.standard.object(forKey: AppSettings.enableVideosTab) as? Bool ?? false
            let concertsEnabled = UserDefaults.standard.object(forKey: AppSettings.enableConcertsTab) as? Bool ?? false
            let videoInputs = videosEnabled ? inputs.filter { $0.kind != "label" } : []
            async let videoFetchTask: [FetchedVideo] = videosEnabled
                ? AppleMusicVideoService().fetchVideos(for: videoInputs)
                : []
            async let concertFetchTask: [FetchedConcert] = concertsEnabled
                ? BandsintownService().fetchConcerts(for: inputs)
                : []

            // Speed win: batch-resolve all cached catalog IDs in one call (chunked by 25)
            // instead of doing a separate network round-trip per artist.
            let appleInputs = inputs.filter { MusicProvider.fromStoredName($0.provider) == .appleMusic }
            let cachedIDs = appleInputs.compactMap { $0.catalogArtistID }.filter { !$0.isEmpty }
            Log.v("[Refresh] apple=\(appleInputs.count), cachedIDs=\(cachedIDs.count), about to preResolve")
            let preResolveStart = Date()
            // Pre-resolve cached artists *and* the storefront concurrently.
            // Storefront used to be re-fetched ~2× per artist inside the REST
            // helpers; resolving once here saves N round-trips on every refresh.
            async let preResolvedTask = appleService.preResolveCachedArtists(catalogIDs: cachedIDs)
            async let storefrontTask = appleService.resolveStorefrontCountryCode()
            let preResolved = await preResolvedTask
            let storefront = await storefrontTask
            Log.v("[Refresh] preResolve done in \(String(format: "%.2f", Date().timeIntervalSince(preResolveStart)))s, resolved=\(preResolved.count), storefront=\(storefront)")

            var collected: [FetchedRelease] = []
            var failures: [String] = []
            var resolvedCatalogIDs: [String: String] = [:]
            var resolvedArtworkURLs: [String: URL] = [:]
            var checkedCount = 0
            var lastProgressDispatch = Date.distantPast

            await withTaskGroup(of: ArtistFetchOutcome.self) { group in
                var nextIndex = 0
                var inFlight = 0
                // AIMD state. Halve cap on rate-limit; +1 every 10 clean outcomes.
                var currentCap = initialCap
                var cleanStreak = 0

                func enqueue(_ index: Int) {
                    let input = inputs[index]
                    let cached = input.catalogArtistID.flatMap { preResolved[$0] }
                    group.addTask {
                        let started = Date()
                        let outcome: ArtistFetchOutcome
                        switch MusicProvider.fromStoredName(input.provider) {
                        case .appleMusic:
                            outcome = await appleService.fetchOne(
                                input,
                                preResolvedArtist: cached,
                                storefront: storefront,
                                daysSinceLastRefresh: daysSinceLastRefresh
                            )
                        case .spotify:
                            outcome = await spotifyService.fetchOne(input)
                        }
                        let elapsed = Date().timeIntervalSince(started)
                        if elapsed > 5 || outcome.errorMessage != nil {
                            Log.v("[Refresh] fetchOne(\(input.name)) elapsed=\(String(format: "%.2f", elapsed))s, releases=\(outcome.releases.count), error=\(outcome.errorMessage ?? "nil"), rateLimited=\(outcome.wasRateLimited)")
                        }
                        return outcome
                    }
                }

                while nextIndex < currentCap && nextIndex < totalCount {
                    enqueue(nextIndex)
                    inFlight += 1
                    nextIndex += 1
                }

                while let outcome = await group.next() {
                    if Task.isCancelled { break }

                    inFlight -= 1
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

                    // AIMD update: detected rate-limit halves the cap; ten
                    // clean outcomes in a row bump it back up by one. Keeps
                    // throughput high when Apple is healthy, backs off fast
                    // when capacity tightens.
                    if outcome.wasRateLimited {
                        currentCap = max(minCap, currentCap / 2)
                        cleanStreak = 0
                        Log.v("[Refresh] rate-limit detected → cap=\(currentCap)")
                    } else {
                        cleanStreak += 1
                        if cleanStreak >= 10 && currentCap < maxCap {
                            currentCap += 1
                            cleanStreak = 0
                            Log.v("[Refresh] cap bumped → \(currentCap)")
                        }
                    }

                    // Throttle progress updates to at most one every 150ms (plus final).
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
                                currentArtistName: currentName,
                                phase: .releases,
                                isIndeterminate: false
                            )
                        }
                    }

                    // Re-fill up to current cap. May enqueue 0 (cap dropped),
                    // 1 (steady), or 2 (cap just bumped after this outcome).
                    while inFlight < currentCap && nextIndex < totalCount && !Task.isCancelled {
                        enqueue(nextIndex)
                        inFlight += 1
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

            // Videos + concerts: the network fetches already ran in parallel
            // with the release fetch (see async let above). Now we just await
            // the results and hand them to the @MainActor apply step. Because
            // the fetch is already done, the "Looking for new videos…" phase
            // is typically near-instant instead of the 5–10s it used to take.
            if videosEnabled && !Task.isCancelled {
                await MainActor.run { [weak self] in
                    self?.progress = ReleaseRefreshProgress(
                        checkedArtists: totalCount,
                        totalArtists: totalCount,
                        currentArtistName: RefreshPhase.videos.rawValue,
                        phase: .videos,
                        isIndeterminate: true
                    )
                }
                let prefetchedVideos = await videoFetchTask
                _ = await VideoRefreshService().refresh(
                    trackedArtists: trackedArtists,
                    modelContext: modelContext,
                    prefetched: prefetchedVideos
                )
            }
            if concertsEnabled && !Task.isCancelled {
                await MainActor.run { [weak self] in
                    self?.progress = ReleaseRefreshProgress(
                        checkedArtists: totalCount,
                        totalArtists: totalCount,
                        currentArtistName: RefreshPhase.concerts.rawValue,
                        phase: .concerts,
                        isIndeterminate: true
                    )
                }
                let prefetchedConcerts = await concertFetchTask
                _ = await ConcertRefreshService().refresh(
                    trackedArtists: trackedArtists,
                    modelContext: modelContext,
                    prefetched: prefetchedConcerts
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
    ///
    /// `reloadAllTimelines` is throttled — back-to-back calls (start-of-refresh,
    /// end-of-refresh, plus any intermediate writes) were hammering WidgetKit
    /// and contributing to visible main-actor stalls during refresh. End-of-
    /// refresh (when `isRefreshing == false`) always reloads since the data
    /// just changed; start-of-refresh reloads at most once per 5s.
    private static let widgetReloadInterval: TimeInterval = 5
    nonisolated(unsafe) private static var lastWidgetReload: Date = .distantPast
    private static let widgetReloadLock = NSLock()

    static func setWidgetRefreshFlag(_ isRefreshing: Bool) {
        UserDefaults(suiteName: AppSettings.appGroupIdentifier)?
            .set(isRefreshing, forKey: "appIsRefreshing")

        let now = Date()
        let shouldReload: Bool
        widgetReloadLock.lock()
        if !isRefreshing {
            // End-of-refresh: always reload — the data the widget renders just changed.
            lastWidgetReload = now
            shouldReload = true
        } else if now.timeIntervalSince(lastWidgetReload) >= widgetReloadInterval {
            lastWidgetReload = now
            shouldReload = true
        } else {
            shouldReload = false
        }
        widgetReloadLock.unlock()
        if shouldReload {
            WidgetCenter.shared.reloadAllTimelines()
        }
    }
}
