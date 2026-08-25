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

    /// A release deep link whose row wasn't in the local store yet.
    ///
    /// A cold launch from a notification tap can easily outrun CloudKit
    /// hydration on a fresh install, and the previous code simply assigned
    /// `selectedRelease = releases.first { ... }` — i.e. `nil` — so the tap
    /// switched to the Feed and then did nothing at all, with no retry and no
    /// explanation. Held here and re-resolved as the store fills in.
    private var pendingReleaseID: String?
    private var pendingSince: Date?

    /// Cap on how long an unresolved deep link keeps retrying. Popping an
    /// album open long after the tap would be jarring.
    private let pendingTimeout: TimeInterval = 60

    var hasPendingRelease: Bool { pendingReleaseID != nil }

    func handle(url: URL, releases: [ReleaseData]) {
        guard let deepLink = MusicNotifierDeepLink(url: url) else { return }

        switch deepLink {
        case .today:
            selectedTab = 0
            clearPending()
        case .release(let releaseID):
            selectedTab = 0
            if let match = releases.first(where: { $0.providerID == releaseID }) {
                clearPending()
                selectedRelease = match
            } else {
                pendingReleaseID = releaseID
                pendingSince = Date()
            }
        }
    }

    /// Retry a deep link that arrived before its release existed locally.
    /// Callers should check `hasPendingRelease` first — it lets them skip
    /// fetching the release table on every store change for nothing.
    func resolvePendingRelease(in releases: [ReleaseData]) {
        guard let pendingReleaseID, let pendingSince else { return }
        guard Date().timeIntervalSince(pendingSince) < pendingTimeout else {
            clearPending()
            return
        }
        guard let match = releases.first(where: { $0.providerID == pendingReleaseID }) else { return }
        clearPending()
        selectedRelease = match
    }

    private func clearPending() {
        pendingReleaseID = nil
        pendingSince = nil
    }
}
