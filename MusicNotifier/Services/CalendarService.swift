//
//  CalendarService.swift
//  MusicNotifier
//
//  Adds upcoming releases to the user's default calendar via EventKit so the
//  drop date shows up alongside the rest of their life. Uses the iOS 17+ full
//  access API when available, falls back to the legacy access API otherwise.
//

import Foundation
import EventKit

enum CalendarAddError: LocalizedError {
    case denied
    case missingDate

    var errorDescription: String? {
        switch self {
        case .denied: "Calendar access was denied. Enable it in iOS Settings."
        case .missingDate: "This release doesn't have a known date yet."
        }
    }
}

struct CalendarService {
    private let store = EKEventStore()

    /// Add a release as an all-day event on its release date. Returns the
    /// created event identifier so we can store it later if we want to support
    /// "Remove from Calendar" too.
    func addRelease(_ release: ReleaseData) async throws -> String {
        guard let releaseDate = release.releaseDate else { throw CalendarAddError.missingDate }

        try await requestAccess()

        let event = EKEvent(eventStore: store)
        event.title = "\(release.artistName) — \(release.title)"
        event.calendar = store.defaultCalendarForNewEvents
        event.isAllDay = true
        event.startDate = Calendar.current.startOfDay(for: releaseDate)
        event.endDate = Calendar.current.startOfDay(for: releaseDate)
        event.notes = "New release tracked by Music Notifier."
        if let url = release.albumURL {
            event.url = url
        }
        // Gentle 9am alarm on the day-of so the user gets a calendar nudge.
        let alarm = EKAlarm(relativeOffset: 9 * 60 * 60)
        event.addAlarm(alarm)

        try store.save(event, span: .thisEvent)
        return event.eventIdentifier ?? ""
    }

    /// Full access is the only path we need — the deployment target is well
    /// past iOS 17. The pre-17 `requestAccess(to:)` fallback used to live here,
    /// but referencing it also dragged in a `NSCalendarsUsageDescription`
    /// requirement for a branch that could never run.
    private func requestAccess() async throws {
        let granted = try await store.requestFullAccessToEvents()
        guard granted else { throw CalendarAddError.denied }
    }
}
