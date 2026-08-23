//
//  ContentView.swift
//  MusicNotifier
//
//  Created by Dimitris Kern on 28.07.25.
//

import SwiftUI
import SwiftData
import UIKit
import CloudKit

/// Tri-state result of the iCloud hydration check we run on first launch.
/// Driven by explicit polling against the SwiftData model context — we
/// don't rely on the routing `@Query` to surface CloudKit-mirrored rows
/// because SwiftData's `@Query` observer doesn't reliably wake up for
/// CloudKit-driven inserts within the same session (rows are in the
/// local store but the view keeps reading "0 artists" until relaunch).
private enum ICloudHydrationOutcome {
    case checking
    case found([ArtistData])
    case empty
}

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
    // Result of the explicit fresh-install hydration check. Drives the
    // loader → welcome / loader → intro routing. The loader's `.task`
    // polls `modelContext.fetch(ArtistData)` directly instead of trusting
    // `@Query` to surface CloudKit-mirrored rows — see the docstring on
    // `ICloudHydrationOutcome` above.
    @State private var iCloudHydration: ICloudHydrationOutcome = .checking
    @State private var showingSettings = false
    @StateObject private var deepLinkRouter = DeepLinkRouter()
    /// App-wide preview player. Lives at the ContentView root so playback
    /// and the floating mini-player survive any navigation. AlbumView and
    /// `GlobalMiniPlayer` both read this instance via `@EnvironmentObject`.
    @StateObject private var previewPlayer = AlbumPreviewPlayer()
    @EnvironmentObject private var navigationDepth: TabNavigationDepth
    @Environment(RefreshCoordinator.self) private var refreshCoordinator
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        Group {
            if !hasCompletedOnboarding {
                if !startFreshOverridden && !hasShownIntro {
                    switch iCloudHydration {
                    case .checking:
                        // Loader polls the model context to see whether
                        // CloudKit mirrors an existing watchlist before we
                        // fall through to Intro. Bypasses `@Query` because
                        // SwiftData's observer can miss CloudKit deliveries
                        // within the same session.
                        iCloudHydrationLoader
                    case .found(let hydrated):
                        // Pass the explicitly-fetched array straight to the
                        // welcome view so its display + actions don't
                        // depend on `@Query` having seen the same rows.
                        ICloudWelcomeView(
                            artistCount: hydrated.count,
                            trackedCount: hydrated.filter(\.isTracked).count,
                            onContinue: {
                                // If iCloud mirrored artists with
                                // isTracked=false (imported but never
                                // tracked on the source device, or the field
                                // didn't round-trip), the Feed would be
                                // empty and the refresh button stays
                                // disabled. Auto-track everything so "use
                                // my iCloud artists" actually does
                                // something.
                                if !hydrated.contains(where: \.isTracked) {
                                    for artist in hydrated { artist.isTracked = true }
                                    try? modelContext.save()
                                }
                                hasCompletedOnboarding = true
                            },
                            onStartFresh: {
                                for artist in hydrated { modelContext.delete(artist) }
                                try? modelContext.save()
                                startFreshOverridden = true
                            }
                        )
                    case .empty:
                        Intro()
                            .onAppear { hasShownIntro = true }
                    }
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
        // Hidden context-menu warmup. The first invocation of
        // `UIContextMenuInteraction` after a cold launch (or after iOS
        // suspends/resumes the app) takes hundreds of ms to initialize —
        // long enough that the user's long-press often lifts off before the
        // menu has time to present, leaving them tapping with no visual
        // feedback. Attaching a `.contextMenu` to a 1×1 transparent view
        // positioned off-screen forces iOS to allocate and wire up the
        // interaction up-front. The view is unreachable so the user can
        // never trigger it.
        //
        // It lives in an `.overlay` rather than as a sibling inside the
        // `Group` above: two children made the Group an implicit stack, and
        // that stack respected the top safe area — which stopped the tab
        // content from ever reaching under the status bar and left a dead
        // strip there that had to be painted flat.
        .overlay(alignment: .topLeading) {
            Color.clear
                .frame(width: 1, height: 1)
                .contextMenu { Button("") {} }
                .accessibilityHidden(true)
                .offset(x: -10_000, y: -10_000)
        }
        .preferredColorScheme(resolvedColorScheme)
        // Mini-player attachment moved to `tabViewBottomAccessory` on the
        // TabView itself (iOS 26 API designed for floating-pill tab bars
        // exactly like ours). The previous `safeAreaInset` here was
        // crushing the system tab bar into a compressed strip.
        .animation(.easeInOut(duration: 0.2), value: previewPlayer.isActive)
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
                // We got it live, so the parked copy is redundant — drop it
                // before the drain below can act on it a second time.
                PendingDeepLink.clear()
                deepLinkRouter.handle(url: url, releases: fetchAllReleases())
            }
        }
        // Drain a tap that landed before this view existed (cold launch from a
        // notification). No-op in the common case.
        .task {
            if let url = PendingDeepLink.take() {
                deepLinkRouter.handle(url: url, releases: fetchAllReleases())
            }
        }
        // A deep-linked release may not have reached this device yet on a fresh
        // install. Re-resolve as CloudKit delivers rows — gated on
        // `hasPendingRelease` so the ordinary case never pays for the fetch.
        .onReceive(NotificationCenter.default.publisher(for: .NSPersistentStoreRemoteChange)) { _ in
            guard deepLinkRouter.hasPendingRelease else { return }
            deepLinkRouter.resolvePendingRelease(in: fetchAllReleases())
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
                    // This sheet is its own NavigationStack, so it needs the
                    // same value-based destinations the tab stacks register —
                    // otherwise tapping the artist name (or a release on the
                    // pushed artist page) is a no-op inside the sheet.
                    .navigationDestination(for: ArtistData.self) { artist in
                        ArtistDetailView(artist: artist)
                    }
                    .navigationDestination(for: ReleaseData.self) { release in
                        AlbumView(release: release)
                    }
            }
            // Sheets present in a separate window root, so
            // `.environmentObject` and `.preferredColorScheme` applied to
            // ContentView don't reach this hierarchy. Re-inject the
            // shared player + router so AlbumView can pick them up.
            .environmentObject(previewPlayer)
            .environmentObject(deepLinkRouter)
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
        // Outermost env-object injection: wraps the whole modifier chain
        // including the safe-area inset (`GlobalMiniPlayer`) and tabs/split
        // layouts below. Sheets explicitly re-inject because they detach
        // from the env tree.
        .environmentObject(previewPlayer)
        .environmentObject(deepLinkRouter)
    }

    /// Shown on a fresh install while we wait to see whether CloudKit
    /// will mirror an existing watchlist. As soon as `artists` becomes
    /// non-empty (handled by the routing logic above), or the timer
    /// fires, or the user taps Skip, this view is replaced.
    ///
    /// 15s is the upper bound: long enough that a real CloudKit pull on
    /// a slow network has a meaningful chance to deliver the first batch
    /// of rows, but bounded so a brand-new user is never permanently
    /// stuck. A Skip button appears after 4s for anyone who knows they
    /// have nothing in iCloud.
    @State private var showICloudSkipButton = false
    private var iCloudHydrationLoader: some View {
        VStack(spacing: 24) {
            VStack(spacing: 16) {
                ProgressView()
                    .controlSize(.large)
                    .tint(AppTheme.accent)
                VStack(spacing: 6) {
                    Text("Restoring from iCloud…")
                        .font(.headline)
                        .foregroundStyle(AppTheme.primaryText)
                    Text("If you've used MusicNotifier before, your watchlist will appear in a moment.")
                        .font(.footnote)
                        .foregroundStyle(AppTheme.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
            }
            if showICloudSkipButton {
                Button {
                    iCloudHydration = .empty
                } label: {
                    Text("Set up as new")
                        .font(.footnote.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(AppTheme.accent)
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.background.ignoresSafeArea())
        .task {
            // Two-phase wait. Phase 1 (first 8s): keep the loader up while
            // we listen for *any* signal that CloudKit is actively
            // syncing — either an `ArtistData` row hits the store, or
            // we see at least one `NSPersistentStoreRemoteChange`
            // notification (which fires when SwiftData merges remote
            // records). Phase 2 (up to 45s total): if CloudKit *did*
            // signal activity in phase 1, keep waiting for actual
            // ArtistData rows; otherwise give up early and route to
            // Intro so a genuinely-new user isn't stuck.
            //
            // We poll the model context directly instead of trusting
            // the routing `@Query`. SwiftData's `@Query` observer can
            // miss CloudKit-driven inserts within the same session
            // (symptom: "had to exit and reopen the app to see my
            // watchlist") — direct fetch always reads live store state.
            Log.v("[HYDRATE] loader appeared, beginning poll")

            // Diagnostic: do we even have an iCloud account on this device,
            // and is the app's CloudKit container reachable? Gated on
            // `Log.verbose` — these are two CloudKit round trips fired on
            // every cold launch that reaches the loader, and nothing reads
            // the result except the log.
            if Log.verbose {
                Task.detached {
                    do {
                        let status = try await CKContainer.default().accountStatus()
                        Log.v("[HYDRATE] CKContainer.default accountStatus = \(status.rawValue) (1=available, 3=noAccount, 4=temporarilyUnavailable)")
                    } catch {
                        Log.v("[HYDRATE] CKContainer.default accountStatus error: \(error)")
                    }
                    do {
                        let named = CKContainer(identifier: "iCloud.com.kern.functional.MusicNotifier")
                        let status = try await named.accountStatus()
                        Log.v("[HYDRATE] named container accountStatus = \(status.rawValue)")
                    } catch {
                        Log.v("[HYDRATE] named container accountStatus error: \(error)")
                    }
                }
            }

            let descriptor = FetchDescriptor<ArtistData>()
            let releaseDescriptor = FetchDescriptor<ReleaseData>()
            let startDate = Date()
            // Short ceiling: the loader is for the lucky case where
            // CloudKit happens to deliver fast. Slow-case users (where
            // hydration takes minutes) get to Intro and can pick the
            // explicit "I already have a watchlist in iCloud" path.
            let initialWait: TimeInterval = 8
            let maxWait: TimeInterval = 8

            // Lightweight box for the remote-change observer to flip
            // without needing actor/atomic gymnastics. `@unchecked Sendable`
            // is sound here and not a shortcut: the observer is registered
            // with `queue: .main`, and every read below happens inside this
            // `.task`, which inherits the view's main-actor isolation — so
            // all access is main-thread serialized.
            final class ActivityFlag: @unchecked Sendable { var fired = false; var count = 0 }
            let activity = ActivityFlag()
            let observer = NotificationCenter.default.addObserver(
                forName: .NSPersistentStoreRemoteChange,
                object: nil,
                queue: .main
            ) { note in
                activity.fired = true
                activity.count += 1
                Log.v("[HYDRATE] NSPersistentStoreRemoteChange #\(activity.count) userInfo=\(note.userInfo ?? [:])")
            }
            defer {
                NotificationCenter.default.removeObserver(observer)
                Log.v("[HYDRATE] loader task exiting, observer removed")
            }

            var pollCount = 0
            while true {
                let elapsed = Date().timeIntervalSince(startDate)
                pollCount += 1

                // Counted only for the log line — skip both table counts
                // entirely when logging is off, otherwise every 750ms tick
                // of the launch loader pays for two full counts it discards.
                if Log.verbose {
                    let artistCount = (try? modelContext.fetchCount(descriptor)) ?? -1
                    let releaseCount = (try? modelContext.fetchCount(releaseDescriptor)) ?? -1
                    Log.v(String(format: "[HYDRATE] poll #%d t=%.1fs artists=%d releases=%d remoteChanges=%d",
                                 pollCount, elapsed, artistCount, releaseCount, activity.count))
                }

                if let fetched = try? modelContext.fetch(descriptor), !fetched.isEmpty {
                    Log.v("[HYDRATE] found \(fetched.count) artists, transitioning to .found")
                    iCloudHydration = .found(fetched)
                    return
                }

                // Reveal the skip button at 5s so a genuinely-new user
                // can opt out without staring at the spinner for 45s.
                if !showICloudSkipButton && elapsed > 5 {
                    await MainActor.run {
                        withAnimation { showICloudSkipButton = true }
                    }
                }

                // Early bail-out: if we've waited the initial window
                // and CloudKit hasn't even signalled a remote change,
                // there's nothing to wait for.
                if elapsed > initialWait && !activity.fired {
                    Log.v("[HYDRATE] no remote-change activity in \(Int(elapsed))s — routing to Intro")
                    iCloudHydration = .empty
                    return
                }

                // Hard ceiling so the loader can't outstay its welcome
                // even if CloudKit is delivering only metadata records
                // (zone setup, change tokens) that never become artists.
                if elapsed > maxWait {
                    Log.v("[HYDRATE] hit \(Int(maxWait))s ceiling — routing to Intro (remoteChanges=\(activity.count))")
                    iCloudHydration = .empty
                    return
                }

                try? await Task.sleep(nanoseconds: 750_000_000)
            }
        }
    }

    private var tabLayout: some View {
        // Custom overlay approach: the TabView never gets a modifier
        // tied to playback state, so its structural identity is
        // permanent and iOS 26 can't reset the selected tab on
        // accessory attach/detach. The mini-player is a sibling
        // overlay in the same ZStack, conditionally rendered, styled
        // to mimic the system's floating glass pill (capsule shape,
        // ultra-thin material, sitting just above the tab-bar pill).
        ZStack(alignment: .bottom) {
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
            // Tint drives the *selected* tab item and every unstyled control
            // inside the tabs (toolbar `Button("Done")`, `.searchable` accents,
            // …). It used to be `.white`, which is invisible on iOS 26's light
            // glass tab bar / toolbar pills — the selected tab and the Add
            // sheet's Done button both disappeared in light mode.
            .tint(AppTheme.accent)
            // simultaneousGesture lets the swipe run alongside the underlying
            // tap recognizers. The minimumDistance + 80pt horizontal threshold
            // (in tabSwitchGesture) make the swipe deliberate, so a casual tap
            // never trips it.
            .simultaneousGesture(tabSwitchGesture)

            if previewPlayer.isActive {
                GlobalMiniPlayer(renderAsCard: true)
                    // Sit close to the tab pill so the two read as a
                    // tight stack.
                    .padding(.bottom, 58)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.22), value: previewPlayer.isActive)
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
        // iPad / Catalyst doesn't have a TabView, so the tabViewBottomAccessory
        // path doesn't apply. Use a safe-area inset on the split layout itself
        // — no floating tab pill underneath here, so the card just sits at
        // the bottom of the detail column.
        .safeAreaInset(edge: .bottom) {
            GlobalMiniPlayer(renderAsCard: true)
        }
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
        .modelContainer(for: [ArtistData.self, ReleaseData.self], inMemory: true)
        .environment(RefreshCoordinator())
        .environmentObject(TabNavigationDepth())
}
