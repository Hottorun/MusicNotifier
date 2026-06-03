//
//  MusicNotifierWidgets.swift
//  MusicNotifierWidgets
//

import SwiftUI
import WidgetKit
import UIKit
import os

// Logger surfaces in Console.app reliably — `print` from widget extensions
// often gets dropped by the system. Filter Console.app on `subsystem:MusicNotifierWidget`
// or search for "MN-WIDGET" to find these.
private let widgetLogger = Logger(subsystem: "MusicNotifierWidget", category: "snapshot")

// MARK: - Shared constants

/// Mirror of `AppSettings.appGroupIdentifier` from the main app target.
/// The widget target can't import `AppSettings` directly without adding the
/// source file to its target membership; declaring the constant here ensures
/// both sides read/write the same container. Keep these in sync — a mismatch
/// silently sends widget reads to a different (empty) container.
enum WidgetConstants {
    static let appGroupIdentifier = "group.com.kern.functional"
}

// MARK: - Snapshot models

struct ReleaseWidgetSnapshot: Codable {
    let generatedAt: Date
    let releases: [ReleaseWidgetItem]
}

struct ReleaseWidgetItem: Codable, Identifiable, Hashable {
    let id: String
    let artistName: String
    let title: String
    let releaseDate: Date?
    let artworkURL: URL?
    let artworkFileName: String?
    let albumURL: URL?
    let type: String
}

struct ReleaseWidgetEntry: TimelineEntry {
    let date: Date
    let releases: [ReleaseWidgetItem]
}

// MARK: - Theme constants (must mirror the app's AppTheme so we don't import it)

private enum WidgetPalette {
    static var accent: Color {
        let defaults = UserDefaults(suiteName: WidgetConstants.appGroupIdentifier)
        switch defaults?.string(forKey: "selectedMusicProvider") {
        case "Spotify":
            return Color(red: 0.114, green: 0.725, blue: 0.329)
        default:
            return Color(red: 0.980, green: 0.141, blue: 0.235)
        }
    }
    static var accentSoft: Color { accent.opacity(0.16) }
    static let darkSurface = Color(red: 0.07, green: 0.07, blue: 0.08)
    static let darkElevatedSurface = Color(red: 0.15, green: 0.15, blue: 0.17)
}

// MARK: - Provider

struct ReleaseWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> ReleaseWidgetEntry {
        ReleaseWidgetEntry(
            date: Date(),
            releases: [
                ReleaseWidgetItem(
                    id: "placeholder",
                    artistName: "Artist",
                    title: "Next Release",
                    releaseDate: Calendar.current.date(byAdding: .day, value: 3, to: Date()),
                    artworkURL: nil,
                    artworkFileName: nil,
                    albumURL: nil,
                    type: "Album"
                )
            ]
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (ReleaseWidgetEntry) -> Void) {
        completion(ReleaseWidgetEntry(date: Date(), releases: WidgetSnapshotStore.loadReleases()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ReleaseWidgetEntry>) -> Void) {
        let releases = WidgetSnapshotStore.loadReleases()
        let now = Date()
        let nextBoundary = nextRefreshDate(from: releases, now: now)
        completion(Timeline(entries: [ReleaseWidgetEntry(date: now, releases: releases)], policy: .after(nextBoundary)))
    }

    private func nextRefreshDate(from releases: [ReleaseWidgetItem], now: Date) -> Date {
        let calendar = Calendar.current
        let nextReleaseBoundary = releases
            .compactMap(\.releaseDate)
            .filter { $0 > now }
            .compactMap { calendar.startOfDay(for: $0) }
            .min()

        return nextReleaseBoundary ?? calendar.date(byAdding: .hour, value: 6, to: now) ?? now.addingTimeInterval(21_600)
    }
}

// MARK: - Snapshot store

private enum WidgetSnapshotStore {
    static func loadReleases() -> [ReleaseWidgetItem] {
        let url = snapshotURL()
        let appGroupContainer = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: WidgetConstants.appGroupIdentifier)
        let fileExists = (url.map { FileManager.default.fileExists(atPath: $0.path) }) ?? false

        // Both Logger (Console.app reliable) AND NSLog (Xcode console reliable
        // when attached to the widget process). Belt-and-suspenders so the
        // user actually sees these.
        widgetLogger.notice("MN-WIDGET group=\(WidgetConstants.appGroupIdentifier, privacy: .public)")
        widgetLogger.notice("MN-WIDGET container=\(appGroupContainer?.path ?? "nil", privacy: .public)")
        widgetLogger.notice("MN-WIDGET snapshotURL=\(url?.path ?? "nil", privacy: .public)")
        widgetLogger.notice("MN-WIDGET fileExists=\(fileExists)")
        NSLog("MN-WIDGET group=%@ container=%@ snapshotURL=%@ fileExists=%@",
              WidgetConstants.appGroupIdentifier,
              appGroupContainer?.path ?? "nil",
              url?.path ?? "nil",
              fileExists ? "true" : "false")

        guard let url,
              let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder.widgetSnapshotDecoder.decode(ReleaseWidgetSnapshot.self, from: data) else {
            widgetLogger.notice("MN-WIDGET returning empty (file missing or decode failed)")
            NSLog("MN-WIDGET returning empty (file missing or decode failed)")
            return []
        }
        widgetLogger.notice("MN-WIDGET decoded \(snapshot.releases.count) releases")
        NSLog("MN-WIDGET decoded %d releases", snapshot.releases.count)
        return snapshot.releases
    }

    private static func snapshotURL() -> URL? {
        let appGroup = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: WidgetConstants.appGroupIdentifier)
        let directory = appGroup ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        return directory?.appendingPathComponent("widget-releases.json")
    }

    static func widgetArtworkDirectory() -> URL? {
        let appGroup = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: WidgetConstants.appGroupIdentifier)
        let directory = appGroup ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        return directory?.appendingPathComponent("WidgetArtwork", isDirectory: true)
    }
}

// MARK: - Shared helpers

private struct WidgetHelpers {
    static func countdownText(for date: Date?) -> String {
        guard let date else { return "Date unknown" }
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return "Out today"
        }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: Date()), to: calendar.startOfDay(for: date)).day ?? 0
        if days <= 0 { return "Out now" }
        return days == 1 ? "Tomorrow" : "In \(days) days"
    }

    static func compactCountdown(for date: Date?) -> String {
        guard let date else { return "—" }
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "TDY" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: Date()), to: calendar.startOfDay(for: date)).day ?? 0
        if days <= 0 { return "OUT" }
        return "\(days)d"
    }

    static var appIsRefreshing: Bool {
        UserDefaults(suiteName: WidgetConstants.appGroupIdentifier)?
            .bool(forKey: "appIsRefreshing") ?? false
    }

    static func cachedArtwork(for release: ReleaseWidgetItem) -> UIImage? {
        guard let artworkFileName = release.artworkFileName,
              let directory = WidgetSnapshotStore.widgetArtworkDirectory() else {
            return nil
        }
        return UIImage(contentsOfFile: directory.appendingPathComponent(artworkFileName).path)
    }
}

// MARK: - Home Screen entry view

/// Countdown pill that adapts to the widget's rendering mode. In `.fullColor`
/// (Home Screen default) it's a solid accent capsule with white text. In
/// `.accented` / `.vibrant` (tinted / lock screen) the colored fill would
/// collapse to the same hue as the text, so we drop the fill and keep just
/// a thin outline + `.primary` foreground that the system can tint cleanly.
private struct CountdownPill: View {
    let text: String
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        Text(text)
            .font(.caption.weight(.bold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .modifier(CountdownPillStyle(renderingMode: renderingMode))
    }
}

/// Compact variant for inline list rows — smaller font, tighter padding.
private struct CompactCountdownPill: View {
    let text: String
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .modifier(CountdownPillStyle(renderingMode: renderingMode))
    }
}

private struct CountdownPillStyle: ViewModifier {
    let renderingMode: WidgetRenderingMode

    func body(content: Content) -> some View {
        if renderingMode == .fullColor {
            content
                .foregroundStyle(Color.white)
                .background(Capsule().fill(WidgetPalette.accent))
        } else {
            content
                .foregroundStyle(.primary)
                .overlay(Capsule().stroke(.primary.opacity(0.55), lineWidth: 1))
        }
    }
}

struct ReleaseHomeWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: ReleaseWidgetProvider.Entry

    private var todayReleases: [ReleaseWidgetItem] {
        entry.releases.filter { release in
            guard let releaseDate = release.releaseDate else { return false }
            return Calendar.current.isDateInToday(releaseDate)
        }
    }

    private var upcomingReleases: [ReleaseWidgetItem] {
        entry.releases
            .filter { ($0.releaseDate ?? .distantFuture) >= Calendar.current.startOfDay(for: Date()) }
            .sorted { ($0.releaseDate ?? .distantFuture) < ($1.releaseDate ?? .distantFuture) }
    }

    private var nextRelease: ReleaseWidgetItem? { upcomingReleases.first }

    var body: some View {
        Group {
            switch family {
            case .systemMedium, .systemLarge:
                todayLayout
            default:
                smallNextLayout
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }

    private var smallNextLayout: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "music.note")
                    .font(.caption2.weight(.semibold))
                Text("NEXT")
                    .font(.caption2.weight(.bold))
                    .tracking(0.8)
                Spacer()
                if WidgetHelpers.appIsRefreshing {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.caption2.weight(.bold))
                }
            }
            .foregroundStyle(WidgetPalette.accent)

            if let release = nextRelease {
                Text(release.title)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Text(release.artistName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                CountdownPill(text: WidgetHelpers.countdownText(for: release.releaseDate))
            } else {
                Text("No upcoming releases")
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Spacer(minLength: 0)
                Text("Open the app to check again")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .widgetURL(nextRelease.map { URL(string: "musicnotifier://release/\($0.id)") } ?? nil)
    }

    private var todayLayout: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "calendar")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(WidgetPalette.accent)
                Text("TODAY")
                    .font(.caption.weight(.bold))
                    .tracking(0.8)
                    .foregroundStyle(WidgetPalette.accent)
                Spacer()
                if WidgetHelpers.appIsRefreshing {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(WidgetPalette.accent)
                }
                if !todayReleases.isEmpty {
                    Text("\(todayReleases.count)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(WidgetPalette.accentSoft))
                }
            }

            if todayReleases.isEmpty {
                if upcomingReleases.isEmpty {
                    Text("Nothing tracked is dropping today")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                } else {
                    // Show the upcoming queue with per-row deep links into each
                    // release, plus the days-until countdown. Container link
                    // intentionally omitted here — each row is its own target.
                    let cap = family == .systemLarge ? 6 : 3
                    ForEach(upcomingReleases.prefix(cap)) { release in
                        Link(destination: deepLink(for: release)) {
                            HStack(spacing: 10) {
                                artworkView(for: release, size: 32)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(release.title)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Text(release.artistName)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 4)
                                CompactCountdownPill(text: WidgetHelpers.compactCountdown(for: release.releaseDate))
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
            } else {
                ForEach(todayReleases.prefix(family == .systemLarge ? 6 : 3)) { release in
                    Link(destination: deepLink(for: release)) {
                        HStack(spacing: 10) {
                            artworkView(for: release, size: 32)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(release.title)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Text(release.artistName)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        // Tap on empty/header areas opens the Today view; row taps deep-link.
        .widgetURL(URL(string: "musicnotifier://today"))
    }

    private func deepLink(for release: ReleaseWidgetItem) -> URL {
        URL(string: "musicnotifier://release/\(release.id)") ?? URL(string: "musicnotifier://today")!
    }

    @ViewBuilder
    private func artworkView(for release: ReleaseWidgetItem, size: CGFloat) -> some View {
        if let image = WidgetHelpers.cachedArtwork(for: release) {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            RoundedRectangle(cornerRadius: 6)
                .fill(WidgetPalette.accentSoft)
                .frame(width: size, height: size)
                .overlay {
                    Image(systemName: "music.note")
                        .font(.caption)
                        .foregroundStyle(WidgetPalette.accent)
                }
        }
    }
}

// MARK: - Upcoming list entry view

struct UpcomingListWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: ReleaseWidgetProvider.Entry

    private var upcoming: [ReleaseWidgetItem] {
        entry.releases
            .filter { ($0.releaseDate ?? .distantFuture) >= Calendar.current.startOfDay(for: Date()) }
            .sorted { ($0.releaseDate ?? .distantFuture) < ($1.releaseDate ?? .distantFuture) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "calendar.badge.clock")
                    .font(.caption.weight(.semibold))
                Text("UPCOMING")
                    .font(.caption.weight(.bold))
                    .tracking(0.8)
                Spacer()
                if WidgetHelpers.appIsRefreshing {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.caption2.weight(.bold))
                }
            }
            .foregroundStyle(WidgetPalette.accent)

            if upcoming.isEmpty {
                Spacer()
                Text("No upcoming releases")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                let cap = family == .systemLarge ? 6 : 3
                ForEach(upcoming.prefix(cap)) { release in
                    HStack(spacing: 10) {
                        Text(WidgetHelpers.compactCountdown(for: release.releaseDate))
                            .font(.caption2.weight(.bold))
                            .monospacedDigit()
                            .foregroundStyle(WidgetPalette.accent)
                            .frame(width: 36, alignment: .leading)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(release.title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Text(release.artistName)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .containerBackground(.fill.tertiary, for: .widget)
        .widgetURL(URL(string: "musicnotifier://upcoming"))
    }
}

// MARK: - Lock-screen accessory entry view

struct LockScreenAccessoryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: ReleaseWidgetProvider.Entry

    private var nextRelease: ReleaseWidgetItem? {
        entry.releases
            .filter { ($0.releaseDate ?? .distantFuture) >= Calendar.current.startOfDay(for: Date()) }
            .sorted { ($0.releaseDate ?? .distantFuture) < ($1.releaseDate ?? .distantFuture) }
            .first
    }

    private var daysAway: Int? {
        guard let date = nextRelease?.releaseDate else { return nil }
        let days = Calendar.current.dateComponents([.day],
                                                   from: Calendar.current.startOfDay(for: Date()),
                                                   to: Calendar.current.startOfDay(for: date)).day
        return days
    }

    var body: some View {
        Group {
            switch family {
            case .accessoryCircular:
                circular
            case .accessoryRectangular:
                rectangular
            case .accessoryInline:
                inline
            default:
                Text("Unsupported")
            }
        }
        .widgetURL(nextRelease.map { URL(string: "musicnotifier://release/\($0.id)") } ?? URL(string: "musicnotifier://today"))
    }

    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            if let days = daysAway, days >= 0 {
                VStack(spacing: 0) {
                    Text(days == 0 ? "OUT" : "\(days)")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .minimumScaleFactor(0.5)
                    Text(days == 1 ? "day" : "days")
                        .font(.system(size: 10, weight: .medium))
                        .opacity(0.7)
                }
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: 18, weight: .semibold))
            }
        }
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Image(systemName: "music.note")
                    .font(.caption2.weight(.bold))
                Text("NEXT RELEASE")
                    .font(.caption2.weight(.bold))
                    .tracking(0.6)
            }
            if let release = nextRelease {
                Text(release.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(release.artistName)
                        .font(.caption2)
                        .lineLimit(1)
                    Text("·")
                        .font(.caption2)
                    Text(WidgetHelpers.countdownText(for: release.releaseDate))
                        .font(.caption2.weight(.semibold))
                }
            } else {
                Text("Nothing upcoming")
                    .font(.subheadline.weight(.semibold))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var inline: some View {
        if let release = nextRelease {
            Text("\(release.artistName) — \(WidgetHelpers.countdownText(for: release.releaseDate))")
        } else {
            Text("No upcoming releases")
        }
    }
}

// MARK: - Widgets

struct MusicNotifierHomeWidget: Widget {
    let kind: String = "MusicNotifierHomeWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ReleaseWidgetProvider()) { entry in
            ReleaseHomeWidgetView(entry: entry)
        }
        .configurationDisplayName("Next & Today")
        .description("See your next or today's tracked releases.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct MusicNotifierUpcomingWidget: Widget {
    let kind: String = "MusicNotifierUpcomingWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ReleaseWidgetProvider()) { entry in
            UpcomingListWidgetView(entry: entry)
        }
        .configurationDisplayName("Upcoming Releases")
        .description("The next few upcoming releases from your tracked artists.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

struct MusicNotifierLockScreenWidget: Widget {
    let kind: String = "MusicNotifierLockScreenWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ReleaseWidgetProvider()) { entry in
            LockScreenAccessoryView(entry: entry)
        }
        .configurationDisplayName("Next Release")
        .description("Countdown to the next tracked release on the lock screen.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

@main
struct MusicNotifierWidgets: WidgetBundle {
    var body: some Widget {
        MusicNotifierHomeWidget()
        MusicNotifierUpcomingWidget()
        MusicNotifierLockScreenWidget()
    }
}

// MARK: - Decoder

private extension JSONDecoder {
    static var widgetSnapshotDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
