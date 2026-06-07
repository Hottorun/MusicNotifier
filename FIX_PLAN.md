# MusicNotifier Performance/UX Plan

All items below to be implemented. Numbering is execution order within each tier.

## Tier 1 — Fetching speed (release refresh)

1. **Drop MusicKit `.with([.albums])` from primary path.** Use REST `sort=-releaseDate` as the primary; fall back to MusicKit only when REST returns 0 rows. (`AppleMusicReleaseService.fetchPrimaryAlbums`, `fetchOne`)
2. **Adaptive `maxConcurrent`.** Start at 6 in `RefreshCoordinator`; on 429-detection halve, recover on 10 successful responses (AIMD).
3. **Hoist REST decoder allocations.** Static `DateFormatter` (or `ISO8601DateFormatter`) + shared `JSONDecoder` instead of one-per-call. (`AppleMusicReleaseService.swift:741–767`)
4. **Fix rate-limit detection.** Inspect actual HTTP status from `MusicDataRequest` response instead of string-matching `"Unexpected character 'A'"`. (`withRetry`/`looksLikeRateLimit`)
5. **Unify background and foreground refresh paths.** `BackgroundRefreshScheduler` calls the legacy serial `refreshReleases` (with 150ms inter-artist sleep at line 317). Route it through the same parallel coordinator code.
6. **Parallelize videos + concerts with releases.** Hand the fetch services value-type inputs + container so they can run alongside the release fetch instead of after it.

## Tier 2 — Operation smoothness

7. **Coalesce widget reloads.** `WidgetCenter.shared.reloadAllTimelines()` is called on every refresh start/end. Throttle to ≤1 per 5s.
8. **`ImageCache` cost-based eviction.** Replace `countLimit = 800` with `totalCostLimit = 100 MB` and pass `cost:` (bytes) on store.
9. **Dedicated artwork `URLCache`.** Install 200MB disk cache at app launch so cold-launches don't redownload art.
10. **Debounce SwiftData saves on context-menu toggles.** Replace per-toggle `try? modelContext.save()` with a 250ms trailing-edge debouncer + flush on scenePhase change.
11. **Off-main `computeDerived` / `makeSnapshot`.** Pass a Sendable projection of `storedReleases` and run the walk on a detached task; deliver result back to MainActor.
12. **Memoize `artistSummaries`.** Roll into the existing `cachedSnapshot` so it doesn't recompute on every render.

## Tier 3 — Popups / sheets

13. **Prefetch tracklists for top ~30 feed items**, not 10. Also prefetch on cell `.onAppear` for incremental coverage.
14. **AlbumView skeleton timing.** Don't flip `tracksLoadAttempted = true` until either tracks arrive OR ≥300ms passed, so the cache-miss empty state doesn't flash.
15. **Faster context-menu preview.** Drop the wrapping `NavigationLink` in the preview — replace with a tap handler that defers the push.
16. **Lazy SettingsView sections.** Wrap heavy Section bodies in a `LazyView { }` helper so first-open instantiates only the visible chunk.
17. **`presentationBackgroundInteraction(.enabled)`** on the refresh detail sheet.

## Tier 4 — UX

18. **Replace custom pull-to-refresh DragGesture with `.refreshable`** on Home (resolves conflict with `.searchable`).
19. **Stale-aware auto-refresh.** Skip auto-refresh when `lastSuccessfulRefreshAt < 30 min` ago.
20. **Animate layout chip icon** via `.contentTransition(.symbolEffect(.replace))`.
21. **Haptic on "Mark all as read"** completion.
22. **Per-phase progress for videos + concerts.** Use existing intra-service fan-out to publish `(checked/total)` instead of indeterminate spinner.
23. **"Last refreshed: N min ago"** indicator in Home header when idle.
24. **Single end-of-refresh save** inside `ReleaseUpsertActor` — only propagate to `@Query` once, not per side-effect section.
