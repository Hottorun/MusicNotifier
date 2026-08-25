//
//  ReleaseUtilities.swift
//  MusicNotifier
//

import Foundation

/// Single source of truth for the refresh recency window.
///
/// A refresh must never pull in anything that dropped more than a week ago —
/// every fetch path (Apple REST primary, Apple appears-on, the MusicKit
/// relationship fallback, label `latestReleases`, Spotify) narrows its own
/// query with `windowDays`, and the upsert actor re-applies `filter` as the
/// last gate before anything is written to SwiftData. Future-dated rows always
/// pass — upcoming drops are the point of the app. Rows with no release date
/// can't be proven recent, so they're dropped.
enum ReleaseRecencyGate {
    /// Releases older than this many days are never imported by a refresh.
    static let windowDays = 7

    /// Start of the oldest day a refresh may import. Day-granular so a release
    /// dated exactly 7 days ago isn't dropped by a few hours of clock drift
    /// (Apple hands back date-only strings parsed as UTC midnight).
    static func cutoff(now: Date = Date(), calendar: Calendar = .current) -> Date {
        let today = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: -windowDays, to: today) ?? today
    }

    static func isWithinWindow(_ releaseDate: Date?, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard let releaseDate else { return false }
        if releaseDate > now { return true }
        return releaseDate >= cutoff(now: now, calendar: calendar)
    }

    static func filter(_ releases: [FetchedRelease], now: Date = Date()) -> [FetchedRelease] {
        let cutoff = cutoff(now: now)
        return releases.filter { release in
            guard let date = release.releaseDate else { return false }
            return date > now || date >= cutoff
        }
    }
}

enum ReleaseDateBucket: Equatable {
    case upcoming
    case new
    case past
    case unknown
}

enum ReleaseClassifier {
    static func bucket(
        for releaseDate: Date?,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> ReleaseDateBucket {
        guard let releaseDate else {
            return .unknown
        }

        let today = calendar.startOfDay(for: now)
        let releaseDay = calendar.startOfDay(for: releaseDate)
        if releaseDay > today {
            return .upcoming
        }

        let daysSinceRelease = calendar.dateComponents([.day], from: releaseDay, to: today).day ?? 0
        return daysSinceRelease <= 14 ? .new : .past
    }
}

enum ArtistImportFilter {
    static func shouldImport(name: String, mode: ArtistImportMode) -> Bool {
        switch mode {
        case .all:
            return true
        case .skipCollaborations:
            return !name.contains("&")
        case .favoritesOnly:
            return true
        }
    }
}

/// Day boundaries, computed once per calendar day and reused by every
/// `ReleaseData` classification.
///
/// `isUpcoming` / `isNewRelease` used to build `Calendar.current` and run
/// `startOfDay(for:)` two-to-four times *per release*. The feed derivations
/// (`HomeView.computeDerived`, `Artists.artistSummaries`,
/// `UpcomingView.makeUpcomingDerived`) call them in loops over every stored
/// release, and those loops re-run on every SwiftData save — so a refresh on a
/// library with a few thousand releases was burning tens of thousands of
/// calendar computations on the main thread per batch flush. That was the
/// dominant source of the scroll hitch during a fetch.
///
/// Both boundaries are day-aligned, so the per-release test collapses to a
/// plain `Date` comparison with zero calendar work:
///   `startOfDay(release) > startOfDay(now)`  ⟺  `release >= startOfTomorrow`
///   `daysAgo(release) <= 14`                 ⟺  `release >= newReleaseCutoff`
/// (A day-aligned bound `M` satisfies `startOfDay(x) >= M ⟺ x >= M`.)
///
/// The cache is recomputed lazily whenever `now` falls outside the cached day,
/// which also covers timezone changes that shift the boundary.
enum ReleaseDayBoundaries {
    /// Number of days a released item stays in the "new" bucket.
    static let newReleaseWindowDays = 14

    struct Snapshot: Sendable {
        /// Start of the day *after* today. `releaseDate >= this` ⟺ upcoming.
        let startOfTomorrow: Date
        /// Start of the day `newReleaseWindowDays` before today.
        /// `releaseDate >= this` (and not upcoming) ⟺ new.
        let newReleaseCutoff: Date
        /// Start of today — retained so callers that need it don't recompute.
        let startOfToday: Date
    }

    nonisolated(unsafe) private static var cached: Snapshot?
    private static let lock = NSLock()

    /// Day boundaries valid for `now`. Cheap on the hot path: one lock, two
    /// date comparisons, and a return of a cached value.
    static func snapshot(now: Date = Date()) -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        if let cached, now < cached.startOfTomorrow, now >= cached.startOfToday {
            return cached
        }
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: now)
        let fresh = Snapshot(
            startOfTomorrow: calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? startOfToday,
            newReleaseCutoff: calendar.date(
                byAdding: .day,
                value: -newReleaseWindowDays,
                to: startOfToday
            ) ?? startOfToday,
            startOfToday: startOfToday
        )
        cached = fresh
        return fresh
    }
}

/// Shared lifecycle/category helpers for `ReleaseData`. Moved out of `Home.swift`
/// so views in other files (UpcomingView, etc.) can use them too.
extension ReleaseData {
    var isUpcoming: Bool {
        guard let releaseDate else { return false }
        return releaseDate >= ReleaseDayBoundaries.snapshot().startOfTomorrow
    }

    var daysAgo: Int {
        guard let releaseDate else { return 0 }
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let releaseDay = cal.startOfDay(for: releaseDate)
        return cal.dateComponents([.day], from: releaseDay, to: today).day ?? 0
    }

    var isNewRelease: Bool {
        guard let releaseDate else { return false }
        let day = ReleaseDayBoundaries.snapshot()
        return releaseDate < day.startOfTomorrow && releaseDate >= day.newReleaseCutoff
    }

    var isPastRelease: Bool {
        guard releaseDate != nil else { return false }
        return !isUpcoming && !isNewRelease
    }

    var hasUnknownReleaseDate: Bool { releaseDate == nil }

    var formattedReleaseDate: String {
        guard let releaseDate else { return "Date unknown" }
        return releaseDate.formatted(date: .abbreviated, time: .omitted)
    }

    var kind: ReleaseKind {
        ReleaseKind(rawValue: type) ?? .album
    }
}

/// Strips Apple Music's redundant " - Single" / " - EP" / " - Album" suffixes
/// from a release title. The release-type chip already conveys the type, so the
/// suffix just truncates the actual title in compact rows. Case-preserving.
enum ReleaseTitleFormatter {
    static func displayTitle(_ title: String) -> String {
        let pattern = #"\s*-\s*(Single|EP|Album)\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return title
        }
        let range = NSRange(title.startIndex..., in: title)
        let stripped = regex.stringByReplacingMatches(in: title, options: [], range: range, withTemplate: "")
        return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum ReleaseTitleNormalizer {
    static func normalized(_ title: String) -> String {
        var lower = title.lowercased()
        let patterns = [
            #"\s*\((deluxe|deluxe edition|expanded|expanded edition|remastered|remaster|live|clean|explicit|commentary|anniversary|anniversary edition|special edition|bonus track version|tour edition|extended)\)"#,
            #"\s*-\s*(deluxe|deluxe edition|expanded|remastered|live|clean|explicit|single|ep)$"#,
            #"\s+\[(deluxe|live|clean|explicit|remastered).*\]"#
        ]

        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                let range = NSRange(lower.startIndex..., in: lower)
                lower = regex.stringByReplacingMatches(in: lower, options: [], range: range, withTemplate: "")
            }
        }

        return lower.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum NotificationDateBuilder {
    static func releaseDayComponents(
        for releaseDate: Date,
        hour: Int,
        minute: Int,
        calendar: Calendar = .current
    ) -> DateComponents {
        var dateComponents = calendar.dateComponents([.year, .month, .day], from: releaseDate)
        dateComponents.hour = hour
        dateComponents.minute = minute
        return dateComponents
    }
}
