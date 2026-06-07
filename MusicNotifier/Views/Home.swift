//
//  Main.swift
//  MusicNotifier
//
//  Created by Dimitris Kern on 28.07.25.
//

import SwiftUI
import SwiftData
import UIKit

private struct EmptyStateAction {
    let label: String
    let icon: String
    let action: () -> Void
}

private enum ReleaseFeedFilter: String, CaseIterable, Identifiable {
    // "All" was redundant once you had New + Seen + Upcoming covering every state;
    // the feed defaults to Releases (= New + Seen merged with section dividers).
    case releases = "Releases"
    case upcoming = "Upcoming"

    var id: String { rawValue }
}

private enum ReleaseKindFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case albums = "Albums"
    case eps = "EPs"
    case singles = "Singles"

    var id: String { rawValue }
}

struct HomeView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(RefreshCoordinator.self) private var refreshCoordinator
    @Query(filter: #Predicate<ArtistData> { artist in
        artist.isTracked
    }, sort: \ArtistData.name) private var trackedArtists: [ArtistData]

    /// Memoized membership sets, updated by `refreshTrackedSets()` on tracked-roster
    /// changes. Previously these were computed properties that rebuilt the Set
    /// on every access — row methods (called per visible release) each triggered
    /// a fresh O(N) walk over the tracked roster.
    @State private var trackedArtistIDs: Set<String> = []
    @State private var labelArtistIDs: Set<String> = []
    /// providerID → tracked artist name. Used by the row to surface a
    /// "via <name>" hint when a release's credited artist string doesn't
    /// already mention the artist the user follows (typical for features /
    /// collabs where the tracked artist is buried later in the credits).
    @State private var trackedArtistNamesByID: [String: String] = [:]

    private func refreshTrackedSets() {
        var tracked: Set<String> = []
        var labels: Set<String> = []
        var names: [String: String] = [:]
        for artist in trackedArtists {
            tracked.insert(artist.providerID)
            names[artist.providerID] = artist.name
            if artist.kind == "label" { labels.insert(artist.providerID) }
        }
        if tracked != trackedArtistIDs { trackedArtistIDs = tracked }
        if labels != labelArtistIDs { labelArtistIDs = labels }
        if names != trackedArtistNamesByID { trackedArtistNamesByID = names }
    }

    /// Returns the tracked artist's name when the credited string doesn't
    /// already make it obvious. Suppressed in two cases:
    ///   1. Solo release — credited string equals the tracked artist's name.
    ///   2. Pure tracked-only collab — every artist mentioned in the credit
    ///      ("Trevor Spitta & Keshore") is one the user already follows, so
    ///      there's no disambiguation left to do.
    /// Shown otherwise — including collabs where one credit is tracked and
    /// another isn't ("Katy Perry & Chief Keef" with only Chief Keef tracked).
    private func viaTrackedArtistName(for release: ReleaseData) -> String? {
        guard let name = trackedArtistNamesByID[release.artistProviderID] else { return nil }
        let credited = release.artistName.trimmingCharacters(in: .whitespacesAndNewlines)
        if credited.caseInsensitiveCompare(name) == .orderedSame { return nil }
        if allCreditedArtistsTracked(credited) { return nil }
        return name
    }

    /// Splits a credited-artist string into components and checks whether
    /// every component matches a tracked artist's name. Splitters cover the
    /// common Apple Music conventions: " & ", ", ", " feat. ", " ft. ",
    /// " featuring ", " x ", " X ", " and ", and parenthetical "(feat. ...)"
    /// suffixes (which we strip before splitting).
    private func allCreditedArtistsTracked(_ credited: String) -> Bool {
        var working = credited
        // Strip "(feat. X)" / "[feat. X]" / "(with X)" — keeps the primary
        // credit list clean before we split on ampersand/comma.
        let parens = #"\s*[\(\[](?:feat\.?|featuring|with)\s[^\)\]]+[\)\]]"#
        if let regex = try? NSRegularExpression(pattern: parens, options: [.caseInsensitive]) {
            let range = NSRange(working.startIndex..., in: working)
            working = regex.stringByReplacingMatches(in: working, options: [], range: range, withTemplate: "")
        }
        let separators: [String] = [" & ", ", ", " feat. ", " ft. ", " featuring ", " x ", " X ", " and "]
        var pieces: [String] = [working]
        for sep in separators {
            pieces = pieces.flatMap { $0.components(separatedBy: sep) }
        }
        let trimmed = pieces
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !trimmed.isEmpty else { return false }
        let trackedNames = Set(trackedArtistNamesByID.values.map { $0.lowercased() })
        for piece in trimmed where !trackedNames.contains(piece.lowercased()) {
            return false
        }
        return true
    }
    @Query(sort: \ReleaseData.firstSeenAt, order: .reverse) private var storedReleases: [ReleaseData]
    @AppStorage(AppSettings.autoRefreshOnLaunch) private var autoRefreshOnLaunch = true
    @AppStorage(AppSettings.lastSuccessfulRefreshAt) private var lastSuccessfulRefreshAt: Double = 0
    @AppStorage(AppSettings.releaseNotificationHour) private var releaseNotificationHour = 8
    @AppStorage(AppSettings.releaseNotificationMinute) private var releaseNotificationMinute = 0
    @AppStorage(AppSettings.homeReleaseKindFilter) private var releaseKindFilterRaw = ReleaseKindFilter.all.rawValue
    @AppStorage("homeFeedFilter") private var feedFilterRaw = ReleaseFeedFilter.releases.rawValue
    // Global per-kind visibility from Settings → View. A kind toggled off here
    // is hidden everywhere in the app, regardless of the inline filter chip.
    @AppStorage(AppSettings.showAlbums) private var showAlbums = true
    @AppStorage(AppSettings.showSingles) private var showSingles = true
    @AppStorage(AppSettings.showEPs) private var showEPs = true
    @AppStorage(AppSettings.showLiveAlbums) private var showLiveAlbums = true
    @AppStorage(AppSettings.showCompilations) private var showCompilations = true
    @AppStorage(AppSettings.showRemixes) private var showRemixes = true
    /// "hybrid" — new releases as a grid, past as compact rows (the default)
    /// "list" — everything as compact rows
    /// "grid" — everything as a 2-column grid
    @AppStorage("homeFeedLayout") private var feedLayoutRaw: String = "hybrid"
    @State private var hasAutoRefreshed = false
    @State private var showingSettings = false
    @State private var showingRefreshDetail = false
    @State private var releaseSearchText = ""
    /// Debounced mirror of releaseSearchText. `derived` reads this instead of the
    /// raw search text so the (potentially thousands of releases) filter loop
    /// doesn't re-run on every keystroke.
    @State private var debouncedSearchText = ""
    @State private var searchDebounceTask: Task<Void, Never>?
    @State private var showingMarkAllConfirm = false
    /// Past releases default to the most recent 3 month buckets so feeds with
    /// hundreds of stored releases don't render every row up-front (the
    /// non-lazy outer VStack means rows are instantiated eagerly). User taps
    /// "Show older" to expand the rest.
    @State private var showAllPastMonths = false
    private let defaultPastMonthCount = 2

    private var feedFilter: ReleaseFeedFilter {
        ReleaseFeedFilter(rawValue: feedFilterRaw) ?? .releases
    }

    private var isRefreshing: Bool { refreshCoordinator.isRefreshing }
    // Intentionally no `refreshProgress` getter here — reading the live progress
    // value from HomeView would couple the body's invalidation to every progress
    // tick (~6 Hz). The progress data is consumed by `RefreshProgressBar`
    // instead, so HomeView only re-renders on the much rarer `isRefreshing`
    // flips. See the bar view below.
    private var refreshMessage: String? { refreshCoordinator.message }

    /// Single-pass derivation of every list bucket the body needs. Previously
    /// the body walked the release set five-plus times per render (releases,
    /// visibleReleases, newReleases, pastAndSeen, unknownDate, upcomingCount,
    /// unreadCount). This batches everything into one walk.
    private struct DerivedReleases {
        var newReleases: [ReleaseData] = []
        var pastAndSeen: [ReleaseData] = []
        var unknownDate: [ReleaseData] = []
        var upcomingCount = 0
        var unreadCount = 0
        var visibleCount = 0
        var hasAnyTrackedRelease = false
    }

    /// Cached `DerivedReleases` so the feed body can render instantly using
    /// whatever bucketing was true at last compute. A `.task(id:)` driven by
    /// `derivedKey` recomputes this *after* the first frame paints, so the
    /// O(N) walk over all releases never blocks rendering. Without this the
    /// `@Query` invalidation at refresh phase transitions caused multi-frame
    /// hitches as the walk ran inline.
    @State private var cachedDerived = DerivedReleases()

    /// Composite identity key for `.task(id:)`. When any of these changes, the
    /// derived recompute task fires. SwiftData @Query updates change
    /// `storedReleases.count`; toggling `isSeen` or `dismissedAt` on an
    /// individual release won't change the count but the view's own
    /// onChange/state side effects refresh the cache where needed.
    private struct DerivedKey: Hashable {
        var releaseCount: Int
        var trackedCount: Int
        var search: String
        var kindFilter: String
        var showAlbums: Bool
        var showSingles: Bool
        var showEPs: Bool
        var showLiveAlbums: Bool
        var showCompilations: Bool
        var showRemixes: Bool
    }

    private var derivedKey: DerivedKey {
        DerivedKey(
            releaseCount: storedReleases.count,
            trackedCount: trackedArtistIDs.count,
            search: debouncedSearchText,
            kindFilter: releaseKindFilterRaw,
            showAlbums: showAlbums,
            showSingles: showSingles,
            showEPs: showEPs,
            showLiveAlbums: showLiveAlbums,
            showCompilations: showCompilations,
            showRemixes: showRemixes
        )
    }

    /// Sendable projection used for the off-main filter+sort. Carries only the
    /// scalar properties the derivation reads — no `@Model` references cross
    /// the actor boundary.
    private struct ReleaseSnapshot: Sendable {
        let id: PersistentIdentifier
        let artistProviderID: String
        let title: String
        let artistName: String
        let releaseDate: Date?
        let firstSeenAt: Date
        let isUpcoming: Bool
        let isSeen: Bool
        let isDismissed: Bool
        let hasUnknownReleaseDate: Bool
        let kind: ReleaseKind
    }

    /// Bucketed IDs produced off-main; resolved back to `ReleaseData` on MainActor.
    private struct DerivedIDs: Sendable {
        var newReleaseIDs: [PersistentIdentifier] = []
        var pastAndSeenIDs: [PersistentIdentifier] = []
        var unknownDateIDs: [PersistentIdentifier] = []
        var upcomingCount = 0
        var unreadCount = 0
        var visibleCount = 0
        var hasAnyTrackedRelease = false
    }

    private func computeDerived() -> DerivedReleases {
        // Snapshot inputs on MainActor (cheap scalar reads), then run the
        // filter + sort on a detached executor so the main thread isn't
        // tied up walking thousands of releases on large libraries.
        let snapshots = storedReleases.map { release in
            ReleaseSnapshot(
                id: release.persistentModelID,
                artistProviderID: release.artistProviderID,
                title: release.title,
                artistName: release.artistName,
                releaseDate: release.releaseDate,
                firstSeenAt: release.firstSeenAt,
                isUpcoming: release.isUpcoming,
                isSeen: release.isSeen,
                isDismissed: release.dismissedAt != nil,
                hasUnknownReleaseDate: release.hasUnknownReleaseDate,
                kind: release.kind
            )
        }
        let ids = trackedArtistIDs
        let trimmedSearch = debouncedSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let kindFilter = releaseKindFilter
        let visibleKinds = visibleKindsSet()

        let derivedIDs = Self.computeDerivedIDsSync(
            snapshots: snapshots,
            trackedIDs: ids,
            trimmedSearch: trimmedSearch,
            kindFilter: kindFilter,
            visibleKinds: visibleKinds
        )

        // Resolve IDs back to ReleaseData references — single dict build,
        // then O(1) lookups. Cheaper than re-walking storedReleases per bucket.
        let lookup = Dictionary(storedReleases.map { ($0.persistentModelID, $0) }, uniquingKeysWith: { lhs, _ in lhs })
        var out = DerivedReleases()
        out.upcomingCount = derivedIDs.upcomingCount
        out.unreadCount = derivedIDs.unreadCount
        out.visibleCount = derivedIDs.visibleCount
        out.hasAnyTrackedRelease = derivedIDs.hasAnyTrackedRelease
        out.newReleases = derivedIDs.newReleaseIDs.compactMap { lookup[$0] }
        out.pastAndSeen = derivedIDs.pastAndSeenIDs.compactMap { lookup[$0] }
        out.unknownDate = derivedIDs.unknownDateIDs.compactMap { lookup[$0] }
        return out
    }

    /// Async variant — actually moves the filter+sort off MainActor. Used by
    /// `.task(id:)`; the sync wrapper above stays available for the call sites
    /// (context menu) that want immediate cache refresh after a toggle.
    private func computeDerivedAsync() async -> DerivedReleases {
        let snapshots = storedReleases.map { release in
            ReleaseSnapshot(
                id: release.persistentModelID,
                artistProviderID: release.artistProviderID,
                title: release.title,
                artistName: release.artistName,
                releaseDate: release.releaseDate,
                firstSeenAt: release.firstSeenAt,
                isUpcoming: release.isUpcoming,
                isSeen: release.isSeen,
                isDismissed: release.dismissedAt != nil,
                hasUnknownReleaseDate: release.hasUnknownReleaseDate,
                kind: release.kind
            )
        }
        let ids = trackedArtistIDs
        let trimmedSearch = debouncedSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let kindFilter = releaseKindFilter
        let visibleKinds = visibleKindsSet()

        let derivedIDs = await Task.detached(priority: .userInitiated) {
            Self.computeDerivedIDsSync(
                snapshots: snapshots,
                trackedIDs: ids,
                trimmedSearch: trimmedSearch,
                kindFilter: kindFilter,
                visibleKinds: visibleKinds
            )
        }.value

        let lookup = Dictionary(storedReleases.map { ($0.persistentModelID, $0) }, uniquingKeysWith: { lhs, _ in lhs })
        var out = DerivedReleases()
        out.upcomingCount = derivedIDs.upcomingCount
        out.unreadCount = derivedIDs.unreadCount
        out.visibleCount = derivedIDs.visibleCount
        out.hasAnyTrackedRelease = derivedIDs.hasAnyTrackedRelease
        out.newReleases = derivedIDs.newReleaseIDs.compactMap { lookup[$0] }
        out.pastAndSeen = derivedIDs.pastAndSeenIDs.compactMap { lookup[$0] }
        out.unknownDate = derivedIDs.unknownDateIDs.compactMap { lookup[$0] }
        return out
    }

    /// Pure value-type walk — safe to run off any actor. Filters, buckets,
    /// and sorts the snapshot list using the same rules the inline path used.
    nonisolated private static func computeDerivedIDsSync(
        snapshots: [ReleaseSnapshot],
        trackedIDs: Set<String>,
        trimmedSearch: String,
        kindFilter: ReleaseKindFilter,
        visibleKinds: Set<ReleaseKind>
    ) -> DerivedIDs {
        var out = DerivedIDs()
        var newSnaps: [ReleaseSnapshot] = []
        var pastSnaps: [ReleaseSnapshot] = []
        var unknownSnaps: [ReleaseSnapshot] = []

        for s in snapshots {
            guard trackedIDs.contains(s.artistProviderID) else { continue }
            out.hasAnyTrackedRelease = true
            if s.isUpcoming { out.upcomingCount += 1 }
            if !s.isSeen && !s.isDismissed { out.unreadCount += 1 }

            guard !s.isDismissed else { continue }
            guard !s.isUpcoming else { continue }
            guard visibleKinds.contains(s.kind) else { continue }
            guard releaseMatchesKindFilterStatic(s.kind, filter: kindFilter) else { continue }
            if !trimmedSearch.isEmpty {
                let inTitle = s.title.localizedCaseInsensitiveContains(trimmedSearch)
                let inArtist = s.artistName.localizedCaseInsensitiveContains(trimmedSearch)
                if !inTitle && !inArtist { continue }
            }

            out.visibleCount += 1
            if s.hasUnknownReleaseDate { unknownSnaps.append(s) }
            else if !s.isSeen { newSnaps.append(s) }
            else { pastSnaps.append(s) }
        }

        let sortDesc: (ReleaseSnapshot, ReleaseSnapshot) -> Bool = { lhs, rhs in
            (lhs.releaseDate ?? lhs.firstSeenAt) > (rhs.releaseDate ?? rhs.firstSeenAt)
        }
        newSnaps.sort(by: sortDesc)
        pastSnaps.sort(by: sortDesc)
        unknownSnaps.sort(by: sortDesc)
        out.newReleaseIDs = newSnaps.map(\.id)
        out.pastAndSeenIDs = pastSnaps.map(\.id)
        out.unknownDateIDs = unknownSnaps.map(\.id)
        return out
    }

    nonisolated private static func releaseMatchesKindFilterStatic(_ kind: ReleaseKind, filter: ReleaseKindFilter) -> Bool {
        switch filter {
        case .all: return true
        case .albums: return kind == .album || kind == .compilation || kind == .liveAlbum
        case .eps: return kind == .ep
        case .singles: return kind == .single || kind == .remix
        }
    }

    private func visibleKindsSet() -> Set<ReleaseKind> {
        var set: Set<ReleaseKind> = []
        if showAlbums { set.insert(.album) }
        if showSingles { set.insert(.single) }
        if showEPs { set.insert(.ep) }
        if showLiveAlbums { set.insert(.liveAlbum) }
        if showCompilations { set.insert(.compilation) }
        if showRemixes { set.insert(.remix) }
        return set
    }

    private var releaseKindFilter: ReleaseKindFilter {
        ReleaseKindFilter(rawValue: releaseKindFilterRaw) ?? .all
    }

    var body: some View {
        // Compute once per render and reuse — see DerivedReleases.
        // Render from the cached projection. `.task(id: derivedKey)` keeps it
        // fresh after frames paint, so the heavy walk doesn't block render.
        let derived = cachedDerived
        return NavigationStack {
            ScrollView {
                // LazyVStack so only the on-screen sections of the feed
                // (header, hero, current month) are instantiated when the
                // tab appears. On a large library the eager VStack here was
                // building hundreds of release rows before SwiftUI could
                // swap tabs, causing the multi-second tab-switch freeze.
                LazyVStack(spacing: 16) {
                    header(derived: derived)

                    // Only surface the refresh message when it represents a failure that
                    // the user can retry. Success summaries ("Checked 83/83… Found N") are
                    // noisy and live in the toolbar icon state anyway.
                    if let refreshMessage, !isRefreshing, isRefreshFailure(refreshMessage) {
                        HStack(spacing: 8) {
                            Text(refreshMessage)
                                .font(.footnote)
                                .foregroundStyle(AppTheme.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Button {
                                startRefresh()
                            } label: {
                                Label("Retry", systemImage: "arrow.clockwise")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(AppTheme.accent)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 20)
                    }

                    if let entitlementFailureMessage = refreshCoordinator.message,
                       isMusicKitFailure(entitlementFailureMessage), !derived.hasAnyTrackedRelease {
                        actionableEmptyState(
                            title: "Can't reach Apple Music",
                            message: "MusicKit isn't authorized for this app. Open the iOS Settings and grant access, then retry.",
                            systemImage: "exclamationmark.icloud",
                            primary: EmptyStateAction(label: "Retry", icon: "arrow.clockwise") {
                                startRefresh()
                            },
                            secondary: EmptyStateAction(label: "Open Settings", icon: "gear") {
                                if let url = URL(string: UIApplication.openSettingsURLString) {
                                    UIApplication.shared.open(url)
                                }
                            }
                        )
                    } else if trackedArtists.isEmpty {
                        actionableEmptyState(
                            title: "No artists tracked",
                            message: "Import your Apple Music library or search for an artist to follow their releases.",
                            systemImage: "bell.slash",
                            primary: nil,
                            secondary: nil
                        )
                    } else if derived.visibleCount == 0 {
                        actionableEmptyState(
                            title: "Nothing here yet",
                            message: "Tap refresh to look for new music from your tracked artists.",
                            systemImage: "opticaldisc",
                            primary: EmptyStateAction(label: "Check now", icon: "arrow.clockwise") {
                                startRefresh()
                            },
                            secondary: nil
                        )
                    } else {
                        if !derived.newReleases.isEmpty {
                            // Hybrid mode keeps the punchy grid for New + compact
                            // rows for Past; the other two modes are uniform.
                            if feedLayoutRaw == "hybrid" {
                                heroNewReleasesSection(derived.newReleases)
                            } else {
                                releaseGroup("New", releases: derived.newReleases)
                            }
                        }
                        pastReleasesByMonth(derived.pastAndSeen)
                        releaseGroup("Date Unknown", releases: derived.unknownDate)
                    }

                    Spacer(minLength: 110)
                }
                .padding(.top, 4)
            }
            .navigationTitle("Feed")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    headerActionButtons(derived: derived)
                }
            }
            .appScreenBackground()
            // Value-based navigation so AlbumView (with its @StateObject preview
            // player and queries) is only instantiated when the user actually
            // pushes a release, not eagerly for every cell in the feed.
            .navigationDestination(for: ReleaseData.self) { release in
                AlbumView(release: release)
            }
            // System search bar — hidden at rest, revealed by a pull-down
            // gesture at the top of the scroll view (matches Videos tab).
            .searchable(text: $releaseSearchText, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search releases")
            .onChange(of: trackedArtists.count) { _, _ in refreshTrackedSets() }
            .onAppear {
                refreshTrackedSets()
                // User likely just navigated back from AlbumView where they
                // may have toggled a release's seen state. Recompute derived
                // so the feed shows the up-to-date bucketing on return.
                cachedDerived = computeDerived()
            }
            .onChange(of: releaseSearchText) { _, newValue in
                // Empty → flip immediately so clearing the field shows the full feed
                // without a stutter. Non-empty → 220ms debounce so each keystroke
                // doesn't kick off a fresh derived-walk on every release row.
                searchDebounceTask?.cancel()
                if newValue.isEmpty {
                    debouncedSearchText = ""
                    return
                }
                searchDebounceTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 220_000_000)
                    if Task.isCancelled { return }
                    debouncedSearchText = newValue
                }
            }
            // Standard `.refreshable` integrates cleanly with `.searchable`
            // and gives the user the platform pull-to-refresh affordance.
            // The previous custom DragGesture raced with the search bar's
            // pull-to-reveal — overloading the same gesture for both made
            // the search field surface unintentionally during pulls.
            .refreshable {
                guard !refreshCoordinator.isRefreshing, !trackedArtists.isEmpty else { return }
                startRefresh()
                // Hold the system spinner briefly so the user feels the gesture
                // landed even though our refresh runs detached.
                try? await Task.sleep(nanoseconds: 800_000_000)
            }
            .task(id: derivedKey) {
                // Defer the heavy `derived` walk until after the body's first
                // frame has rendered, then run it off-MainActor entirely
                // (via `computeDerivedAsync`). The detached executor walks
                // the Sendable snapshot list and returns bucketed IDs; we
                // only resolve back to `ReleaseData` refs on main.
                await Task.yield()
                let next = await computeDerivedAsync()
                cachedDerived = next
            }
            .task {
                // Warm the artwork cache for everything visible — by the time the
                // user scrolls or taps into a release, covers are already decoded
                // and stored, so navigation paints in the first frame.
                ImagePrefetcher.prefetch(
                    (derived.newReleases + derived.pastAndSeen).prefix(60).map(\.artworkURL)
                )
                ImagePrefetcher.prefetch(trackedArtists.prefix(80).map(\.artworkURL))

                // Warm the Apple Music library index so the first album tap
                // doesn't pay the ~1.7s MusicLibraryRequest cost on the page
                // it's opening. Fire-and-forget — failure just means the first
                // album falls back to building the index on-demand.
                Task.detached(priority: .utility) {
                    _ = await LibraryMembershipIndex.shared.get()
                    TrackCache.shared.prepare()
                }
                Task {
                    _ = await UserPlaylistsCache.shared.get()
                }

                // Prefetch tracklists for the top releases visible in the
                // feed so the user's first tap is already a cache hit. Caps
                // concurrency and skips anything already cached, so this is
                // cheap on repeat launches. Bumped from 10 → 30 so most of
                // the visible grid is warmed before the user starts scrolling.
                let topProviderIDs = (derived.newReleases + derived.pastAndSeen)
                    .prefix(30)
                    .map(\.providerID)
                Task.detached(priority: .utility) {
                    await TrackPrefetcher.prefetchBatch(providerIDs: topProviderIDs)
                }

            }
            // One-shot auto-refresh keyed on a stable identity. The `id:` ensures the
            // task body only fires once per HomeView lifetime even if SwiftUI tears down
            // and recreates the `.task` (e.g. when an unrelated piece of state flips).
            .task(id: "autoRefreshOnLaunch") {
                guard autoRefreshOnLaunch, !hasAutoRefreshed, !trackedArtists.isEmpty else {
                    return
                }
                hasAutoRefreshed = true
                // Stale-aware: skip the network round-trip if we refreshed
                // less than 30 minutes ago. Opening the app frequently
                // (e.g. via notification) was hammering Apple Music with
                // back-to-back refreshes that returned the same data.
                let lastSuccess = UserDefaults.standard.double(forKey: AppSettings.lastSuccessfulRefreshAt)
                if lastSuccess > 0 {
                    let age = Date().timeIntervalSince1970 - lastSuccess
                    if age < 30 * 60 { return }
                }
                startRefresh()
            }
            .confirmationDialog(
                "Mark all \(derived.unreadCount) releases as read?",
                isPresented: $showingMarkAllConfirm,
                titleVisibility: .visible
            ) {
                Button("Mark all as read") {
                    applyMarkAllAsSeen()
                }
                Button("Cancel", role: .cancel) {}
            }
            .sheet(isPresented: $showingSettings) {
                NavigationStack {
                    SettingsView()
                }
                .environment(refreshCoordinator)
            }
            .sheet(isPresented: $showingRefreshDetail) {
                RefreshDetailSheet(isPresented: $showingRefreshDetail)
                    .environment(refreshCoordinator)
                    .presentationDetents([.height(220)])
                    .presentationDragIndicator(.visible)
                    .presentationBackground(AppTheme.background)
                    // Let the user scroll the feed behind the small refresh
                    // card without dismissing it — feels much less modal.
                    .presentationBackgroundInteraction(.enabled(upThrough: .height(220)))
            }
            .onChange(of: refreshCoordinator.isRefreshing) { _, newValue in
                // Auto-dismiss the detail sheet when the refresh ends so the
                // user doesn't have to manually close a stale card.
                if !newValue && showingRefreshDetail {
                    showingRefreshDetail = false
                }
            }
        }
    }

    private func header(derived: DerivedReleases) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // Unread count is the only feed-relevant metric here — artist and
            // upcoming totals belong to their own tabs. The "Feed" title now
            // lives in the native nav bar so it collapses to a small pill on
            // scroll (matches the Videos tab).
            HStack(spacing: 10) {
                inlineMetric(value: derived.unreadCount, label: "unread", color: AppTheme.yellow)
                if !isRefreshing, let last = lastRefreshedLabel {
                    Text("·")
                        .font(.caption2)
                        .foregroundStyle(AppTheme.secondary)
                    Text(last)
                        .font(.caption)
                        .foregroundStyle(AppTheme.secondary)
                        .accessibilityLabel("Last refreshed \(last)")
                }
                Spacer()
                layoutToggleChip
                typeFilterChip
            }

            // Progress is now shown by the toolbar refresh icon (which fills
            // as a circular arc) — much less screen real-estate. Tap the
            // toolbar icon while refreshing to bring up the full detail card
            // (current artist, X/Y count, stop button).
        }
        .padding(.horizontal, 18)
    }

    /// Search / refresh / more buttons, rendered inline at the right of the
    /// "Feed" title row (previously lived in the nav bar toolbar).
    @ViewBuilder
    private func headerActionButtons(derived: DerivedReleases) -> some View {
        HStack(spacing: 10) {
            ToolbarRefreshButton(
                isIdleDisabled: trackedArtists.isEmpty,
                onIdleTap: { startRefresh() },
                onActiveTap: { showingRefreshDetail = true }
            )

            Menu {
                Button {
                    markAllAsSeen()
                } label: {
                    Label("Mark all as read", systemImage: "checkmark.circle")
                }
                .disabled(derived.unreadCount == 0)
                Button {
                    showingSettings = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(AppTheme.primaryText)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("More")
        }
    }

    /// Three-state layout toggle: hybrid → list → grid → hybrid.
    private var layoutToggleChip: some View {
        Button {
            // Don't wrap the layout flip in `withAnimation` — that would animate
            // every visible release row's geometry change at once, which is a
            // significant frame-budget hit on large feeds. The chip's own icon
            // crossfade is handled by `.contentTransition(.symbolEffect)`.
            feedLayoutRaw = nextLayout(after: feedLayoutRaw)
        } label: {
            Image(systemName: layoutIcon(for: feedLayoutRaw))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.secondary)
                .frame(width: 38, height: 38)
                .background(Capsule().fill(AppTheme.surface))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Layout: \(feedLayoutRaw)")
    }

    private func nextLayout(after current: String) -> String {
        switch current {
        case "hybrid": "list"
        case "list": "grid"
        case "grid": "hybrid"
        default: "hybrid"
        }
    }

    private func layoutIcon(for layout: String) -> String {
        switch layout {
        case "list": "list.bullet"
        case "grid": "square.grid.2x2.fill"
        case "hybrid": "rectangle.split.1x2"
        default: "rectangle.split.1x2"
        }
    }

    /// Extracted so UpcomingView can render the exact same chip in the same way.
    private var typeFilterChip: some View {
        Menu {
            Picker("Type", selection: $releaseKindFilterRaw) {
                ForEach(ReleaseKindFilter.allCases) { filter in
                    Text(filter.rawValue).tag(filter.rawValue)
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: releaseKindFilter == .all
                      ? "line.3.horizontal.decrease.circle"
                      : "line.3.horizontal.decrease.circle.fill")
                    .font(.subheadline.weight(.semibold))
                Text(releaseKindFilter.rawValue)
                    .font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(releaseKindFilter == .all ? AppTheme.secondary : .white)
            .padding(.horizontal, 14)
            .frame(height: 38)
            .background(
                Capsule().fill(releaseKindFilter == .all ? AppTheme.surface : AppTheme.elevatedSurface)
            )
        }
        .accessibilityLabel("Filter releases by type")
        .accessibilityValue(releaseKindFilter.rawValue)
    }

    private var dot: some View {
        Circle()
            .fill(AppTheme.secondary.opacity(0.6))
            .frame(width: 3, height: 3)
    }

    private var lastRefreshedLabel: String? {
        guard lastSuccessfulRefreshAt > 0 else { return nil }
        let date = Date(timeIntervalSince1970: lastSuccessfulRefreshAt)
        let elapsed = Date().timeIntervalSince(date)
        if elapsed < 60 { return "just now" }
        if elapsed < 3600 { return "\(Int(elapsed / 60)) min ago" }
        if elapsed < 86_400 { return "\(Int(elapsed / 3600))h ago" }
        return "\(Int(elapsed / 86_400))d ago"
    }

    private func inlineMetric(value: Int, label: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Text("\(value)")
                .font(.caption.weight(.bold))
                .foregroundStyle(color)
            Text(label)
                .font(.caption)
                .foregroundStyle(AppTheme.secondary)
        }
    }


    private func actionableEmptyState(
        title: String,
        message: String,
        systemImage: String,
        primary: EmptyStateAction? = nil,
        secondary: EmptyStateAction? = nil
    ) -> some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(AppTheme.accentSoft)
                    .frame(width: 64, height: 64)
                Image(systemName: systemImage)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(AppTheme.accent)
            }

            VStack(spacing: 6) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(AppTheme.primaryText)
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(AppTheme.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 16)

            if primary != nil || secondary != nil {
                HStack(spacing: 10) {
                    if let primary {
                        Button(action: primary.action) {
                            Label(primary.label, systemImage: primary.icon)
                        }
                        .buttonStyle(PrimaryButtonStyle())
                    }
                    if let secondary {
                        Button(action: secondary.action) {
                            Label(secondary.label, systemImage: secondary.icon)
                        }
                        .buttonStyle(GhostButtonStyle())
                    }
                }
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .padding(.horizontal, 24)
    }

    private func isRefreshFailure(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("first:") || lower.contains("fail") || lower.contains("error")
            || isMusicKitFailure(message)
    }

    private func isMusicKitFailure(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("entitle") || lower.contains("not registered")
            || lower.contains("token") || lower.contains("client not found")
    }

    private func releaseGroup(_ title: String, releases: [ReleaseData]) -> some View {
        Group {
            if !releases.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader(title: title)
                        .padding(.horizontal, 18)

                    if feedLayoutRaw == "grid" {
                        // 2-column grid using the same hero-style card.
                        let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
                        LazyVGrid(columns: columns, spacing: 14) {
                            ForEach(releases) { release in
                                NavigationLink(value: release) {
                                    heroGridCard(release)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 18)
                    } else {
                        // In list mode, promote the very first item of the "New"
                        // bucket to a hero row so the most recent drop reads as
                        // more important than the rest of the unread list.
                        let useHero = feedLayoutRaw == "list" && title == "New"
                        // LazyVStack — without this, switching to the Feed tab on
                        // libraries with 100+ artists instantiated ~150 release
                        // rows eagerly before the tab could appear, freezing the
                        // current tab for ~2s. Rows now build as they scroll in.
                        LazyVStack(spacing: 8) {
                            ForEach(Array(releases.enumerated()), id: \.element.id) { idx, release in
                                NavigationLink(value: release) {
                                    if useHero && idx == 0 {
                                        heroListRow(release)
                                    } else {
                                        releaseRow(release)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 18)
                    }
                }
            }
        }
    }

    /// Past + already-seen releases bucketed by release month so the feed stops
    /// being one infinite scroll. Each bucket is its own section header + list.
    @ViewBuilder
    private func pastReleasesByMonth(_ releases: [ReleaseData]) -> some View {
        if !releases.isEmpty {
            let buckets = monthBuckets(for: releases)
            let visibleBuckets = showAllPastMonths
                ? buckets
                : Array(buckets.prefix(defaultPastMonthCount))
            let hiddenCount = buckets.count - visibleBuckets.count
            let hiddenReleaseCount = visibleBuckets.count < buckets.count
                ? buckets.dropFirst(visibleBuckets.count).reduce(0) { $0 + $1.releases.count }
                : 0

            // LazyVStack so off-screen month buckets aren't instantiated until
            // the user scrolls. Each bucket holds its own ForEach of releases,
            // so eagerly building all buckets multiplied the tab-switch cost.
            LazyVStack(alignment: .leading, spacing: 18) {
                ForEach(visibleBuckets, id: \.label) { bucket in
                    releaseGroup(bucket.label, releases: bucket.releases)
                }

                if hiddenCount > 0 {
                    Button {
                        showAllPastMonths = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.down")
                                .font(.footnote.weight(.semibold))
                            Text("Show \(hiddenReleaseCount) older release\(hiddenReleaseCount == 1 ? "" : "s")")
                                .font(.subheadline.weight(.semibold))
                        }
                        .foregroundStyle(AppTheme.accent)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(AppTheme.surface)
                        )
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 18)
                }
            }
        }
    }

    private struct MonthBucket {
        let label: String
        let releases: [ReleaseData]
    }

    private static let monthBucketFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMMM yyyy"
        return f
    }()

    private func monthBuckets(for releases: [ReleaseData]) -> [MonthBucket] {
        let formatter = Self.monthBucketFormatter
        let grouped = Dictionary(grouping: releases) { release -> String in
            guard let date = release.releaseDate else { return "Unknown" }
            return formatter.string(from: date)
        }
        return grouped
            .map { MonthBucket(label: $0.key, releases: $0.value) }
            .sorted { lhs, rhs in
                // Newest month first so recent past is at the top.
                let lhsDate = lhs.releases.first?.releaseDate ?? .distantPast
                let rhsDate = rhs.releases.first?.releaseDate ?? .distantPast
                return lhsDate > rhsDate
            }
    }

    /// New unseen releases shown as a 2-column album grid (Apple Music "New
    /// Releases" style). Big square artwork, title + artist below — feels like
    /// browsing music instead of a notification list.
    private func heroNewReleasesSection(_ releases: [ReleaseData]) -> some View {
        let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
        return VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "New")
                .padding(.horizontal, 18)
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(releases) { release in
                    NavigationLink(value: release) {
                        heroGridCard(release)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 18)
        }
    }

    private func heroGridCard(_ release: ReleaseData) -> some View {
        let providerID = release.providerID
        return VStack(alignment: .leading, spacing: 8) {
            CachedAsyncImage(url: release.artworkURL) {
                releaseArtworkPlaceholder(release)
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(alignment: .topTrailing) {
                if !release.isSeen {
                    Circle()
                        .fill(AppTheme.accent)
                        .frame(width: 10, height: 10)
                        .overlay(Circle().stroke(AppTheme.background, lineWidth: 2))
                        .padding(8)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if labelArtistIDs.contains(release.artistProviderID) {
                    LabelSourceBadge().padding(6)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(ReleaseTitleFormatter.displayTitle(release.title))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.primaryText)
                    .lineLimit(1)
                Text(release.artistName)
                    .font(.caption)
                    .foregroundStyle(AppTheme.secondary)
                    .lineLimit(1)
                ReleaseTypeBadge(kind: release.kind)
            }
        }
        .contextMenu { releaseContextMenu(release) } preview: { releaseContextMenuPreview(release) }
        .onAppear {
            // Per-cell tracklist warmup. Skips if already cached; otherwise
            // fetches in the background so a tap into the album page opens
            // with the tracklist already populated.
            Task.detached(priority: .utility) {
                await TrackPrefetcher.prefetch(providerID: providerID)
            }
        }
    }

    private func releaseRow(_ release: ReleaseData) -> some View {
        HStack(spacing: 12) {
            CachedAsyncImage(url: release.artworkURL) {
                releaseArtworkPlaceholder(release)
            }
            .frame(width: 58, height: 58)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(ReleaseTitleFormatter.displayTitle(release.title))
                    .font(.subheadline.weight(release.isSeen ? .regular : .semibold))
                    .foregroundStyle(AppTheme.primaryText)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(release.artistName)
                        .font(.footnote)
                        .foregroundStyle(AppTheme.secondary)
                        .lineLimit(1)
                    if labelArtistIDs.contains(release.artistProviderID) {
                        LabelSourceBadge()
                    }
                }
                if let via = viaTrackedArtistName(for: release) {
                    Text("via \(via)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(AppTheme.accent)
                        .lineLimit(1)
                }
                HStack(spacing: 6) {
                    Text(release.formattedReleaseDate)
                        .font(.caption2)
                        .foregroundStyle(AppTheme.secondary)
                    ReleaseTypeBadge(kind: release.kind)
                }
            }

            Spacer()

            if !release.isSeen {
                Circle()
                    .fill(AppTheme.accent)
                    .frame(width: 7, height: 7)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(AppTheme.surface)
        )
        .contextMenu { releaseContextMenu(release) } preview: { releaseContextMenuPreview(release) }
    }

    /// Hero list row: larger artwork, artist name in accent above the title.
    /// Used for the top-most item in the "New" section in list layout so the
    /// most recent drop reads as more important than the rest of the list.
    private func heroListRow(_ release: ReleaseData) -> some View {
        HStack(spacing: 14) {
            CachedAsyncImage(url: release.artworkURL) {
                releaseArtworkPlaceholder(release)
            }
            .frame(width: 92, height: 92)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            VStack(alignment: .leading, spacing: 5) {
                Text(release.artistName.uppercased())
                    .font(.caption.weight(.heavy))
                    .tracking(0.8)
                    .foregroundStyle(AppTheme.accent)
                    .lineLimit(1)

                Text(ReleaseTitleFormatter.displayTitle(release.title))
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(AppTheme.primaryText)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)

                if let via = viaTrackedArtistName(for: release) {
                    Text("via \(via)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(AppTheme.accent)
                        .lineLimit(1)
                }

                HStack(spacing: 6) {
                    Text(release.formattedReleaseDate)
                        .font(.caption2)
                        .foregroundStyle(AppTheme.secondary)
                    ReleaseTypeBadge(kind: release.kind)
                    if labelArtistIDs.contains(release.artistProviderID) {
                        LabelSourceBadge()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if !release.isSeen {
                Circle()
                    .fill(AppTheme.accent)
                    .frame(width: 9, height: 9)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(AppTheme.surface)
        )
        .contextMenu { releaseContextMenu(release) } preview: { releaseContextMenuPreview(release) }
    }

    /// Lightweight long-press snapshot. Default `.contextMenu` lifts the entire
    /// row including badges, ring overlays, and label-source chips, which can
    /// stutter on weaker devices when the row is large. This preview is just the
    /// artwork + two lines of text — fast to render and feels punchier.
    private func releaseContextMenuPreview(_ release: ReleaseData) -> some View {
        // Wrapping the preview in a NavigationLink (with the matching
        // `.navigationDestination(for: ReleaseData.self)` already installed
        // on the parent) lets a tap on the lifted preview push the album
        // detail view, which is what users instinctively try.
        NavigationLink(value: release) {
            VStack(alignment: .leading, spacing: 10) {
                CachedAsyncImage(url: release.artworkURL) {
                    releaseArtworkPlaceholder(release)
                }
                .frame(width: 220, height: 220)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text(ReleaseTitleFormatter.displayTitle(release.title))
                        .font(.headline)
                        .foregroundStyle(AppTheme.primaryText)
                        .lineLimit(2)
                    Text(release.artistName)
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.secondary)
                        .lineLimit(1)
                }
            }
            .padding(14)
            .background(AppTheme.surface)
        }
        .buttonStyle(.plain)
    }

    /// Long-press menu shared by every release surface in the feed. Covers the
    /// MusicHarbor-style actions (calendar / share / open in Apple Music /
    /// view artist) plus the read-state controls. Each surface attaches this
    /// menu rather than duplicating button definitions.
    @ViewBuilder
    private func releaseContextMenu(_ release: ReleaseData) -> some View {
        // Order: primary → share → state action → destructive (last).
        // "Add to Calendar" lives on the album detail page (only relevant for
        // upcoming releases). In the feed it just adds visual noise to every
        // long-press menu, so it's hidden here.
        if let url = release.albumURL {
            Button {
                UIApplication.shared.open(url)
            } label: {
                Label("Open in Apple Music", systemImage: "music.note")
            }
            ShareLink(item: url) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
        }
        Button {
            release.isSeen.toggle()
            // Debounced save — fast successive toggles collapse to one commit.
            ModelContextSaveDebouncer.shared.scheduleSave(modelContext)
            // Toggle doesn't change `storedReleases.count`, so .task(id:)
            // won't refire. Refresh the cache inline so the row moves to
            // the correct bucket immediately.
            cachedDerived = computeDerived()
        } label: {
            Label(release.isSeen ? "Mark unseen" : "Mark seen",
                  systemImage: release.isSeen ? "circle" : "checkmark.circle")
        }
        Divider()
        // Quick path to stop following the source artist directly from a
        // release row — saves the user a trip to the Artists tab when
        // something they no longer care about keeps surfacing in the feed.
        if let trackedArtist = trackedArtists.first(where: { $0.providerID == release.artistProviderID }) {
            Button(role: .destructive) {
                trackedArtist.isTracked = false
                ModelContextSaveDebouncer.shared.scheduleSave(modelContext)
                refreshTrackedSets()
                cachedDerived = computeDerived()
            } label: {
                Label("Unfollow \(trackedArtist.name)", systemImage: "person.fill.xmark")
            }
        }
        Button(role: .destructive) {
            release.dismissedAt = Date()
            ModelContextSaveDebouncer.shared.scheduleSave(modelContext)
            cachedDerived = computeDerived()
        } label: {
            Label("Dismiss", systemImage: "xmark")
        }
    }

    private func releaseArtworkPlaceholder(_ release: ReleaseData) -> some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(AppTheme.elevatedSurface)
            .overlay {
                Image(systemName: release.isUpcoming ? "calendar" : "opticaldisc")
                    .font(.title3)
                    .foregroundStyle(AppTheme.secondary)
            }
    }

    private func markAllAsSeen() {
        // Confirm if it's a substantial batch so the user doesn't fat-finger
        // away their unread state.
        let ids = trackedArtistIDs
        let count = storedReleases.lazy.filter { ids.contains($0.artistProviderID) && !$0.isSeen && $0.dismissedAt == nil }.count
        if count > 50 {
            showingMarkAllConfirm = true
        } else {
            applyMarkAllAsSeen()
        }
    }

    private func applyMarkAllAsSeen() {
        let ids = trackedArtistIDs
        for release in storedReleases where ids.contains(release.artistProviderID) && !release.isSeen && release.dismissedAt == nil {
            release.isSeen = true
        }
        try? modelContext.save()
        cachedDerived = computeDerived()
        // Success haptic so the action feels acknowledged — without this the
        // 100-row mutation appears to do nothing on slower devices.
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    private func startRefresh() {
        refreshCoordinator.refresh(
            trackedArtists: trackedArtists,
            modelContext: modelContext,
            notificationHour: releaseNotificationHour,
            notificationMinute: releaseNotificationMinute
        )
    }

    /// Consults the global Settings → View toggles. Releases of a kind toggled
    /// off here are hidden from every list in the app.
    private func kindIsGloballyVisible(_ kind: ReleaseKind) -> Bool {
        switch kind {
        case .album: return showAlbums
        case .single: return showSingles
        case .ep: return showEPs
        case .liveAlbum: return showLiveAlbums
        case .compilation: return showCompilations
        case .remix: return showRemixes
        }
    }

    private func releaseMatchesKindFilter(_ release: ReleaseData, filter: ReleaseKindFilter? = nil) -> Bool {
        switch filter ?? releaseKindFilter {
        case .all:
            return true
        case .albums:
            return release.kind == .album || release.kind == .compilation || release.kind == .liveAlbum
        case .eps:
            return release.kind == .ep
        case .singles:
            return release.kind == .single || release.kind == .remix
        }
    }
}


#Preview {
    HomeView()
        .modelContainer(for: [ArtistData.self, ReleaseData.self], inMemory: true)
        .environment(RefreshCoordinator())
}

/// Toolbar refresh control. When idle: a plain refresh icon that starts a new
/// fetch on tap. When in-progress: a circular progress arc that fills with
/// `checkedArtists / totalArtists` (or spins as an indeterminate quarter-arc
/// during the warming / videos / concerts phases). Tapping during a refresh
/// surfaces the detail sheet instead of trying to start a new one.
///
/// This view is its own observer of `RefreshCoordinator` so progress ticks
/// (~6 Hz) don't bubble up to invalidate `HomeView.body`.
fileprivate struct ToolbarRefreshButton: View {
    @Environment(RefreshCoordinator.self) private var refreshCoordinator
    let isIdleDisabled: Bool
    let onIdleTap: () -> Void
    let onActiveTap: () -> Void

    private let arcSize: CGFloat = 22
    private let lineWidth: CGFloat = 2.5

    var body: some View {
        Button {
            if refreshCoordinator.isRefreshing {
                onActiveTap()
            } else {
                onIdleTap()
            }
        } label: {
            Group {
                if refreshCoordinator.isRefreshing {
                    arcContent
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(AppTheme.navAccent)
                }
            }
            .frame(width: 30, height: 30)
            .contentShape(Rectangle())
        }
        .disabled(!refreshCoordinator.isRefreshing && isIdleDisabled)
        .accessibilityLabel(refreshCoordinator.isRefreshing
                            ? "Refresh in progress, tap for details"
                            : "Check for releases")
    }

    @ViewBuilder
    private var arcContent: some View {
        let progress = refreshCoordinator.progress
        let isIndeterminate = progress?.isIndeterminate ?? true
        let fraction = isIndeterminate ? 0.0 : (progress?.fractionCompleted ?? 0)

        ZStack {
            Circle()
                .stroke(AppTheme.accent.opacity(0.22), lineWidth: lineWidth)
            if isIndeterminate {
                // Spinning quarter-arc — paused: false so SwiftUI keeps
                // ticking the timeline regardless of state churn.
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: false)) { ctx in
                    let degrees = ctx.date.timeIntervalSinceReferenceDate
                        .truncatingRemainder(dividingBy: 1.0) * 360
                    Circle()
                        .trim(from: 0, to: 0.25)
                        .stroke(AppTheme.accent, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                        .rotationEffect(.degrees(degrees))
                }
            } else {
                Circle()
                    .trim(from: 0, to: max(0.04, fraction))
                    .stroke(AppTheme.accent, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.3), value: fraction)
            }
        }
        .frame(width: arcSize, height: arcSize)
    }
}

/// Sheet shown when the user taps the toolbar arc during a refresh. Hosts the
/// full progress bar plus the stop control. Auto-dismisses when the refresh
/// finishes (see `.onChange(of: refreshCoordinator.isRefreshing)` in HomeView).
fileprivate struct RefreshDetailSheet: View {
    @Environment(RefreshCoordinator.self) private var refreshCoordinator
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Refreshing")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(AppTheme.primaryText)
                Spacer()
                Button("Done") { isPresented = false }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.accent)
            }

            RefreshProgressBar()

            Text(phaseDescription)
                .font(.footnote)
                .foregroundStyle(AppTheme.secondary)

            Spacer()
        }
        .padding(20)
    }

    private var phaseDescription: String {
        guard let progress = refreshCoordinator.progress else {
            return "Starting…"
        }
        switch progress.phase {
        case .warming: return "Connecting to Apple Music."
        case .releases:
            if progress.totalArtists > 0 {
                return "Checking \(progress.checkedArtists) of \(progress.totalArtists) tracked artists for new releases."
            }
            return "Checking your tracked artists for new releases."
        case .videos: return "Looking for new music videos."
        case .concerts: return "Looking for new concert dates."
        case .finishing: return "Wrapping up."
        }
    }
}

/// Refresh progress bar isolated as its own observer of `RefreshCoordinator`.
/// HomeView used to render the bar inline, which made every progress tick
/// (~6 Hz, plus phase changes) re-run the entire HomeView body — pulling the
/// `derived` walk over the full release set onto the main thread on each tick.
/// Putting the bar in its own view scopes those invalidations: only the bar's
/// body re-renders on a progress change, leaving HomeView untouched.
fileprivate struct RefreshProgressBar: View {
    @Environment(RefreshCoordinator.self) private var refreshCoordinator

    var body: some View {
        let progress = refreshCoordinator.progress
        let isIndeterminate = progress?.isIndeterminate ?? false
        let phase = progress?.phase ?? .releases
        let fraction: Double = isIndeterminate ? 1.0 : (progress?.fractionCompleted ?? 0)
        let checked = progress?.checkedArtists ?? 0
        let total = progress?.totalArtists ?? 0
        let current: String = {
            if isIndeterminate { return phase.rawValue + "…" }
            return progress?.currentArtistName ?? "Starting…"
        }()

        // Layered approach: full-width track, then a fill anchored to the
        // leading edge that scales horizontally to the current fraction.
        // Avoids GeometryReader (which gave 0 width on the first layout pass
        // and made the bar jump in on appear), and avoids tying the sheen
        // animation to the changing fraction (which made it stutter when
        // progress jumped).
        return ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(AppTheme.elevatedSurface)

            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(AppTheme.accent)
                .scaleEffect(x: max(0.0001, CGFloat(fraction)), y: 1, anchor: .leading)
                .animation(.easeOut(duration: 0.35), value: fraction)
                .overlay(
                    // Continuous shimmer that lives in the filled region and
                    // sweeps independently of the actual fraction value.
                    // 20fps is plenty for the gentle gradient sweep — at 30
                    // it was contributing visible main-thread load during
                    // refresh on older devices.
                    TimelineView(.animation(minimumInterval: 1.0 / 20, paused: false)) { context in
                        let t = context.date.timeIntervalSinceReferenceDate
                            .truncatingRemainder(dividingBy: 1.8) / 1.8
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0),
                                Color.white.opacity(0.22),
                                Color.white.opacity(0)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .opacity(0.9)
                        .mask(
                            Rectangle()
                                .offset(x: -200 + 600 * CGFloat(t))
                                .frame(width: 200)
                        )
                    }
                )
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            HStack(spacing: 10) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.subheadline.weight(.semibold))
                Text(current)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                if !isIndeterminate {
                    Text("\(checked)/\(total)")
                        .font(.footnote.weight(.semibold))
                        .monospacedDigit()
                }
                Button {
                    refreshCoordinator.cancel()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(AppTheme.primaryText)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(AppTheme.primaryText.opacity(0.18)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Stop checking")
            }
            .foregroundStyle(AppTheme.primaryText)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 46)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Checking \(checked) of \(total). Currently \(current).")
        .accessibilityValue("\(Int(fraction * 100)) percent")
    }
}

