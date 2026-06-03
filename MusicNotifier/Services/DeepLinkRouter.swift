//
//  DeepLinkRouter.swift
//  MusicNotifier
//

import Foundation
import SwiftUI
import SwiftData

/// Counts how many child destinations are currently pushed across the active
/// `NavigationStack`s. ContentView reads this to disable the tab-swipe gesture
/// whenever the user has drilled into an album/artist/etc., so the gesture only
/// fires on the root of a tab.
@MainActor
final class TabNavigationDepth: ObservableObject {
    @Published private(set) var depth: Int = 0

    func push() { depth += 1 }
    func pop() { depth = max(0, depth - 1) }
}

extension View {
    /// Apply to any pushed destination's root so the global swipe-between-tabs
    /// gesture is suppressed while it's on screen.
    func tracksTabNavigationDepth() -> some View {
        modifier(TabNavigationDepthModifier())
    }
}

private struct TabNavigationDepthModifier: ViewModifier {
    @EnvironmentObject private var tracker: TabNavigationDepth

    func body(content: Content) -> some View {
        content
            .onAppear { tracker.push() }
            .onDisappear { tracker.pop() }
    }
}

enum MusicNotifierDeepLink: Equatable {
    case release(String)
    case today

    init?(url: URL) {
        guard url.scheme == "musicnotifier" else { return nil }

        if url.host == "today" {
            self = .today
            return
        }

        if url.host == "release" {
            let releaseID = url.pathComponents.dropFirst().first
            guard let releaseID, !releaseID.isEmpty else { return nil }
            self = .release(releaseID)
            return
        }

        return nil
    }
}

@MainActor
final class DeepLinkRouter: ObservableObject {
    @Published var selectedTab = 0
    @Published var selectedRelease: ReleaseData?

    func handle(url: URL, releases: [ReleaseData]) {
        guard let deepLink = MusicNotifierDeepLink(url: url) else { return }

        switch deepLink {
        case .today:
            selectedTab = 0
        case .release(let releaseID):
            selectedTab = 0
            selectedRelease = releases.first { $0.providerID == releaseID }
        }
    }
}
