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
    @EnvironmentObject private var refreshCoordinator: RefreshCoordinator
    @Query(filter: #Predicate<ArtistData> { artist in
        artist.isTracked
    }, sort: \ArtistData.name) private var trackedArtists: [ArtistData]

    /// Set of every tracked artist's providerID. Used as an O(1) membership check
    /// when filtering releases — previously this was a linear `.contains` per
    /// release, which scaled badly with large libraries.
    private var trackedArtistIDs: Set<String> {
        Set(trackedArtists.map(\.providerID))
    }

    /// Provider IDs of artists whose `kind == "label"`. Used to mark releases
    /// pulled via record-label tracking with the LabelSourceBadge.
    private var labelArtistIDs: Set<String> {
        Set(trackedArtists.filter { $0.kind == "label" }.map(\.providerID))
    }
    @Query(sort: \ReleaseData.firstSeenAt, order: .reverse) private var storedReleases: [ReleaseData]
    @AppStorage(AppSettings.autoRefreshOnLaunch) private var autoRefreshOnLaunch = true
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
    @State private var pullTriggered = false
    @State private var scrollAtTop = true
    @State private var releaseSearchText = ""
    @State private var showingMarkAllConfirm = false
    @State private var isSearchPresented = false

    private var feedFilter: ReleaseFeedFilter {
        ReleaseFeedFilter(rawValue: feedFilterRaw) ?? .releases
    }

    private var isRefreshing: Bool { refreshCoordinator.isRefreshing }
    private var refreshProgress: ReleaseRefreshProgress? { refreshCoordinator.progress }
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

    private var derived: DerivedReleases {
        let ids = trackedArtistIDs
        let trimmedSearch = releaseSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let kindFilter = releaseKindFilter
        var out = DerivedReleases()

        for release in storedReleases {
            guard ids.contains(release.artistProviderID) else { continue }
            out.hasAnyTrackedRelease = true
            if release.isUpcoming { out.upcomingCount += 1 }
            if !release.isSeen && release.dismissedAt == nil { out.unreadCount += 1 }

            // Below this point: visible-feed filtering.
            guard release.dismissedAt == nil else { continue }
            guard !release.isUpcoming else { continue }
            guard kindIsGloballyVisible(release.kind) else { continue }
            guard releaseMatchesKindFilter(release, filter: kindFilter) else { continue }
            if !trimmedSearch.isEmpty {
                let inTitle = release.title.localizedCaseInsensitiveContains(trimmedSearch)
                let inArtist = release.artistName.localizedCaseInsensitiveContains(trimmedSearch)
                if !inTitle && !inArtist { continue }
            }

            out.visibleCount += 1
            if release.hasUnknownReleaseDate {
                out.unknownDate.append(release)
            } else if release.isNewRelease && !release.isSeen {
                out.newReleases.append(release)
            } else if release.isPastRelease || (release.isNewRelease && release.isSeen) {
                out.pastAndSeen.append(release)
            }
        }

        // Sort each bucket once. storedReleases is itself sorted by firstSeenAt
        // desc, but we want releaseDate-desc presentation throughout the feed.
        let sortDesc: (ReleaseData, ReleaseData) -> Bool = { lhs, rhs in
            (lhs.releaseDate ?? lhs.firstSeenAt) > (rhs.releaseDate ?? rhs.firstSeenAt)
        }
        out.newReleases.sort(by: sortDesc)
        out.pastAndSeen.sort(by: sortDesc)
        out.unknownDate.sort(by: sortDesc)
        return out
    }

    private var releaseKindFilter: ReleaseKindFilter {
        ReleaseKindFilter(rawValue: releaseKindFilterRaw) ?? .all
    }

    var body: some View {
        // Compute once per render and reuse — see DerivedReleases.
        let derived = derived
        return NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
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
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .appScreenBackground()
            // Value-based navigation so AlbumView (with its @StateObject preview
            // player and queries) is only instantiated when the user actually
            // pushes a release, not eagerly for every cell in the feed.
            .navigationDestination(for: ReleaseData.self) { release in
                AlbumView(release: release)
            }
            .searchable(text: $releaseSearchText, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search releases")
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                // contentOffset.y stays clamped at the top in SwiftUI's ScrollView during
                // rubber-band, so we only use it to tell whether the user is *resting* at top.
                geometry.contentOffset.y
            } action: { _, newOffset in
                scrollAtTop = newOffset < 12
                if newOffset > 40 { pullTriggered = false }
            }
            .simultaneousGesture(
                // DragGesture fires reliably during overscroll. Threshold: user must start the
                // drag while sitting at the top and pull down at least 120pt before we trigger.
                DragGesture(minimumDistance: 20)
                    .onChanged { value in
                        guard scrollAtTop,
                              !pullTriggered,
                              !refreshCoordinator.isRefreshing,
                              !trackedArtists.isEmpty,
                              value.translation.height > 120 else { return }
                        pullTriggered = true
                        startRefresh()
                    }
                    .onEnded { _ in
                        // Allow the latch to clear once the gesture is over so the next pull retriggers.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            pullTriggered = false
                        }
                    }
            )
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
                // cheap on repeat launches.
                let topProviderIDs = (derived.newReleases + derived.pastAndSeen)
                    .prefix(10)
                    .map(\.providerID)
                Task.detached(priority: .utility) {
                    await TrackPrefetcher.prefetchBatch(providerIDs: topProviderIDs)
                }

                guard autoRefreshOnLaunch, !hasAutoRefreshed, !trackedArtists.isEmpty else {
                    return
                }

                hasAutoRefreshed = true
                startRefresh()
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 6) {
                        Button {
                            startRefresh()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(refreshCoordinator.isRefreshing ? AppTheme.secondary : AppTheme.accent)
                        }
                        .disabled(trackedArtists.isEmpty || refreshCoordinator.isRefreshing)
                        .accessibilityLabel("Check for releases")

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
                        }
                        .accessibilityLabel("More")
                    }
                }
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
                .environmentObject(refreshCoordinator)
            }
        }
    }

    private func header(derived: DerivedReleases) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Feed")
                .font(.system(size: 36, weight: .bold, design: .rounded))
                .foregroundStyle(AppTheme.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            // Unread count is the only feed-relevant metric here — artist and
            // upcoming totals belong to their own tabs.
            HStack(spacing: 10) {
                inlineMetric(value: derived.unreadCount, label: "unread", color: AppTheme.yellow)
                Spacer()
                layoutToggleChip
                typeFilterChip
            }

            // Only show the progress bar inline; the icon refresh button is in the toolbar.
            if refreshCoordinator.isRefreshing {
                refreshProgressBar
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 18)
    }

    /// Three-state layout toggle: hybrid → list → grid → hybrid.
    private var layoutToggleChip: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                feedLayoutRaw = nextLayout(after: feedLayoutRaw)
            }
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
    }

    private var dot: some View {
        Circle()
            .fill(AppTheme.secondary.opacity(0.6))
            .frame(width: 3, height: 3)
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

    private var refreshProgressBar: some View {
        let fraction = refreshProgress?.fractionCompleted ?? 0
        let checked = refreshProgress?.checkedArtists ?? 0
        let total = refreshProgress?.totalArtists ?? trackedArtists.count
        let current = refreshProgress?.currentArtistName ?? "Starting…"

        // Layered approach: full-width track, then a fill anchored to the
        // leading edge that scales horizontally to the current fraction.
        // Avoids GeometryReader (which gave 0 width on the first layout pass
        // and made the bar jump in on appear), and avoids tying the sheen
        // animation to the changing fraction (which made it stutter when
        // progress jumped).
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(AppTheme.elevatedSurface)

            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(AppTheme.accent)
                .scaleEffect(x: max(0.0001, CGFloat(fraction)), y: 1, anchor: .leading)
                .animation(.easeOut(duration: 0.35), value: fraction)
                .overlay(
                    // Continuous shimmer that lives in the filled region and
                    // sweeps independently of the actual fraction value.
                    TimelineView(.animation(minimumInterval: 1.0 / 30, paused: false)) { context in
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
                Text("\(checked)/\(total)")
                    .font(.footnote.weight(.semibold))
                    .monospacedDigit()
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
                        VStack(spacing: 8) {
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
            VStack(alignment: .leading, spacing: 18) {
                ForEach(monthBuckets(for: releases), id: \.label) { bucket in
                    releaseGroup(bucket.label, releases: bucket.releases)
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
        VStack(alignment: .leading, spacing: 8) {
            CachedAsyncImage(url: release.artworkURL) {
                releaseArtworkPlaceholder(release)
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(alignment: .topTrailing) {
                if !release.isSeen && release.isNewRelease {
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
        .contextMenu { releaseContextMenu(release) }
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
                HStack(spacing: 6) {
                    Text(release.formattedReleaseDate)
                        .font(.caption2)
                        .foregroundStyle(AppTheme.secondary)
                    ReleaseTypeBadge(kind: release.kind)
                }
            }

            Spacer()

            if !release.isSeen && release.isNewRelease {
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
        .contextMenu { releaseContextMenu(release) }
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
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

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

            if !release.isSeen && release.isNewRelease {
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
        .contextMenu { releaseContextMenu(release) }
    }

    /// Long-press menu shared by every release surface in the feed. Covers the
    /// MusicHarbor-style actions (calendar / share / open in Apple Music /
    /// view artist) plus the read-state controls. Each surface attaches this
    /// menu rather than duplicating button definitions.
    @ViewBuilder
    private func releaseContextMenu(_ release: ReleaseData) -> some View {
        Button {
            Task { _ = try? await CalendarService().addRelease(release) }
        } label: {
            Label("Add to Calendar", systemImage: "calendar.badge.plus")
        }
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
        Divider()
        Button {
            release.isSeen.toggle()
            try? modelContext.save()
        } label: {
            Label(release.isSeen ? "Mark unseen" : "Mark seen",
                  systemImage: release.isSeen ? "circle" : "checkmark.circle")
        }
        Button(role: .destructive) {
            release.dismissedAt = Date()
            try? modelContext.save()
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
        .environmentObject(RefreshCoordinator())
}
