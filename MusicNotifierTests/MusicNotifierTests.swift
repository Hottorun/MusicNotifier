//
//  MusicNotifierTests.swift
//  MusicNotifierTests
//

import XCTest
@testable import MusicNotifier

final class MusicNotifierTests: XCTestCase {
    func testReleaseDeepLinkParsesProviderID() throws {
        let url = try XCTUnwrap(URL(string: "musicnotifier://release/12345"))
        XCTAssertEqual(MusicNotifierDeepLink(url: url), .release("12345"))
    }

    func testTodayDeepLinkParsesHomeRoute() throws {
        let url = try XCTUnwrap(URL(string: "musicnotifier://today"))
        XCTAssertEqual(MusicNotifierDeepLink(url: url), .today)
    }

    func testUnknownDeepLinkIsIgnored() throws {
        let url = try XCTUnwrap(URL(string: "musicnotifier://settings"))
        XCTAssertNil(MusicNotifierDeepLink(url: url))
    }

    func testWidgetSnapshotRoundTripsArtworkFileName() throws {
        let release = WidgetReleaseSnapshot(
            id: "album-1",
            artistName: "Artist",
            title: "Album",
            releaseDate: Date(timeIntervalSince1970: 1_800_000_000),
            artworkURL: URL(string: "https://example.com/art.jpg"),
            artworkFileName: "album-1.jpg",
            albumURL: URL(string: "https://music.apple.com/album/album-1"),
            type: "Album"
        )
        let snapshot = WidgetSnapshot(generatedAt: Date(timeIntervalSince1970: 1_800_000_000), releases: [release])

        let data = try JSONEncoder.widgetSnapshotEncoder.encode(snapshot)
        let decoded = try JSONDecoder.widgetSnapshotDecoder.decode(WidgetSnapshot.self, from: data)

        XCTAssertEqual(decoded.releases.first?.artworkFileName, "album-1.jpg")
        XCTAssertEqual(decoded.releases.first?.id, "album-1")
    }

    func testReleaseClassifierBucketsReleaseDates() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 5, day: 28)))
        let yesterday = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: now))
        let older = try XCTUnwrap(calendar.date(byAdding: .day, value: -30, to: now))
        let tomorrow = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: now))

        XCTAssertEqual(ReleaseClassifier.bucket(for: tomorrow, now: now, calendar: calendar), .upcoming)
        XCTAssertEqual(ReleaseClassifier.bucket(for: yesterday, now: now, calendar: calendar), .new)
        XCTAssertEqual(ReleaseClassifier.bucket(for: older, now: now, calendar: calendar), .past)
        XCTAssertEqual(ReleaseClassifier.bucket(for: nil, now: now, calendar: calendar), .unknown)
    }

    /// `ReleaseData.isUpcoming` / `.isNewRelease` were rewritten from per-call
    /// `Calendar` math into plain `Date` comparisons against cached day
    /// boundaries (they ran in loops over every stored release on the main
    /// thread, on every SwiftData save). This pins the equivalence: the
    /// boundary form must agree with the original calendar form for every
    /// offset around the interesting edges.
    func testDayBoundariesMatchCalendarClassification() throws {
        let day = ReleaseDayBoundaries.snapshot()
        let calendar = Calendar.current
        let now = Date()
        let today = calendar.startOfDay(for: now)

        // Offsets spanning both edges: the upcoming boundary (0/+1) and the
        // 14-day "new" window boundary (-14/-15).
        for offset in [-40, -16, -15, -14, -13, -1, 0, 1, 2, 40] {
            let candidate = try XCTUnwrap(calendar.date(byAdding: .day, value: offset, to: now))
            let candidateDay = calendar.startOfDay(for: candidate)

            // Original: startOfDay(release) > startOfDay(now)
            let expectedUpcoming = candidateDay > today
            XCTAssertEqual(
                candidate >= day.startOfTomorrow, expectedUpcoming,
                "upcoming mismatch at offset \(offset)"
            )

            // Original: !isUpcoming && (isDateInToday || daysAgo <= 14)
            let daysAgo = calendar.dateComponents([.day], from: candidateDay, to: today).day ?? 0
            let expectedNew = !expectedUpcoming
                && (calendar.isDateInToday(candidate) || daysAgo <= ReleaseDayBoundaries.newReleaseWindowDays)
            XCTAssertEqual(
                candidate < day.startOfTomorrow && candidate >= day.newReleaseCutoff, expectedNew,
                "isNewRelease mismatch at offset \(offset)"
            )
        }
    }

    /// The cache must hand back the same boundaries across repeated calls
    /// within a day — that reuse is the entire point of the type.
    func testDayBoundariesAreStableWithinTheSameDay() {
        let first = ReleaseDayBoundaries.snapshot()
        let second = ReleaseDayBoundaries.snapshot()
        XCTAssertEqual(first.startOfToday, second.startOfToday)
        XCTAssertEqual(first.startOfTomorrow, second.startOfTomorrow)
        XCTAssertEqual(first.newReleaseCutoff, second.newReleaseCutoff)
        XCTAssertTrue(first.startOfTomorrow > first.startOfToday)
        XCTAssertTrue(first.newReleaseCutoff < first.startOfToday)
    }

    func testArtistImportFilterSkipsAmpersandCollaborations() {
        XCTAssertTrue(ArtistImportFilter.shouldImport(name: "FKA twigs", mode: .all))
        XCTAssertTrue(ArtistImportFilter.shouldImport(name: "FKA twigs", mode: .skipCollaborations))
        XCTAssertFalse(ArtistImportFilter.shouldImport(name: "Artist A & Artist B", mode: .skipCollaborations))
        // `.favoritesOnly` is enforced upstream by `fetchFavoriteArtists()`,
        // not by this name filter — everything the favorites fetch returns is
        // already a favorite. Asserting `false` here described a filter that,
        // if implemented, would drop every artist a favorites import found.
        XCTAssertTrue(ArtistImportFilter.shouldImport(name: "FKA twigs", mode: .favoritesOnly))
    }

    func testNotificationDateBuilderUsesReleaseDayAndConfiguredTime() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let releaseDate = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 6, day: 5, hour: 18)))

        let components = NotificationDateBuilder.releaseDayComponents(
            for: releaseDate,
            hour: 8,
            minute: 30,
            calendar: calendar
        )

        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 6)
        XCTAssertEqual(components.day, 5)
        XCTAssertEqual(components.hour, 8)
        XCTAssertEqual(components.minute, 30)
    }

    func testReleaseTitleNormalizerDeduplicatesCommonVariants() {
        XCTAssertEqual(ReleaseTitleNormalizer.normalized("Album (Deluxe Edition)"), "album")
        XCTAssertEqual(ReleaseTitleNormalizer.normalized("Album - Remastered"), "album")
        XCTAssertEqual(ReleaseTitleNormalizer.normalized("Album [Explicit]"), "album")
    }

    // MARK: - Library membership

    /// The bug this guards: membership used to be keyed on artist + title, so
    /// adding a single marked the album cut of the same recording as already
    /// in the library and hid its `+` button for good. They're distinct
    /// catalog items and must stay distinguishable.
    func testLibraryMembershipDistinguishesSingleFromAlbumCut() {
        var snapshot = LibraryMembershipSnapshot()
        snapshot.catalogSongIDs = ["single-opalite-1"]

        XCTAssertTrue(snapshot.contains(
            catalogSongID: "single-opalite-1",
            title: "Opalite",
            artistName: "Taylor Swift"
        ))
        XCTAssertFalse(snapshot.contains(
            catalogSongID: "album-opalite-9",
            title: "Opalite",
            artistName: "Taylor Swift"
        ), "the album cut is a different catalog song and is not in the library")
    }

    /// Songs with no catalog identity (uploaded / iTunes-matched) have nothing
    /// to match an ID against, so they keep text matching.
    func testLibraryMembershipFallsBackToTitleOnlyForNonCatalogSongs() {
        var snapshot = LibraryMembershipSnapshot()
        snapshot.titlesByArtistWithoutCatalogID = ["home taping": ["b side"]]

        XCTAssertTrue(snapshot.contains(
            catalogSongID: "whatever",
            title: "B Side",
            artistName: "Home Taping"
        ))
        XCTAssertFalse(snapshot.contains(
            catalogSongID: "whatever",
            title: "Different Song",
            artistName: "Home Taping"
        ))
    }

    /// A catalog song in the library must not leak into the text fallback —
    /// otherwise the original collision comes straight back.
    func testLibraryMembershipCatalogSongsDoNotPopulateTitleFallback() {
        var snapshot = LibraryMembershipSnapshot()
        snapshot.catalogSongIDs = ["single-opalite-1"]
        XCTAssertTrue(snapshot.titlesByArtistWithoutCatalogID.isEmpty)

        // Same title, same artist, different edition → still addable.
        XCTAssertFalse(snapshot.contains(
            catalogSongID: "deluxe-opalite-7",
            title: "Opalite",
            artistName: "Taylor Swift"
        ))
    }

    func testLibraryMembershipEmptySnapshotMatchesNothing() {
        let snapshot = LibraryMembershipSnapshot()
        XCTAssertTrue(snapshot.isEmpty)
        XCTAssertFalse(snapshot.contains(catalogSongID: "x", title: "y", artistName: "z"))
    }

    // MARK: - Notification budget

    private func spec(_ id: String, daysFromNow: Int, now: Date, calendar: Calendar) -> ReleaseNotificationSpec {
        ReleaseNotificationSpec(
            providerID: id,
            artistProviderID: "artist-\(id)",
            artistName: "Artist \(id)",
            title: "Release \(id)",
            releaseDate: calendar.date(byAdding: .day, value: daysFromNow, to: now)!
        )
    }

    /// iOS keeps only 64 pending local notifications per app, so the planner
    /// has to cut the list itself rather than letting the system pick.
    func testReleaseRequestPlanRespectsBudget() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 6, day: 1)))

        let specs = (1...80).map { spec("r\($0)", daysFromNow: $0, now: now, calendar: calendar) }
        let planned = NotificationScheduler.planReleaseRequests(
            specs: specs,
            preAlertDays: [1, 7],
            now: now,
            calendar: calendar,
            budget: 56
        )

        XCTAssertEqual(planned.count, 56)
        XCTAssertEqual(Set(planned.map(\.identifier)).count, 56, "identifiers must be unique")
    }

    /// Sorting is on the fire date, not the release date — an imminent
    /// pre-alert has to outrank a release day months away.
    func testReleaseRequestPlanOrdersByFireDateNearestFirst() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 6, day: 1)))

        let distant = spec("distant", daysFromNow: 90, now: now, calendar: calendar)
        let soon = spec("soon", daysFromNow: 10, now: now, calendar: calendar)

        let planned = NotificationScheduler.planReleaseRequests(
            specs: [distant, soon],
            preAlertDays: [7],
            now: now,
            calendar: calendar,
            budget: 56
        )

        let fireDates = planned.map(\.fireDate)
        XCTAssertEqual(fireDates, fireDates.sorted(), "plan must be nearest-first")
        // "soon" fires its 7-day pre-alert on day 3, ahead of everything from
        // the distant release including that release's own pre-alert.
        XCTAssertEqual(planned.first?.identifier, "release-soon-prealert-7")
    }

    /// A budget smaller than the plan keeps the soonest entries and drops the
    /// tail, rather than truncating in arbitrary spec order.
    func testReleaseRequestPlanKeepsSoonestWhenBudgetIsTight() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 6, day: 1)))

        let specs = [
            spec("far", daysFromNow: 60, now: now, calendar: calendar),
            spec("near", daysFromNow: 2, now: now, calendar: calendar),
        ]
        let planned = NotificationScheduler.planReleaseRequests(
            specs: specs,
            preAlertDays: [],
            now: now,
            calendar: calendar,
            budget: 1
        )

        XCTAssertEqual(planned.map(\.identifier), ["release-near"])
    }

    /// Past releases still get a release-day request (it fires immediately as
    /// an "out now" alert) but must never generate pre-alerts.
    func testReleaseRequestPlanSkipsPreAlertsForPastReleases() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 6, day: 1)))

        let planned = NotificationScheduler.planReleaseRequests(
            specs: [spec("past", daysFromNow: -5, now: now, calendar: calendar)],
            preAlertDays: [1, 7],
            now: now,
            calendar: calendar,
            budget: 56
        )

        XCTAssertEqual(planned.map(\.identifier), ["release-past"])
    }

    // MARK: - Refresh recency window

    func testRecencyGateAcceptsThisWeekAndUpcomingOnly() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 6, day: 10, hour: 12)))

        func day(_ offset: Int) throws -> Date {
            try XCTUnwrap(calendar.date(byAdding: .day, value: offset, to: now))
        }

        // Inside the window: today, a few days back, exactly 7 days back.
        XCTAssertTrue(ReleaseRecencyGate.isWithinWindow(now, now: now, calendar: calendar))
        XCTAssertTrue(ReleaseRecencyGate.isWithinWindow(try day(-3), now: now, calendar: calendar))
        XCTAssertTrue(ReleaseRecencyGate.isWithinWindow(try day(-7), now: now, calendar: calendar))
        // Future drops always pass — the app is built around announcing them.
        XCTAssertTrue(ReleaseRecencyGate.isWithinWindow(try day(30), now: now, calendar: calendar))

        // Outside: anything from before the cutoff day, and undated rows.
        XCTAssertFalse(ReleaseRecencyGate.isWithinWindow(try day(-8), now: now, calendar: calendar))
        XCTAssertFalse(ReleaseRecencyGate.isWithinWindow(try day(-45), now: now, calendar: calendar))
        XCTAssertFalse(ReleaseRecencyGate.isWithinWindow(nil, now: now, calendar: calendar))
    }

    func testRecencyGateFilterDropsStaleFetchedReleases() throws {
        let calendar = Calendar.current
        let now = Date()
        func release(_ id: String, dayOffset: Int?) -> FetchedRelease {
            FetchedRelease(
                providerID: id,
                artistProviderID: "artist",
                artistName: "Artist",
                title: id,
                releaseDate: dayOffset.flatMap { calendar.date(byAdding: .day, value: $0, to: now) },
                artworkURL: nil,
                albumURL: nil,
                provider: MusicProvider.appleMusic.rawValue,
                type: ReleaseKind.album.rawValue
            )
        }

        let filtered = ReleaseRecencyGate.filter(
            [
                release("today", dayOffset: 0),
                release("last-week", dayOffset: -6),
                release("upcoming", dayOffset: 14),
                release("stale", dayOffset: -20),
                release("undated", dayOffset: nil)
            ],
            now: now
        )

        XCTAssertEqual(Set(filtered.map(\.providerID)), ["today", "last-week", "upcoming"])
    }
}
