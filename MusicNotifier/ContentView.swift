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
    @AppStorage(AppSettings.enableVideosTab) private var enableVideosTab = false
    @AppStorage(AppSettings.enableConcertsTab) private var enableConcertsTab = false
    @Query(sort: \ReleaseData.firstSeenAt, order: .reverse) private var releases: [ReleaseData]
    @Query private var artists: [ArtistData]
    @State private var startFreshOverridden = false
    @StateObject private var deepLinkRouter = DeepLinkRouter()
    @EnvironmentObject private var navigationDepth: TabNavigationDepth
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        Group {
            if !hasCompletedOnboarding {
                if !startFreshOverridden && !artists.isEmpty {
                    // Fresh install + CloudKit hydrated an existing watchlist:
                    // skip the provider/import flow and offer a quick welcome.
                    ICloudWelcomeView(
                        artistCount: artists.count,
                        trackedCount: artists.filter(\.isTracked).count,
                        onStartFresh: {
                            for artist in artists { modelContext.delete(artist) }
                            try? modelContext.save()
                            startFreshOverridden = true
                        }
                    )
                } else {
                    Intro()
                }
            } else if horizontalSizeClass == .regular {
                // iPad / Mac Catalyst / landscape iPhone Pro Max: sidebar layout.
                splitLayout
            } else {
                // iPhone (compact): bottom tab bar.
                tabLayout
            }
        }
        .preferredColorScheme(.dark)
        .onOpenURL { url in
            deepLinkRouter.handle(url: url, releases: releases)
        }
        // Notification tap → broadcasted by ForegroundNotificationDelegate.
        // Route the same way as system deep links so AlbumView pops up.
        .onReceive(NotificationCenter.default.publisher(for: .musicNotifierDeepLinkTapped)) { notification in
            if let url = notification.object as? URL {
                deepLinkRouter.handle(url: url, releases: releases)
            }
        }
        .sheet(item: $deepLinkRouter.selectedRelease) { release in
            NavigationStack {
                AlbumView(release: release)
            }
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

    /// Sidebar + detail layout for iPad / Mac. Mirrors the bottom-tab destinations
    /// as sidebar rows; the selected destination renders to the right.
    private var splitLayout: some View {
        NavigationSplitView {
            List(selection: sidebarSelectionBinding) {
                Section {
                    sidebarRow(title: "Feed", icon: "music.note", tag: 0)
                    sidebarRow(title: "Upcoming", icon: "calendar", tag: 1)
                    sidebarRow(title: "Artists", icon: "person.2", tag: 2)
                    if enableVideosTab {
                        sidebarRow(title: "Videos", icon: "play.rectangle", tag: 3)
                    }
                    if enableConcertsTab {
                        sidebarRow(title: "Concerts", icon: "ticket", tag: 4)
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("Music Notifier")
            .tint(.white)
        } detail: {
            switch deepLinkRouter.selectedTab {
            case 1: UpcomingView()
            case 2: Artists()
            case 3 where enableVideosTab: VideosView()
            case 4 where enableConcertsTab: ConcertsView()
            default: HomeView()
            }
        }
        .tint(.white)
    }

    private var sidebarSelectionBinding: Binding<Int?> {
        Binding(
            get: { deepLinkRouter.selectedTab },
            set: { deepLinkRouter.selectedTab = $0 ?? 0 }
        )
    }

    private func sidebarRow(title: String, icon: String, tag: Int) -> some View {
        Label(title, systemImage: icon)
            .tag(tag)
    }

    /// Swipe between tabs. Conditions that suppress the gesture (each closes a
    /// collision vector):
    ///  • User disabled it in Settings.
    ///  • A child destination is currently pushed in any tab (avoids fighting
    ///    the system back-swipe and protects horizontal scrolls inside details).
    ///  • Drag started in the left-edge gutter (system interactive-pop region).
    ///  • Drag started in the top ~120pt (search bar / large-title area).
    ///  • Predicted end is too small or too vertical — has to be a deliberate
    ///    flick, not a slow ambient drag.
    private var tabSwitchGesture: some Gesture {
        DragGesture(minimumDistance: 50)
            .onEnded { value in
                guard swipeBetweenTabs else { return }
                guard navigationDepth.depth == 0 else { return }
                guard value.startLocation.x > 30 else { return }
                guard value.startLocation.y > 120 else { return }

                let dx = value.translation.width
                let dy = value.translation.height
                let pdx = value.predictedEndTranslation.width
                guard abs(dx) > abs(dy) * 2.0 else { return }
                guard abs(dx) > 90 || abs(pdx) > 160 else { return }

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

#Preview {
    ContentView()
        .modelContainer(for: [Item.self, ArtistData.self, ReleaseData.self], inMemory: true)
        .environmentObject(RefreshCoordinator())
        .environmentObject(TabNavigationDepth())
}
