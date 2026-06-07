//
//  ContentView.swift
//  MusicNotifier
//
//  Created by Dimitris Kern on 28.07.25.
//

import SwiftUI
import SwiftData
import UIKit

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @AppStorage(AppSettings.swipeBetweenTabs) private var swipeBetweenTabs = true
    @AppStorage(AppSettings.appearance) private var appearanceRaw: String = "system"
    @AppStorage(AppSettings.enableVideosTab) private var enableVideosTab = false
    @AppStorage(AppSettings.enableConcertsTab) private var enableConcertsTab = false
    @AppStorage(AppSettings.releaseNotificationHour) private var releaseNotificationHour = 8
    @AppStorage(AppSettings.releaseNotificationMinute) private var releaseNotificationMinute = 0
    // NOTE: deliberately no top-level `@Query releases` here.
    // Every SwiftData save during a refresh (release upsert, videos, concerts)
    // re-fires top-level @Query observers and re-runs ContentView's body — which
    // re-renders the whole TabView and was making tab switches block for ~2s
    // during a refresh. Releases are now fetched on demand by the deep-link
    // handler, and the iPad sidebar's reactive counts live in `SidebarContent`
    // so the query never instantiates on iPhone.
    @Query private var artists: [ArtistData]
    @State private var startFreshOverridden = false
    // Latch: once we've shown Intro, never re-route to ICloudWelcomeView
    // mid-flow. Without this, late-arriving CloudKit hydration during an
    // Apple Music import yanks the user from the import sheet into the
    // iCloud welcome — and tapping Continue there re-imports the same
    // artists, creating duplicates.
    @State private var hasShownIntro = false
    @State private var showingSettings = false
    @StateObject private var deepLinkRouter = DeepLinkRouter()
    @EnvironmentObject private var navigationDepth: TabNavigationDepth
    @Environment(RefreshCoordinator.self) private var refreshCoordinator
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        Group {
            // Hidden context-menu warmup. The first invocation of
            // `UIContextMenuInteraction` after a cold launch (or after iOS
            // suspends/resumes the app) takes hundreds of ms to initialize —
            // long enough that the user's long-press often lifts off before
            // the menu has time to present, leaving them tapping with no
            // visual feedback. Attaching a `.contextMenu` to a 1×1
            // transparent view positioned off-screen forces iOS to allocate
            // and wire up the interaction up-front, on the same work it was
            // already doing to install the rest of the hierarchy. The view
            // itself is unreachable so the user can never trigger it.
            Color.clear
                .frame(width: 1, height: 1)
                .contextMenu { Button("") {} }
                .accessibilityHidden(true)
                .offset(x: -10_000, y: -10_000)

            if !hasCompletedOnboarding {
                if !startFreshOverridden && !artists.isEmpty && !hasShownIntro {
                    // Fresh install + CloudKit hydrated an existing watchlist:
                    // skip the provider/import flow and offer a quick welcome.
                    ICloudWelcomeView(
                        artistCount: artists.count,
                        trackedCount: artists.filter(\.isTracked).count,
                        onContinue: {
                            // If iCloud mirrored artists with isTracked=false
                            // (e.g. they were imported but never tracked on
                            // the source device, or the field didn't round-
                            // trip), the Feed would be empty and the refresh
                            // button stays disabled. Auto-track everything so
                            // "use my iCloud artists" actually does something.
                            if !artists.contains(where: \.isTracked) {
                                for artist in artists { artist.isTracked = true }
                                try? modelContext.save()
                            }
                            hasCompletedOnboarding = true
                        },
                        onStartFresh: {
                            for artist in artists { modelContext.delete(artist) }
                            try? modelContext.save()
                            startFreshOverridden = true
                        }
                    )
                } else {
                    Intro()
                        .onAppear { hasShownIntro = true }
                }
            } else if horizontalSizeClass == .regular {
                // iPad / Mac Catalyst / landscape iPhone Pro Max: sidebar layout.
                splitLayout
            } else {
                // iPhone (compact): bottom tab bar.
                tabLayout
            }
        }
        .preferredColorScheme(resolvedColorScheme)
        // iOS 26's floating tab/nav pills leave the safe-area strips above
        // and below the content uncovered. Without a root background those
        // strips fall through to the system window black, which doesn't
        // match AppTheme.background and reads as a black band at the top
        // (under the status bar) and bottom (around the tab bar pill).
        // Painting the background here covers the whole window including
        // those safe-area regions.
        .background(AppTheme.background.ignoresSafeArea())
        .onOpenURL { url in
            deepLinkRouter.handle(url: url, releases: fetchAllReleases())
        }
        // Notification tap → broadcasted by ForegroundNotificationDelegate.
        // Route the same way as system deep links so AlbumView pops up.
        .onReceive(NotificationCenter.default.publisher(for: .musicNotifierDeepLinkTapped)) { notification in
            if let url = notification.object as? URL {
                deepLinkRouter.handle(url: url, releases: fetchAllReleases())
            }
        }
        // Menu-bar / keyboard shortcut hooks (Mac + iPad). These fire from the
        // .commands block on the WindowGroup; they're picked up here so they
        // affect the same selectedTab state the UI already drives.
        .onReceive(NotificationCenter.default.publisher(for: .musicNotifierSelectTab)) { notification in
            if let tag = notification.object as? Int { deepLinkRouter.selectedTab = tag }
        }
        .onReceive(NotificationCenter.default.publisher(for: .musicNotifierOpenSettings)) { _ in
            showingSettings = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .musicNotifierRequestRefresh)) { _ in
            startRefresh()
        }
        .sheet(item: $deepLinkRouter.selectedRelease) { release in
            NavigationStack {
                AlbumView(release: release)
            }
            .preferredColorScheme(resolvedColorScheme)
        }
        .sheet(isPresented: $showingSettings) {
            NavigationStack {
                SettingsView()
            }
            .environment(refreshCoordinator)
            // Sheets present in a separate window root, so the .preferred-
            // ColorScheme applied to ContentView doesn't reach them. Re-apply
            // here so Settings flips with the appearance picker too.
            .preferredColorScheme(resolvedColorScheme)
        }
    }

    private var tabLayout: some View {
        TabView(selection: $deepLinkRouter.selectedTab) {
            HomeView()
                .tabItem { Label("Feed", systemImage: "music.note") }
                .tag(0)
            UpcomingView()
                .tabItem { Label("Upcoming", systemImage: "calendar") }
                .tag(1)
            Artists()
                .tabItem { Label("Artists", systemImage: "person.2") }
                .tag(2)
            if enableVideosTab {
                VideosView()
                    .tabItem { Label("Videos", systemImage: "play.rectangle") }
                    .tag(3)
            }
            if enableConcertsTab {
                ConcertsView()
                    .tabItem { Label("Concerts", systemImage: "ticket") }
                    .tag(4)
            }
        }
        .tint(.white)
        // simultaneousGesture lets the swipe run alongside the underlying
        // tap recognizers. The minimumDistance + 80pt horizontal threshold
        // (in tabSwitchGesture) make the swipe deliberate, so a casual tap
        // never trips it.
        .simultaneousGesture(tabSwitchGesture)
    }

    /// Sidebar + detail layout for iPad / Mac. Each row uses a Mail/Reminders-style
    /// colored icon tile so the sidebar reads as a hub instead of a flat list, and
    /// a footer card surfaces refresh status without forcing the user to jump to
    /// the Feed toolbar to trigger one.
    private var splitLayout: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
        } detail: {
            detailColumn
                .id(deepLinkRouter.selectedTab)
        }
        .navigationSplitViewStyle(.balanced)
        .tint(AppTheme.accent)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: sidebarSelectionBinding) {
            Section {
                SidebarBadgedRow(destination: .feed, kind: .unreadReleases) { destination, badge in
                    sidebarRow(destination, badge: badge)
                }
                SidebarBadgedRow(destination: .upcoming, kind: .upcomingReleases) { destination, badge in
                    sidebarRow(destination, badge: badge)
                }
                sidebarRow(SidebarDestination.artists, badge: trackedArtistCount)
            } header: {
                Text("Library")
            }

            if enableVideosTab || enableConcertsTab {
                Section {
                    if enableVideosTab { sidebarRow(SidebarDestination.videos) }
                    if enableConcertsTab { sidebarRow(SidebarDestination.concerts) }
                } header: {
                    Text("Discover")
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(AppTheme.background)
        .navigationTitle("Music Notifier")
        .safeAreaInset(edge: .bottom) {
            sidebarFooter
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                // ⌘, is already registered by the .commands block in
                // MusicNotifierApp via `CommandGroup(after: .appSettings)`.
                // Re-declaring it here triggered a hard crash on iPad/Mac
                // when the responder chain tried to install both shortcuts
                // ("Replacement elements contain duplicates" NSException).
                .accessibilityLabel("Settings")
            }
        }
    }

    /// One styled row. The trailing badge is suppressed when zero so the sidebar
    /// stays calm on first launch / empty states.
    private func sidebarRow(_ destination: SidebarDestination, badge: Int? = nil) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(destination.tint.gradient)
                    .frame(width: 28, height: 28)
                Image(systemName: destination.icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
            }
            Text(destination.title)
                .font(.body)
                .foregroundStyle(AppTheme.primaryText)
            Spacer(minLength: 4)
            if let badge, badge > 0 {
                Text("\(badge)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 2)
        .tag(destination.tag)
    }

    /// Footer surfacing tracked-artist count + live refresh status. The button
    /// mirrors Home.swift's toolbar refresh so users in any tab can kick off a
    /// refresh from a single, persistent spot.
    private var sidebarFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider().background(AppTheme.hairline)
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    if refreshCoordinator.isRefreshing {
                        Text(refreshCoordinator.progress?.phase.rawValue ?? "Refreshing")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AppTheme.primaryText)
                        if let p = refreshCoordinator.progress, !p.isIndeterminate, p.totalArtists > 0 {
                            Text("\(p.checkedArtists) / \(p.totalArtists)")
                                .font(.caption2)
                                .foregroundStyle(AppTheme.secondary)
                                .monospacedDigit()
                        } else {
                            Text("Working…")
                                .font(.caption2)
                                .foregroundStyle(AppTheme.secondary)
                        }
                    } else {
                        Text("\(trackedArtistCount) tracked")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AppTheme.primaryText)
                        SidebarReleaseCountText()
                            .font(.caption2)
                            .foregroundStyle(AppTheme.secondary)
                            .monospacedDigit()
                    }
                }
                Spacer(minLength: 0)
                Button {
                    if refreshCoordinator.isRefreshing {
                        refreshCoordinator.cancel()
                    } else {
                        startRefresh()
                    }
                } label: {
                    ZStack {
                        Circle()
                            .fill(AppTheme.accent.opacity(refreshCoordinator.isRefreshing ? 0.25 : 1.0))
                            .frame(width: 32, height: 32)
                        Image(systemName: refreshCoordinator.isRefreshing ? "stop.fill" : "arrow.clockwise")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(refreshCoordinator.isRefreshing ? AppTheme.accent : .white)
                    }
                }
                .buttonStyle(.plain)
                // ⌘R is owned by the "Refresh" command in the Go menu (see
                // MusicNotifierApp.swift). Don't declare it twice — iOS will
                // throw NSException on shortcut installation.
                .disabled(!refreshCoordinator.isRefreshing && trackedArtistCount == 0)
                .accessibilityLabel(refreshCoordinator.isRefreshing ? "Cancel refresh" : "Refresh")
            }
            if refreshCoordinator.isRefreshing,
               let p = refreshCoordinator.progress,
               !p.isIndeterminate,
               p.totalArtists > 0 {
                ProgressView(value: Double(p.checkedArtists), total: Double(p.totalArtists))
                    .progressViewStyle(.linear)
                    .tint(AppTheme.accent)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(AppTheme.background)
    }

    // MARK: - Detail

    @ViewBuilder
    private var detailColumn: some View {
        switch deepLinkRouter.selectedTab {
        case 1: UpcomingView()
        case 2: Artists()
        case 3 where enableVideosTab: VideosView()
        case 4 where enableConcertsTab: ConcertsView()
        default: HomeView()
        }
    }

    // MARK: - Sidebar selection / data

    private var sidebarSelectionBinding: Binding<Int?> {
        Binding(
            get: { deepLinkRouter.selectedTab },
            set: { deepLinkRouter.selectedTab = $0 ?? 0 }
        )
    }

    private var trackedArtistCount: Int {
        artists.lazy.filter(\.isTracked).count
    }

    /// Resolves the user's appearance setting to a SwiftUI `ColorScheme?`.
    /// `nil` means "follow the system", which is what we want for the
    /// default — the previous hardcoded `.dark` ignored the setting entirely
    /// and left sheets like Settings stranded in dark mode even when the
    /// user picked light.
    private var resolvedColorScheme: ColorScheme? {
        switch appearanceRaw {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    /// On-demand fetch for the deep-link handler. Avoids a top-level `@Query` that
    /// would re-fire ContentView body on every refresh save and lag tab switches.
    private func fetchAllReleases() -> [ReleaseData] {
        (try? modelContext.fetch(
            FetchDescriptor<ReleaseData>(sortBy: [SortDescriptor(\.firstSeenAt, order: .reverse)])
        )) ?? []
    }

    private func startRefresh() {
        guard !refreshCoordinator.isRefreshing else { return }
        let tracked = artists.filter(\.isTracked)
        guard !tracked.isEmpty else { return }
        refreshCoordinator.refresh(
            trackedArtists: tracked,
            modelContext: modelContext,
            notificationHour: releaseNotificationHour,
            notificationMinute: releaseNotificationMinute
        )
    }

    /// Swipe between tabs. Conditions that suppress the gesture (each closes a
    /// collision vector):
    ///  • User disabled it in Settings.
    ///  • A child destination is currently pushed in any tab (avoids fighting
    ///    the system back-swipe and protects horizontal scrolls inside details).
    ///  • Drag started in the left-edge gutter (system interactive-pop region).
    ///  • Drag started in the top ~120pt (search bar / large-title area).
    ///  • Drag distance + momentum must both clear high bars — short swipes
    ///    (swipe-to-delete on rows) and horizontal carousels would otherwise
    ///    get hijacked into a tab switch.
    private var tabSwitchGesture: some Gesture {
        DragGesture(minimumDistance: 60)
            .onEnded { value in
                guard swipeBetweenTabs else { return }
                guard navigationDepth.depth == 0 else { return }
                guard value.startLocation.x > 30 else { return }
                guard value.startLocation.y > 120 else { return }

                let dx = value.translation.width
                let dy = value.translation.height
                let pdx = value.predictedEndTranslation.width
                // Must be unambiguously horizontal — a 3:1 ratio cuts out
                // most casual diagonals that incidentally have width.
                guard abs(dx) > abs(dy) * 3.0 else { return }
                // Both a substantial actual drag AND momentum past the
                // halfway-flick threshold. Old logic accepted 90pt drags or
                // 160pt momentum (either/or) which a swipe-to-delete reveal
                // (~70pt with momentum) would clear. The AND + higher
                // numbers reserve this gesture for an intentional page-flip.
                guard abs(dx) > 130 && abs(pdx) > 260 else { return }

                let lastTabIndex: Int = {
                    if enableConcertsTab { return 4 }
                    if enableVideosTab { return 3 }
                    return 2
                }()
                let target: Int
                if dx < 0 && deepLinkRouter.selectedTab < lastTabIndex {
                    target = deepLinkRouter.selectedTab + 1
                } else if dx > 0 && deepLinkRouter.selectedTab > 0 {
                    target = deepLinkRouter.selectedTab - 1
                } else {
                    return
                }

                UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) {
                    deepLinkRouter.selectedTab = target
                }
            }
    }
}

/// Reactive badge for the iPad sidebar. Holds its own `@Query` so a SwiftData
/// release save invalidates *this* row, not the entire ContentView/TabView tree.
private struct SidebarBadgedRow<RowContent: View>: View {
    let destination: SidebarDestination
    let kind: Kind
    @ViewBuilder let row: (SidebarDestination, Int) -> RowContent

    enum Kind { case unreadReleases, upcomingReleases }

    @Query private var releases: [ReleaseData]

    init(
        destination: SidebarDestination,
        kind: Kind,
        @ViewBuilder row: @escaping (SidebarDestination, Int) -> RowContent
    ) {
        self.destination = destination
        self.kind = kind
        self.row = row
        switch kind {
        case .unreadReleases:
            _releases = Query(filter: #Predicate<ReleaseData> { !$0.isSeen })
        case .upcomingReleases:
            // SwiftData #Predicate can't take a captured Date, so we filter the
            // common case (must have a date) in the predicate and the
            // today-cutoff in-memory. The fetched set is still small enough
            // that this isn't a hot path.
            _releases = Query(filter: #Predicate<ReleaseData> { $0.releaseDate != nil })
        }
    }

    var body: some View {
        row(destination, badgeCount)
    }

    private var badgeCount: Int {
        switch kind {
        case .unreadReleases:
            return releases.count
        case .upcomingReleases:
            let today = Calendar.current.startOfDay(for: Date())
            return releases.lazy.filter { ($0.releaseDate ?? .distantPast) >= today }.count
        }
    }
}

/// Total-release count text for the iPad sidebar footer. Same isolation idea
/// as `SidebarBadgedRow` — keep the `@Query` out of `ContentView`'s root.
private struct SidebarReleaseCountText: View {
    @Query private var releases: [ReleaseData]
    var body: some View {
        Text(releases.count == 0 ? "No releases yet" : "\(releases.count) releases")
    }
}

/// Sidebar row metadata. Centralizing this keeps icons / tints / titles / tags
/// in lockstep so adding a new destination is one case, not three.
private enum SidebarDestination {
    case feed, upcoming, artists, videos, concerts

    var title: String {
        switch self {
        case .feed: return "Feed"
        case .upcoming: return "Upcoming"
        case .artists: return "Artists"
        case .videos: return "Videos"
        case .concerts: return "Concerts"
        }
    }

    var icon: String {
        switch self {
        case .feed: return "music.note"
        case .upcoming: return "calendar"
        case .artists: return "person.2.fill"
        case .videos: return "play.rectangle.fill"
        case .concerts: return "ticket.fill"
        }
    }

    var tint: Color {
        switch self {
        case .feed: return AppTheme.accent
        case .upcoming: return Color(red: 0.95, green: 0.55, blue: 0.20)
        case .artists: return Color(red: 0.42, green: 0.55, blue: 0.95)
        case .videos: return Color(red: 0.65, green: 0.35, blue: 0.95)
        case .concerts: return Color(red: 0.20, green: 0.78, blue: 0.55)
        }
    }

    var tag: Int {
        switch self {
        case .feed: return 0
        case .upcoming: return 1
        case .artists: return 2
        case .videos: return 3
        case .concerts: return 4
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [Item.self, ArtistData.self, ReleaseData.self], inMemory: true)
        .environment(RefreshCoordinator())
        .environmentObject(TabNavigationDepth())
}
