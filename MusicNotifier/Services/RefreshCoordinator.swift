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

        // Captured on main: the ModelContainer the streaming upsert actor
        // uses to write releases off-main during the task group. SwiftData
        // mirrors actor writes back to this same container's main context,
        // so `@Query` on Home fires per batch and the feed fills in live.
        let modelContainer = modelContext.container

        // Detached, .userInitiated — runs on cooperative pool, fully independent of any
        // SwiftUI view lifecycle. The fetch loop is therefore not affected by tab switches.
        task = Task.detached(priority: .userInitiated) { [weak self] in
            Log.v("[Refresh] detached task started, inputs=\(inputs.count)")

            // Auth gate. If a refresh kicks off at launch (auto-refresh) before
            // `verifyMusicLibraryAccess` finishes its `MusicAuthorization.request`,
            // the pre-resolve / storefront / album calls all fire while status
            // is `.notDetermined` and silently fall back to a Locale storefront.
            // Block here until the user has actually granted (or denied) access.
            await Self.awaitMusicAuthorizationResolved()

            let warmupStart = Date()
            await Self.warmUpMusicKitIdentity(timeout: 8)
            Log.v("[Refresh] warmup done in \(String(format: "%.2f", Date().timeIntervalSince(warmupStart)))s")

            let appleService = AppleMusicReleaseService()
            let spotifyService = SpotifyService()

            // Fetch window is fixed, not incremental: a refresh only ever
            // pulls releases from the last `ReleaseRecencyGate.windowDays`
            // days (plus anything future-dated). The old behaviour widened
            // the window to "everything since the last successful refresh"
            // — and to "since Jan 1" on a first run — which is why stale
            // back-catalog kept landing in the feed. `isFirstRefresh` is
            // still tracked, but only to decide whether to retry a failed
            // artist fetch.
            let lastSuccess = UserDefaults.standard.double(forKey: AppSettings.lastSuccessfulRefreshAt)
            let isFirstRefresh = lastSuccess <= 0
            Log.v("[Refresh] window: last \(ReleaseRecencyGate.windowDays) days (firstRefresh=\(isFirstRefresh))")

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

            // Advance phase out of `.warming` before pre-resolve so the UI
            // shows "Checking releases" instead of "Connecting to Apple
            // Music" while we batch-resolve. Pre-resolve hits the same
            // network/itunescloudd path that's saturated during CloudKit
            // hydration, so it can take noticeably longer than warmup on a
            // fresh install.
            await MainActor.run { [weak self] in
                self?.progress = ReleaseRefreshProgress(
                    checkedArtists: 0,
                    totalArtists: totalCount,
                    currentArtistName: "Starting",
                    phase: .releases,
                    isIndeterminate: true
                )
            }

            // Speed win: batch-resolve all cached catalog IDs in one call (chunked by 25)
            // instead of doing a separate network round-trip per artist.
            let appleInputs = inputs.filter { MusicProvider.fromStoredName($0.provider) == .appleMusic }
            let cachedIDs = appleInputs.compactMap { $0.catalogArtistID }.filter { !$0.isEmpty }
            Log.v("[Refresh] apple=\(appleInputs.count), cachedIDs=\(cachedIDs.count), about to preResolve")
            let preResolveStart = Date()
            // Pre-resolve cached artists *and* the storefront concurrently,
            // each races a 20s timeout so a stalled itunescloudd can't pin
            // the refresh in pre-resolve forever (we observed this on a
            // fresh install while CloudKit was saturating the device).
            // Fallbacks: empty dict for cached artists (caller falls back
            // to per-artist resolution), "us" for storefront.
            async let preResolvedTask = Self.raceWithTimeout(
                seconds: 20,
                fallback: [String: Artist]()
            ) {
                await appleService.preResolveCachedArtists(catalogIDs: cachedIDs)
            }
            async let storefrontTask = Self.raceWithTimeout(
                seconds: 20,
                fallback: "us"
            ) {
                await appleService.resolveStorefrontCountryCode()
            }
            let preResolved = await preResolvedTask
            let storefront = await storefrontTask
            Log.v("[Refresh] preResolve done in \(String(format: "%.2f", Date().timeIntervalSince(preResolveStart)))s, resolved=\(preResolved.count), storefront=\(storefront)")

            // Streaming upsert: the actor lives on a background executor,
            // shares the main ModelContainer, and each `applyBatch` call
            // commits a small transaction that propagates to the @Query on
            // Home — so the feed fills in artist-by-artist instead of all
            // at once after the task group drains.
            let upsertActor = ReleaseUpsertActor(modelContainer: modelContainer)
            let releaseService = ReleaseRefreshService()
            var streamingState = ReleaseRefreshService.StreamingRefreshState()
            // Flush whenever the buffer hits this many releases or it has
            // been ~4s since the last flush, whichever fires first. Threshold
            // was 24 / 1.5s — too aggressive on stores with thousands of
            // releases (every flush re-fires `@Query<ReleaseData>`, which
            // makes Home re-walk every snapshot and rebuild `derived`,
            // producing visible UI lag during refresh).
            let flushThreshold = 60
            let flushInterval: TimeInterval = 4.0
            var pendingReleases: [FetchedRelease] = []
            var lastFlushAt = Date()

            var failures: [String] = []
            var resolvedCatalogIDs: [String: String] = [:]
            var resolvedArtworkURLs: [String: URL] = [:]
            var checkedCount = 0
            var lastProgressDispatch = Date.distantPast
            // Per-artist retry counter, keyed by providerID. Capped at 1
            // retry on the first refresh (the path most prone to flake);
            // incremental refreshes don't retry — user can re-trigger.
            let maxRetriesPerInput = isFirstRefresh ? 1 : 0
            var retryAttempts: [String: Int] = [:]

            await withTaskGroup(of: ArtistFetchOutcome.self) { group in
                var nextIndex = 0
                var inFlight = 0
                // AIMD state. Halve cap on rate-limit; +1 every 10 clean outcomes.
                var currentCap = initialCap
                var cleanStreak = 0

                func enqueue(_ input: ArtistFetchInput) {
                    let cached = input.catalogArtistID.flatMap { preResolved[$0] }
                    group.addTask {
                        let started = Date()
                        let outcome: ArtistFetchOutcome
                        switch MusicProvider.fromStoredName(input.provider) {
                        case .appleMusic:
                            outcome = await appleService.fetchOne(
                                input,
                                preResolvedArtist: cached,
                                storefront: storefront
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
                    enqueue(inputs[nextIndex])
                    inFlight += 1
                    nextIndex += 1
                }

                while let outcome = await group.next() {
                    if Task.isCancelled { break }

                    inFlight -= 1

                    // Failed outcome: if we have retries left for this input,
                    // requeue it instead of counting it. Doesn't bump
                    // checkedCount yet — that happens when the retry returns
                    // (or this is the final attempt).
                    let providerID = outcome.input.providerID
                    let attemptsSoFar = retryAttempts[providerID] ?? 0
                    let shouldRetry = outcome.errorMessage != nil
                        && attemptsSoFar < maxRetriesPerInput
                        && !Task.isCancelled
                    if shouldRetry {
                        retryAttempts[providerID] = attemptsSoFar + 1
                        Log.v("[Refresh] retrying \(outcome.input.name) (attempt \(attemptsSoFar + 2))")
                        enqueue(outcome.input)
                        inFlight += 1
                        // Don't refill from `inputs` this iteration — the retry
                        // re-uses the slot.
                        continue
                    }

                    checkedCount += 1
                    pendingReleases.append(contentsOf: outcome.releases)
                    if let catID = outcome.catalogArtistID {
                        resolvedCatalogIDs[providerID] = catID
                    }
                    if let art = outcome.artworkURL {
                        resolvedArtworkURLs[providerID] = art
                    }
                    if let err = outcome.errorMessage {
                        failures.append("\(outcome.input.name): \(err)")
                    }

                    // Streaming flush: enough releases buffered, or it's
                    // been long enough since the last flush. Awaiting here
                    // briefly blocks the loop, but the bounded fetch +
                    // small save is fast (typically <50ms) and the user
                    // perceived win — feed filling in live — is huge.
                    let nowFlushCheck = Date()
                    if pendingReleases.count >= flushThreshold
                        || nowFlushCheck.timeIntervalSince(lastFlushAt) >= flushInterval {
                        let batch = pendingReleases
                        pendingReleases.removeAll(keepingCapacity: true)
                        lastFlushAt = nowFlushCheck
                        await releaseService.applyStreamingBatch(
                            releases: batch,
                            state: &streamingState,
                            actor: upsertActor,
                            now: Date()
                        )
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
                        enqueue(inputs[nextIndex])
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

            // Final streaming flush: anything still buffered from the last
            // few outcomes goes in one last bounded upsert before finalize.
            if !pendingReleases.isEmpty {
                let batch = pendingReleases
                pendingReleases.removeAll(keepingCapacity: false)
                await releaseService.applyStreamingBatch(
                    releases: batch,
                    state: &streamingState,
                    actor: upsertActor,
                    now: Date()
                )
            }

            // Apply tracked-artist metadata + finalize on main. The metadata
            // write fires one @Query; finalize fires another after building
            // notification specs + widget snapshot + playlist candidates.
            let resolvedCatalogIDsSnapshot = resolvedCatalogIDs
            let resolvedArtworkURLsSnapshot = resolvedArtworkURLs
            await MainActor.run {
                releaseService.applyArtistMetadata(
                    resolvedCatalogIDs: resolvedCatalogIDsSnapshot,
                    resolvedArtworkURLs: resolvedArtworkURLsSnapshot,
                    trackedArtists: trackedArtists,
                    modelContext: modelContext,
                    now: Date()
                )
            }

            let summary = await releaseService.finalizeRefresh(
                state: streamingState,
                failures: failures,
                checkedArtists: checkedCount,
                totalArtists: totalCount,
                trackedArtists: trackedArtists,
                modelContext: modelContext,
                scheduleNotifications: true,
                notificationHour: notificationHour,
                notificationMinute: notificationMinute
            )

            // Catalog IDs that were freshly resolved during this refresh can
            // expose duplicate artists that the launch-time dedup couldn't
            // see (because the rows hadn't had `catalogArtistID` set yet).
            // Run dedup once more so those duplicates collapse before the
            // user notices a "via X" row from an untracked-looking artist.
            await MainActor.run {
                CloudSyncDeduplicator.run(in: modelContext)
            }

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

    /// Run `operation` against a timeout, returning `fallback` if the
    /// timeout fires first. Used to keep pre-resolve from pinning the
    /// refresh in `.warming` when itunescloudd is slow.
    private static func raceWithTimeout<T: Sendable>(
        seconds: Double,
        fallback: T,
        operation: @Sendable @escaping () async -> T
    ) async -> T {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? fallback
        }
    }

    /// Kick `MusicSubscription.current` so any later catalog calls find a
    /// warm identity, but never block on it. The call can hang
    /// indefinitely when iTunes account services are stalled (the device
    /// keeps logging `-7013 "Client is not entitled to access account
    /// store"`) and it doesn't honor structured-concurrency cancellation
    /// — so the previous `withTaskGroup` race would deadlock on the
    /// implicit "wait for children" at the end of the group body.
    ///
    /// Fire-and-forget instead. We sleep the timeout window so warmup
    /// *might* complete before the rest of the refresh proceeds, then
    /// return regardless. The detached task continues in the background
    /// and resolves whenever the system finally responds (or gets torn
    /// down on app exit). Worst case we lose the warmup optimization;
    /// the actual catalog fetches do not depend on a subscription.
    /// Block until MusicKit authorization is in a settled state (.authorized
    /// / .denied / .restricted). Returns immediately when already settled;
    /// when `.notDetermined`, awaits `MusicAuthorization.request()` which
    /// shows the system prompt and resolves once the user picks. Prevents
    /// any catalog / storefront call from firing while auth is in flight
    /// (which used to surface as "Failed to fetch current country code …
    /// notDetermined" log spam during auto-refresh-on-launch).
    private static func awaitMusicAuthorizationResolved() async {
        if MusicAuthorization.currentStatus == .notDetermined {
            _ = await MusicAuthorization.request()
        }
    }

    private static func warmUpMusicKitIdentity(timeout seconds: Double) async {
        Task.detached(priority: .utility) {
            _ = try? await MusicSubscription.current
        }
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
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
