//
//  ReleaseUtilities.swift
//  MusicNotifier
//

import Foundation

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

        if releaseDate > now {
            return .upcoming
        }

        let daysSinceRelease = calendar.dateComponents([.day], from: releaseDate, to: now).day ?? 0
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

/// Shared lifecycle/category helpers for `ReleaseData`. Moved out of `Home.swift`
/// so views in other files (UpcomingView, etc.) can use them too.
extension ReleaseData {
    var isUpcoming: Bool {
        guard let releaseDate else { return false }
        return releaseDate > Date()
    }

    var daysAgo: Int {
        guard let releaseDate else { return 0 }
        return Calendar.current.dateComponents([.day], from: releaseDate, to: Date()).day ?? 0
    }

    var isNewRelease: Bool {
        guard let releaseDate else { return false }
        return !isUpcoming && (Calendar.current.isDateInToday(releaseDate) || daysAgo <= 14)
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
