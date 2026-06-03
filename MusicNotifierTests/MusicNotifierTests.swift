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

    func testArtistImportFilterSkipsAmpersandCollaborations() {
        XCTAssertTrue(ArtistImportFilter.shouldImport(name: "FKA twigs", mode: .all))
        XCTAssertTrue(ArtistImportFilter.shouldImport(name: "FKA twigs", mode: .skipCollaborations))
        XCTAssertFalse(ArtistImportFilter.shouldImport(name: "Artist A & Artist B", mode: .skipCollaborations))
        XCTAssertFalse(ArtistImportFilter.shouldImport(name: "FKA twigs", mode: .favoritesOnly))
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
}
