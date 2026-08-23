//
//  ForegroundNotificationDelegate.swift
//  MusicNotifier
//

import Foundation
import UserNotifications

extension Notification.Name {
    /// Broadcast when the user taps a release-related notification. The object
    /// is the destination URL (`musicnotifier://release/<id>` or
    /// `musicnotifier://today`). ContentView subscribes and routes via DeepLinkRouter.
    static let musicNotifierDeepLinkTapped = Notification.Name("musicNotifierDeepLinkTapped")

    /// Posted by Mac/iPad menu commands. Object is the destination tab index
    /// (Int). ContentView's sidebar layout listens and updates its selection.
    static let musicNotifierSelectTab = Notification.Name("musicNotifierSelectTab")

    /// Posted by the ⌘R menu command. Whoever currently owns refresh state
    /// (Home view / sidebar footer) starts a refresh.
    static let musicNotifierRequestRefresh = Notification.Name("musicNotifierRequestRefresh")

    /// Posted by the ⌘, menu command. ContentView opens the settings sheet.
    static let musicNotifierOpenSettings = Notification.Name("musicNotifierOpenSettings")
}

/// Parking spot for a deep link that arrived before the UI was listening.
///
/// On a cold launch from a notification tap, `didReceive` fires while the scene
/// is still being built — often before `ContentView` has subscribed to
/// `.musicNotifierDeepLinkTapped`. A bare `NotificationCenter.post` at that
/// moment goes nowhere and the tap is silently dropped, which for this app
/// means "I tapped a new-release alert and it just opened the Feed." The
/// delegate parks the URL here as well as posting it, and ContentView drains it
/// on appear, so no ordering loses the tap.
@MainActor
enum PendingDeepLink {
    private static var stored: (url: URL, receivedAt: Date)?

    /// A parked tap is only worth honouring briefly — surfacing an album the
    /// user tapped several minutes ago would be surprising, not helpful.
    private static let maxAge: TimeInterval = 60

    static func store(_ url: URL) {
        stored = (url, Date())
    }

    /// Returns and clears the parked link, if it's still fresh.
    static func take() -> URL? {
        guard let entry = stored else { return nil }
        stored = nil
        guard Date().timeIntervalSince(entry.receivedAt) < maxAge else { return nil }
        return entry.url
    }

    /// Drop the parked link because a live post already handled it.
    static func clear() {
        stored = nil
    }
}

/// Without this delegate, iOS suppresses notifications while the app is in the foreground.
/// Setting it as `UNUserNotificationCenter.current().delegate` ensures the test notification
/// and same-day release alerts actually show as banners even when the user is in the app.
final class ForegroundNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .badge, .list])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let content = response.notification.request.content
        let url: URL? = {
            // 1) Explicit targetContentIdentifier (most reliable).
            if let identifier = content.targetContentIdentifier,
               let parsed = URL(string: identifier) { return parsed }
            // 2) Fallback to releaseID in userInfo.
            if let releaseID = content.userInfo["releaseID"] as? String,
               let parsed = URL(string: "musicnotifier://release/\(releaseID)") { return parsed }
            return nil
        }()

        if let url {
            // Park *and* post: the park covers a cold launch where nothing is
            // subscribed yet, the post covers a tap while the app is already
            // on screen. Whichever lands first clears the other.
            Task { @MainActor in
                PendingDeepLink.store(url)
                NotificationCenter.default.post(name: .musicNotifierDeepLinkTapped, object: url)
            }
        }
        completionHandler()
    }
}
