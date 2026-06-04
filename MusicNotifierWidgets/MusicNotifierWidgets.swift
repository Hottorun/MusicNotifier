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
    @Environment(\.widgetRenderingMode) private var renderingMode
    let entry: ReleaseWidgetProvider.Entry

    private var upcomingReleases: [ReleaseWidgetItem] {
        entry.releases
            .filter { ($0.releaseDate ?? .distantFuture) >= Calendar.current.startOfDay(for: Date()) }
            .sorted { ($0.releaseDate ?? .distantFuture) < ($1.releaseDate ?? .distantFuture) }
    }

    private var nextRelease: ReleaseWidgetItem? { upcomingReleases.first }

    var body: some View {
        Group {
            switch family {
            case .systemSmall:
                smallHero
            case .systemMedium:
                mediumSplit
            case .systemLarge:
                largeLayout
            default:
                smallHero
            }
        }
        .widgetURL(nextRelease.map { URL(string: "musicnotifier://release/\($0.id)") } ?? URL(string: "musicnotifier://today"))
    }

    // MARK: Small — full-bleed artwork hero
    //
    // Important: the artwork lives in `.containerBackground(for: .widget) {...}`,
    // NOT in the body's ZStack. Apple insets widget body content from the
    // rounded widget edge — if the artwork were inside the body it would leave
    // a `.fill.tertiary` (or whichever container fill we set) frame around the
    // image, which is the "huge white rectangle" effect in dark/tinted mode.
    // containerBackground is the only API that actually fills the rounded
    // widget shape edge-to-edge.

    @ViewBuilder
    private var smallHero: some View {
        if let release = nextRelease {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: "music.note")
                        .font(.system(size: 9, weight: .bold))
                    Text("NEXT")
                        .font(.caption2.weight(.bold))
                        .tracking(0.9)
                    Spacer(minLength: 0)
                    if WidgetHelpers.appIsRefreshing {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 9, weight: .bold))
                    }
                }
                .foregroundStyle(heroForeground.opacity(0.9))

                Spacer(minLength: 0)

                Text(release.title)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(heroForeground)
                    .lineLimit(2)
                Text(release.artistName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(heroForeground.opacity(0.85))
                    .lineLimit(1)
                CountdownPill(text: WidgetHelpers.countdownText(for: release.releaseDate))
                    .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .containerBackground(for: .widget) {
                smallHeroBackground(for: release)
            }
        } else {
            emptyState
                .containerBackground(.fill.tertiary, for: .widget)
        }
    }

    /// Background painted by `.containerBackground`. In full-color we layer the
    /// album artwork under a vertical dark gradient that gives the white text
    /// a reliable contrast floor. In tinted/vibrant modes a per-pixel image
    /// gets flattened to luminance and looks muddy — we substitute an accent
    /// gradient instead, which the system tints cleanly.
    @ViewBuilder
    private func smallHeroBackground(for release: ReleaseWidgetItem) -> some View {
        if renderingMode == .fullColor, let image = WidgetHelpers.cachedArtwork(for: release) {
            ZStack {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                LinearGradient(
                    colors: [Color.black.opacity(0), Color.black.opacity(0.35), Color.black.opacity(0.78)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        } else {
            LinearGradient(
                colors: [WidgetPalette.accent.opacity(0.75), WidgetPalette.accent.opacity(0.30)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    /// White text reads well over a full-color artwork+gradient, but in
    /// tinted/vibrant mode the system maps `.white` to flat full-tint which
    /// disappears into the equally-tinted background. `.primary` lets the
    /// system pick the correct luminance for the active rendering mode.
    private var heroForeground: Color {
        renderingMode == .fullColor ? .white : .primary
    }

    // MARK: Medium — left hero, right upcoming list

    @ViewBuilder
    private var mediumSplit: some View {
        if let hero = nextRelease {
            HStack(alignment: .top, spacing: 12) {
                ZStack(alignment: .bottomLeading) {
                    artworkView(for: hero, size: 140, corner: 12)
                    LinearGradient(
                        colors: [Color.black.opacity(0), Color.black.opacity(0.55)],
                        startPoint: .center,
                        endPoint: .bottom
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .allowsHitTesting(false)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(hero.title)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        CountdownPill(text: WidgetHelpers.compactCountdown(for: hero.releaseDate))
                    }
                    .padding(8)
                }
                .frame(width: 140, height: 140)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 4) {
                        Text("UPCOMING")
                            .font(.caption2.weight(.bold))
                            .tracking(0.7)
                            .foregroundStyle(WidgetPalette.accent)
                        Spacer()
                        if WidgetHelpers.appIsRefreshing {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(WidgetPalette.accent)
                        }
                    }
                    // Skip the hero in the side list so the user isn't seeing
                    // the same release twice. Cap at 3 for the medium family.
                    ForEach(Array(upcomingReleases.dropFirst().prefix(3))) { release in
                        compactRow(release)
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(12)
            .containerBackground(.fill.tertiary, for: .widget)
        } else {
            emptyState
                .containerBackground(.fill.tertiary, for: .widget)
        }
    }

    // MARK: Large — hero header + full list

    @ViewBuilder
    private var largeLayout: some View {
        if let hero = nextRelease {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    artworkView(for: hero, size: 92, corner: 12)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("NEXT RELEASE")
                            .font(.caption2.weight(.bold))
                            .tracking(0.8)
                            .foregroundStyle(WidgetPalette.accent)
                        Text(hero.title)
                            .font(.system(size: 17, weight: .bold, design: .rounded))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                        Text(hero.artistName)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        CountdownPill(text: WidgetHelpers.countdownText(for: hero.releaseDate))
                    }
                    Spacer(minLength: 0)
                }

                Divider()

                VStack(spacing: 6) {
                    ForEach(Array(upcomingReleases.dropFirst().prefix(5))) { release in
                        Link(destination: deepLink(for: release)) {
                            compactRow(release)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .containerBackground(.fill.tertiary, for: .widget)
        } else {
            emptyState
                .containerBackground(.fill.tertiary, for: .widget)
        }
    }

    // MARK: Building blocks

    private func compactRow(_ release: ReleaseWidgetItem) -> some View {
        HStack(spacing: 8) {
            artworkView(for: release, size: 30, corner: 6)
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

    @ViewBuilder
    private func artworkView(for release: ReleaseWidgetItem, size: CGFloat, corner: CGFloat = 6) -> some View {
        if renderingMode == .fullColor, let image = WidgetHelpers.cachedArtwork(for: release) {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: corner))
        } else {
            RoundedRectangle(cornerRadius: corner)
                .fill(WidgetPalette.accentSoft)
                .frame(width: size, height: size)
                .overlay {
                    Image(systemName: "music.note")
                        .font(.caption)
                        .foregroundStyle(WidgetPalette.accent)
                }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: "music.note")
                .font(.title3.weight(.bold))
                .foregroundStyle(WidgetPalette.accent)
            Text("No upcoming releases")
                .font(.headline)
                .foregroundStyle(.primary)
            Text("Open the app to check again")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(14)
    }

    private func deepLink(for release: ReleaseWidgetItem) -> URL {
        URL(string: "musicnotifier://release/\(release.id)") ?? URL(string: "musicnotifier://today")!
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
                    Link(destination: URL(string: "musicnotifier://release/\(release.id)") ?? URL(string: "musicnotifier://upcoming")!) {
                        HStack(spacing: 10) {
                            UpcomingArtworkThumb(release: release)

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
                            Text(WidgetHelpers.compactCountdown(for: release.releaseDate))
                                .font(.caption2.weight(.bold))
                                .monospacedDigit()
                                .foregroundStyle(WidgetPalette.accent)
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

/// Small artwork thumb used by the upcoming list rows. Respects the widget
/// rendering mode the same way `ReleaseHomeWidgetView.artworkView` does — tinted
/// and vibrant lock-screen modes fall back to a symbol placeholder instead of a
/// muddy color-mapped image.
private struct UpcomingArtworkThumb: View {
    let release: ReleaseWidgetItem
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        if renderingMode == .fullColor, let image = WidgetHelpers.cachedArtwork(for: release) {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 30, height: 30)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            RoundedRectangle(cornerRadius: 6)
                .fill(WidgetPalette.accentSoft)
                .frame(width: 30, height: 30)
                .overlay {
                    Image(systemName: "music.note")
                        .font(.caption)
                        .foregroundStyle(WidgetPalette.accent)
                }
        }
    }
}

// MARK: - Calendar widget — month grid with release-day dots

struct CalendarWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var renderingMode
    let entry: ReleaseWidgetProvider.Entry

    /// Dates (start-of-day) within the visible month that have at least one
    /// tracked release. We keep both the set (for fast "is this day a release
    /// day?" checks during grid render) and a per-day map for the side list.
    private var releaseDaysByDay: [Date: [ReleaseWidgetItem]] {
        let calendar = Calendar.current
        var out: [Date: [ReleaseWidgetItem]] = [:]
        for release in entry.releases {
            guard let date = release.releaseDate else { continue }
            let day = calendar.startOfDay(for: date)
            out[day, default: []].append(release)
        }
        return out
    }

    private var nextThree: [ReleaseWidgetItem] {
        let today = Calendar.current.startOfDay(for: Date())
        return entry.releases
            .filter { ($0.releaseDate ?? .distantFuture) >= today }
            .sorted { ($0.releaseDate ?? .distantFuture) < ($1.releaseDate ?? .distantFuture) }
            .prefix(family == .systemLarge ? 5 : 3)
            .map { $0 }
    }

    var body: some View {
        Group {
            switch family {
            case .systemLarge:
                largeBody
            default:
                mediumBody
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
        .widgetURL(URL(string: "musicnotifier://upcoming"))
    }

    private var mediumBody: some View {
        HStack(alignment: .top, spacing: 12) {
            calendarGrid(cellSize: 16, spacing: 4)
                .frame(maxWidth: .infinity)
            sideList
                .frame(maxWidth: .infinity)
        }
        .padding(12)
    }

    private var largeBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(monthLabel.uppercased())
                    .font(.caption.weight(.bold))
                    .tracking(0.9)
                    .foregroundStyle(WidgetPalette.accent)
                Spacer()
                Text("\(releaseDaysByDay.values.reduce(0) { $0 + $1.count }) releases")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            calendarGrid(cellSize: 30, spacing: 6)
            Divider()
            VStack(spacing: 6) {
                ForEach(nextThree) { release in
                    Link(destination: URL(string: "musicnotifier://release/\(release.id)") ?? URL(string: "musicnotifier://upcoming")!) {
                        listRow(release)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
    }

    // MARK: Grid

    private func calendarGrid(cellSize: CGFloat, spacing: CGFloat) -> some View {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let monthInterval = calendar.dateInterval(of: .month, for: today) ?? DateInterval(start: today, duration: 0)
        let firstWeekday = calendar.component(.weekday, from: monthInterval.start)
        // Convert weekday (1=Sun) into a leading-blank count so day 1 aligns
        // under the right column header. Treats Sunday as the first column.
        let leadingBlanks = firstWeekday - calendar.firstWeekday
        let daysInMonth = calendar.range(of: .day, in: .month, for: today)?.count ?? 30
        let totalCells = leadingBlanks + daysInMonth
        let weeks = Int(ceil(Double(totalCells) / 7.0))

        let releaseDays = releaseDaysByDay

        return VStack(alignment: .leading, spacing: spacing) {
            HStack(spacing: spacing) {
                ForEach(weekdaySymbols, id: \.self) { symbol in
                    Text(symbol)
                        .font(.system(size: max(8, cellSize * 0.42), weight: .bold))
                        .tracking(0.4)
                        .foregroundStyle(.secondary)
                        .frame(width: cellSize, height: cellSize * 0.7)
                }
            }

            ForEach(0..<weeks, id: \.self) { week in
                HStack(spacing: spacing) {
                    ForEach(0..<7, id: \.self) { weekday in
                        let cellIndex = week * 7 + weekday
                        let dayNumber = cellIndex - leadingBlanks + 1
                        if dayNumber >= 1 && dayNumber <= daysInMonth,
                           let dayDate = calendar.date(byAdding: .day, value: dayNumber - 1, to: monthInterval.start) {
                            calendarCell(
                                dayNumber: dayNumber,
                                isToday: calendar.isDate(dayDate, inSameDayAs: today),
                                releaseCount: releaseDays[calendar.startOfDay(for: dayDate)]?.count ?? 0,
                                cellSize: cellSize
                            )
                        } else {
                            Color.clear.frame(width: cellSize, height: cellSize)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func calendarCell(dayNumber: Int, isToday: Bool, releaseCount: Int, cellSize: CGFloat) -> some View {
        // Tinted/vibrant render modes flatten any colored fill to the system's
        // tint luminance (~white on dark tints), which made the previous
        // `Circle().fill(accent)` cover the day number with a solid white blob.
        // Use a stroked ring in those modes and switch the number's color to
        // `.primary` so the system can pick the right contrast for us.
        let isFullColor = renderingMode == .fullColor

        ZStack {
            if isToday {
                if isFullColor {
                    Circle()
                        .fill(WidgetPalette.accent)
                        .frame(width: cellSize, height: cellSize)
                } else {
                    Circle()
                        .strokeBorder(.primary, lineWidth: max(1, cellSize * 0.05))
                        .frame(width: cellSize, height: cellSize)
                }
            } else if releaseCount > 0 && isFullColor {
                Circle()
                    .fill(WidgetPalette.accentSoft)
                    .frame(width: cellSize, height: cellSize)
            }
            Text("\(dayNumber)")
                .font(.system(size: max(8, cellSize * 0.45), weight: isToday ? .bold : .medium))
                .foregroundStyle(dayNumberColor(isToday: isToday, releaseCount: releaseCount, isFullColor: isFullColor))
                .monospacedDigit()
            if releaseCount > 0 && !isToday {
                // Small marker below the number. Filled dot in full color,
                // primary dot in tinted modes — either way distinct from a
                // plain weekday.
                Group {
                    if isFullColor {
                        Circle().fill(WidgetPalette.accent)
                    } else {
                        Circle().fill(.primary)
                    }
                }
                .frame(width: max(3, cellSize * 0.13), height: max(3, cellSize * 0.13))
                .offset(y: cellSize * 0.32)
            }
        }
        .frame(width: cellSize, height: cellSize)
    }

    private func dayNumberColor(isToday: Bool, releaseCount: Int, isFullColor: Bool) -> Color {
        if isToday {
            return isFullColor ? .white : .primary
        }
        if releaseCount > 0 {
            return isFullColor ? WidgetPalette.accent : .primary
        }
        return .primary
    }

    // MARK: Side list (medium)

    private var sideList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(monthLabel.uppercased())
                .font(.caption2.weight(.bold))
                .tracking(0.7)
                .foregroundStyle(WidgetPalette.accent)
            if nextThree.isEmpty {
                Text("No upcoming")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(nextThree) { release in
                    Link(destination: URL(string: "musicnotifier://release/\(release.id)") ?? URL(string: "musicnotifier://upcoming")!) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(release.title)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            HStack(spacing: 4) {
                                Text(release.artistName)
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                Spacer(minLength: 2)
                                Text(WidgetHelpers.compactCountdown(for: release.releaseDate))
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(WidgetPalette.accent)
                            }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func listRow(_ release: ReleaseWidgetItem) -> some View {
        HStack(spacing: 8) {
            UpcomingArtworkThumb(release: release)
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

    private var weekdaySymbols: [String] {
        let calendar = Calendar.current
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        // Rotate so position 0 matches calendar.firstWeekday (1=Sun in en_US).
        let first = calendar.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }

    private var monthLabel: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        return formatter.string(from: Date())
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

struct MusicNotifierCalendarWidget: Widget {
    let kind: String = "MusicNotifierCalendarWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ReleaseWidgetProvider()) { entry in
            CalendarWidgetView(entry: entry)
        }
        .configurationDisplayName("Release Calendar")
        .description("This month at a glance — release days highlighted.")
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
        MusicNotifierCalendarWidget()
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
