//
//  NotificationScheduler.swift
//  MusicNotifier
//

import Foundation
import UserNotifications

/// Sendable snapshot of the fields a release notification needs. Lets the
/// refresh pipeline build the spec list synchronously on MainActor and hand
/// the actual UNUserNotificationCenter writes off to a detached task.
/// `ReleaseData` is a non-Sendable @Model so it can't cross actors directly.
struct ReleaseNotificationSpec: Sendable {
    let providerID: String
    let artistProviderID: String
    let artistName: String
    let title: String
    let releaseDate: Date
    let artworkURL: URL?

    init?(from release: ReleaseData) {
        guard let releaseDate = release.releaseDate else { return nil }
        self.providerID = release.providerID
        self.artistProviderID = release.artistProviderID
        self.artistName = release.artistName
        self.title = release.title
        self.releaseDate = releaseDate
        self.artworkURL = release.artworkURL
    }
}

struct ReleaseSummarySpec: Sendable {
    let providerID: String
    let artistName: String
    let title: String
    let releaseDate: Date?

    init(from release: ReleaseData) {
        self.providerID = release.providerID
        self.artistName = release.artistName
        self.title = release.title
        self.releaseDate = release.releaseDate
    }
}

struct NotificationScheduler {
    func requestAuthorization() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
        } catch {
            return false
        }
    }

    func scheduleNotification(for release: ReleaseData) async {
        await scheduleReleaseDayNotification(for: release, hour: 8, minute: 0)
    }

    // MARK: - Sendable spec API (preferred for off-main scheduling)

    /// Spec-based version of `scheduleReleaseDayNotification`. Safe to call
    /// from any actor since `ReleaseNotificationSpec` is Sendable. The refresh
    /// pipeline builds specs on MainActor then schedules in a detached task
    /// so the main thread isn't blocked on UNUserNotificationCenter writes.
    func scheduleReleaseDayNotification(spec: ReleaseNotificationSpec, hour: Int, minute: Int) async {
        let releaseDate = spec.releaseDate
        let content = UNMutableNotificationContent()
        content.title = "New music from \(spec.artistName)"
        content.body = "\(spec.title) is \(releaseDate > Date() ? "coming soon" : "out now")."
        content.sound = .default
        content.threadIdentifier = "release-artist-\(spec.artistProviderID)"
        content.interruptionLevel = .timeSensitive
        content.targetContentIdentifier = "musicnotifier://release/\(spec.providerID)"
        content.userInfo = ["releaseID": spec.providerID]
        if let attachment = await Self.makeArtworkAttachment(providerID: spec.providerID, artworkURL: spec.artworkURL) {
            content.attachments = [attachment]
        }

        let trigger: UNNotificationTrigger
        let calendar = Calendar.current
        if !calendar.isDateInToday(releaseDate) && releaseDate > Date() {
            let components = NotificationDateBuilder.releaseDayComponents(
                for: releaseDate,
                hour: hour,
                minute: minute,
                calendar: calendar
            )
            trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        } else {
            trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        }

        let request = UNNotificationRequest(
            identifier: "release-\(spec.providerID)",
            content: content,
            trigger: trigger
        )
        try? await UNUserNotificationCenter.current().add(request)
    }

    func schedulePreReleaseAlerts(spec: ReleaseNotificationSpec, hour: Int, minute: Int) async {
        guard spec.releaseDate > Date() else { return }
        let raw = UserDefaults.standard.string(forKey: AppSettings.releasePreAlertDays) ?? ""
        let daysBefore = raw
            .split(separator: ",")
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            .filter { $0 > 0 }
        guard !daysBefore.isEmpty else { return }

        let calendar = Calendar.current
        for days in daysBefore {
            guard let alertDate = calendar.date(byAdding: .day, value: -days, to: spec.releaseDate),
                  alertDate > Date() else { continue }

            let content = UNMutableNotificationContent()
            content.title = "Coming \(days == 1 ? "tomorrow" : "in \(days) days")"
            content.body = "\(spec.artistName) — \(spec.title)"
            content.sound = .default
            content.threadIdentifier = "release-artist-\(spec.artistProviderID)"
            content.interruptionLevel = .active
            content.targetContentIdentifier = "musicnotifier://release/\(spec.providerID)"
            content.userInfo = ["releaseID": spec.providerID, "prealertDays": days]
            if let attachment = await Self.makeArtworkAttachment(providerID: spec.providerID, artworkURL: spec.artworkURL) {
                content.attachments = [attachment]
            }

            let components = NotificationDateBuilder.releaseDayComponents(
                for: alertDate,
                hour: hour,
                minute: minute,
                calendar: calendar
            )
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            let request = UNNotificationRequest(
                identifier: "release-\(spec.providerID)-prealert-\(days)",
                content: content,
                trigger: trigger
            )
            try? await UNUserNotificationCenter.current().add(request)
        }
    }

    func scheduleReleaseSummaryNotification(specs: [ReleaseSummarySpec]) async {
        guard !specs.isEmpty else { return }
        let content = UNMutableNotificationContent()
        content.title = specs.count == 1 ? "1 new release" : "\(specs.count) new releases"

        let uniqueArtists = NSOrderedSet(array: specs.map(\.artistName)).array as? [String] ?? []
        let preview = uniqueArtists.prefix(3).joined(separator: ", ")
        let remaining = uniqueArtists.count - 3
        content.body = remaining > 0 ? "\(preview) and \(remaining) more" : preview
        content.sound = .default
        content.threadIdentifier = "release-day-summary"
        content.interruptionLevel = .timeSensitive
        content.targetContentIdentifier = "musicnotifier://today"

        let request = UNNotificationRequest(
            identifier: "release-summary-\(Date().timeIntervalSince1970)",
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        )
        try? await UNUserNotificationCenter.current().add(request)
    }

    /// Spec-based makeArtworkAttachment — same logic as the @Model version,
    /// reads only the fields the Sendable spec carries.
    private static func makeArtworkAttachment(providerID: String, artworkURL: URL?) async -> UNNotificationAttachment? {
        guard let artworkURL else { return nil }
        let safeID = providerID.replacingOccurrences(of: "/", with: "-")
        let cachedPath = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: AppSettings.appGroupIdentifier)?
            .appendingPathComponent("WidgetArtwork", isDirectory: true)
            .appendingPathComponent("\(safeID).jpg")

        let sourceURL: URL
        if let cachedPath, FileManager.default.fileExists(atPath: cachedPath.path) {
            sourceURL = cachedPath
        } else {
            do {
                let (data, response) = try await URLSession.shared.data(from: artworkURL)
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return nil }
                let tmp = FileManager.default.temporaryDirectory
                    .appendingPathComponent("notif-\(safeID)-\(UUID().uuidString).jpg")
                try data.write(to: tmp, options: [.atomic])
                sourceURL = tmp
            } catch {
                return nil
            }
        }

        return try? UNNotificationAttachment(
            identifier: "artwork-\(safeID)",
            url: sourceURL,
            options: [UNNotificationAttachmentOptionsTypeHintKey: "public.jpeg"]
        )
    }

    // MARK: - ReleaseData API (kept for non-refresh callers)

    func scheduleReleaseDayNotification(for release: ReleaseData, hour: Int, minute: Int) async {
        guard let releaseDate = release.releaseDate else {
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "New music from \(release.artistName)"
        content.body = "\(release.title) is \(releaseDate > Date() ? "coming soon" : "out now")."
        content.sound = .default
        // Group per artist so consecutive releases collapse together in Notification Center.
        content.threadIdentifier = "release-artist-\(release.artistProviderID)"
        // Release day is a real time-sensitive moment — let it break through Focus.
        content.interruptionLevel = .timeSensitive
        content.targetContentIdentifier = "musicnotifier://release/\(release.providerID)"
        content.userInfo = ["releaseID": release.providerID]
        if let attachment = await Self.makeArtworkAttachment(for: release) {
            content.attachments = [attachment]
        }

        let trigger: UNNotificationTrigger
        let calendar = Calendar.current
        if !calendar.isDateInToday(releaseDate) && releaseDate > Date() {
            let dateComponents = NotificationDateBuilder.releaseDayComponents(
                for: releaseDate,
                hour: hour,
                minute: minute,
                calendar: calendar
            )
            trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: false)
        } else {
            trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        }

        let request = UNNotificationRequest(
            identifier: "release-\(release.providerID)",
            content: content,
            trigger: trigger
        )

        try? await UNUserNotificationCenter.current().add(request)
    }

    /// Schedule pre-release heads-up notifications N days before each upcoming
    /// release. Reads the user's preference (comma-separated days) from
    /// AppSettings.releasePreAlertDays.
    func schedulePreReleaseAlerts(for release: ReleaseData, hour: Int, minute: Int) async {
        guard let releaseDate = release.releaseDate, releaseDate > Date() else { return }
        let raw = UserDefaults.standard.string(forKey: AppSettings.releasePreAlertDays) ?? ""
        let daysBefore = raw
            .split(separator: ",")
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            .filter { $0 > 0 }
        guard !daysBefore.isEmpty else { return }

        let calendar = Calendar.current
        for days in daysBefore {
            guard let alertDate = calendar.date(byAdding: .day, value: -days, to: releaseDate),
                  alertDate > Date() else { continue }

            let content = UNMutableNotificationContent()
            content.title = "Coming \(days == 1 ? "tomorrow" : "in \(days) days")"
            content.body = "\(release.artistName) — \(release.title)"
            content.sound = .default
            content.threadIdentifier = "release-artist-\(release.artistProviderID)"
            content.interruptionLevel = .active
            content.targetContentIdentifier = "musicnotifier://release/\(release.providerID)"
            content.userInfo = ["releaseID": release.providerID, "prealertDays": days]
            if let attachment = await Self.makeArtworkAttachment(for: release) {
                content.attachments = [attachment]
            }

            let components = NotificationDateBuilder.releaseDayComponents(
                for: alertDate,
                hour: hour,
                minute: minute,
                calendar: calendar
            )
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            let request = UNNotificationRequest(
                identifier: "release-\(release.providerID)-prealert-\(days)",
                content: content,
                trigger: trigger
            )
            try? await UNUserNotificationCenter.current().add(request)
        }
    }

    func scheduleReleaseSummaryNotification(releases: [ReleaseData]) async {
        guard !releases.isEmpty else {
            return
        }

        let content = UNMutableNotificationContent()
        content.title = releases.count == 1 ? "1 new release" : "\(releases.count) new releases"

        // Tight body: up to 3 artist names, "and N more" tail. Unique artists only — a
        // single artist dropping multiple tracks shouldn't repeat in the preview.
        let uniqueArtists = NSOrderedSet(array: releases.map(\.artistName)).array as? [String] ?? []
        let preview = uniqueArtists.prefix(3).joined(separator: ", ")
        let remaining = uniqueArtists.count - 3
        content.body = remaining > 0 ? "\(preview) and \(remaining) more" : preview
        content.sound = .default
        content.threadIdentifier = "release-day-summary"
        content.interruptionLevel = .timeSensitive
        content.targetContentIdentifier = "musicnotifier://today"

        let request = UNNotificationRequest(
            identifier: "release-summary-\(Date().timeIntervalSince1970)",
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        )

        try? await UNUserNotificationCenter.current().add(request)
    }

    func cancelReleaseNotifications() async {
        let center = UNUserNotificationCenter.current()
        let pendingRequests = await center.pendingNotificationRequests()
        let identifiers = pendingRequests
            .map(\.identifier)
            .filter { identifier in
                identifier.hasPrefix("release-")
            }

        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    func scheduleTestNotification() async {
        let content = UNMutableNotificationContent()
        content.title = "MusicNotifier test"
        content.body = "Notifications are working."
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "test-notification-\(Date().timeIntervalSince1970)",
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 10, repeats: false)
        )

        try? await UNUserNotificationCenter.current().add(request)
    }

    func pendingNotificationCount() async -> Int {
        await UNUserNotificationCenter.current().pendingNotificationRequests().count
    }

    func pendingReleaseNotifications() async -> [PendingReleaseNotification] {
        let requests = await UNUserNotificationCenter.current().pendingNotificationRequests()
        return requests
            .filter { $0.identifier.hasPrefix("release-") }
            .map { request in
                PendingReleaseNotification(
                    identifier: request.identifier,
                    title: request.content.title,
                    body: request.content.body,
                    triggerDescription: triggerDescription(for: request.trigger)
                )
            }
            .sorted { $0.title < $1.title }
    }

    /// Builds a UNNotificationAttachment from the release's artwork.
    /// Prefers the widget's cached file (already in the App Group) and falls back to a one-shot
    /// download into a uniquely-named temp file so UN can copy it into its sandbox.
    private static func makeArtworkAttachment(for release: ReleaseData) async -> UNNotificationAttachment? {
        guard let artworkURL = release.artworkURL else { return nil }

        let safeID = release.providerID.replacingOccurrences(of: "/", with: "-")
        let cachedPath = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: AppSettings.appGroupIdentifier)?
            .appendingPathComponent("WidgetArtwork", isDirectory: true)
            .appendingPathComponent("\(safeID).jpg")

        let sourceURL: URL
        if let cachedPath, FileManager.default.fileExists(atPath: cachedPath.path) {
            sourceURL = cachedPath
        } else {
            do {
                let (data, response) = try await URLSession.shared.data(from: artworkURL)
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    return nil
                }
                let tmp = FileManager.default.temporaryDirectory
                    .appendingPathComponent("notif-\(safeID)-\(UUID().uuidString).jpg")
                try data.write(to: tmp, options: [.atomic])
                sourceURL = tmp
            } catch {
                return nil
            }
        }

        return try? UNNotificationAttachment(
            identifier: "artwork-\(safeID)",
            url: sourceURL,
            options: [UNNotificationAttachmentOptionsTypeHintKey: "public.jpeg"]
        )
    }

    private func releaseDateThreadID(for date: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return "\(components.year ?? 0)-\(components.month ?? 0)-\(components.day ?? 0)"
    }

    private func triggerDescription(for trigger: UNNotificationTrigger?) -> String {
        if let calendarTrigger = trigger as? UNCalendarNotificationTrigger {
            let components = calendarTrigger.dateComponents
            var parts: [String] = []
            if let year = components.year, let month = components.month, let day = components.day {
                parts.append("\(year)-\(String(format: "%02d", month))-\(String(format: "%02d", day))")
            }
            if let hour = components.hour, let minute = components.minute {
                parts.append("\(String(format: "%02d", hour)):\(String(format: "%02d", minute))")
            }
            return parts.isEmpty ? "Calendar trigger" : parts.joined(separator: " ")
        }

        if let intervalTrigger = trigger as? UNTimeIntervalNotificationTrigger {
            return "In \(Int(intervalTrigger.timeInterval)) seconds"
        }

        return "Unknown trigger"
    }
}

struct PendingReleaseNotification: Identifiable, Hashable {
    var id: String { identifier }
    let identifier: String
    let title: String
    let body: String
    let triggerDescription: String
}
