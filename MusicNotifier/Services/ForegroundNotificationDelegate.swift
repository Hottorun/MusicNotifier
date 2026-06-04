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
            NotificationCenter.default.post(name: .musicNotifierDeepLinkTapped, object: url)
        }
        completionHandler()
    }
}
