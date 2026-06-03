//
//  MusicNotifierIntents.swift
//  MusicNotifier
//

import AppIntents
import Foundation
import SwiftData

// MARK: - Shared container

/// Lightweight read access to SwiftData from intent execution context.
@MainActor
enum IntentDataAccess {
    static func makeContainer() throws -> ModelContainer {
        let schema = Schema([Item.self, ArtistData.self, ReleaseData.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    static func trackedArtistIDs(in container: ModelContainer) -> Set<String> {
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<ArtistData>(
            predicate: #Predicate { $0.isTracked }
        )
        guard let artists = try? context.fetch(descriptor) else { return [] }
        return Set(artists.map(\.providerID))
    }

    static func releases(in container: ModelContainer) -> [ReleaseData] {
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<ReleaseData>(
            sortBy: [SortDescriptor(\.releaseDate, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }
}

// MARK: - What's new today

struct WhatsNewTodayIntent: AppIntent {
    static var title: LocalizedStringResource = "What's new today"
    static var description = IntentDescription(
        "Read out any releases from your tracked artists dropping today."
    )

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let container = try IntentDataAccess.makeContainer()
        let trackedIDs = IntentDataAccess.trackedArtistIDs(in: container)
        let releases = IntentDataAccess.releases(in: container)

        let calendar = Calendar.current
        let today = releases.filter { release in
            guard trackedIDs.contains(release.artistProviderID),
                  release.dismissedAt == nil,
                  let releaseDate = release.releaseDate else { return false }
            return calendar.isDateInToday(releaseDate)
        }

        if today.isEmpty {
            return .result(dialog: IntentDialog("No tracked releases are dropping today."))
        }

        let names = today.prefix(5).map { "\($0.title) by \($0.artistName)" }.joined(separator: ", ")
        let extra = today.count > 5 ? " and \(today.count - 5) more" : ""
        return .result(dialog: IntentDialog("Today: \(names)\(extra)."))
    }
}

// MARK: - Next release

struct NextReleaseIntent: AppIntent {
    static var title: LocalizedStringResource = "Next release"
    static var description = IntentDescription(
        "Tell me when the soonest upcoming release from a tracked artist is."
    )

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let container = try IntentDataAccess.makeContainer()
        let trackedIDs = IntentDataAccess.trackedArtistIDs(in: container)
        let releases = IntentDataAccess.releases(in: container)

        let now = Date()
        let next = releases
            .filter { release in
                guard trackedIDs.contains(release.artistProviderID),
                      release.dismissedAt == nil,
                      let date = release.releaseDate, date > now else { return false }
                return true
            }
            .min { ($0.releaseDate ?? .distantFuture) < ($1.releaseDate ?? .distantFuture) }

        guard let next, let date = next.releaseDate else {
            return .result(dialog: IntentDialog("No upcoming releases for your tracked artists."))
        }

        let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: now), to: Calendar.current.startOfDay(for: date)).day ?? 0
        let when: String
        switch days {
        case 0: when = "today"
        case 1: when = "tomorrow"
        default: when = "in \(days) days"
        }
        return .result(dialog: IntentDialog("\(next.title) by \(next.artistName) is out \(when)."))
    }
}

// MARK: - Mark all seen

struct MarkAllSeenIntent: AppIntent {
    static var title: LocalizedStringResource = "Mark all releases as seen"
    static var description = IntentDescription(
        "Clear the unread badge on every release."
    )

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let container = try IntentDataAccess.makeContainer()
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<ReleaseData>(
            predicate: #Predicate { !$0.isSeen }
        )
        let unread = (try? context.fetch(descriptor)) ?? []
        unread.forEach { $0.isSeen = true }
        try? context.save()

        return .result(dialog: IntentDialog("Marked \(unread.count) release\(unread.count == 1 ? "" : "s") as seen."))
    }
}

// MARK: - Shortcuts surface

struct MusicNotifierShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: WhatsNewTodayIntent(),
            phrases: [
                "What's new today in \(.applicationName)",
                "Any new music today in \(.applicationName)",
            ],
            shortTitle: "What's new today",
            systemImageName: "calendar"
        )

        AppShortcut(
            intent: NextReleaseIntent(),
            phrases: [
                "Next release in \(.applicationName)",
                "When is the next release in \(.applicationName)",
            ],
            shortTitle: "Next release",
            systemImageName: "calendar.badge.clock"
        )

        AppShortcut(
            intent: MarkAllSeenIntent(),
            phrases: [
                "Mark all seen in \(.applicationName)",
            ],
            shortTitle: "Mark all seen",
            systemImageName: "checkmark.circle"
        )
    }
}
