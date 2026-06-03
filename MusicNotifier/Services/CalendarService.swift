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

    /// Add a concert as a 2-hour timed event starting at the show's datetime
    /// (or all-day if the time is missing). Adds the venue as the location and
    /// the ticket link as the event URL.
    func addConcert(_ concert: ConcertData) async throws -> String {
        guard let date = concert.date else { throw CalendarAddError.missingDate }

        try await requestAccess()

        let event = EKEvent(eventStore: store)
        event.title = "\(concert.artistName) — \(concert.venueName.isEmpty ? concert.city : concert.venueName)"
        event.calendar = store.defaultCalendarForNewEvents
        event.startDate = date
        event.endDate = date.addingTimeInterval(2 * 60 * 60)
        let locationParts = [concert.venueName, concert.city, concert.country].filter { !$0.isEmpty }
        event.location = locationParts.joined(separator: ", ")
        event.notes = "Concert tracked by Music Notifier."
        if let url = concert.ticketURL {
            event.url = url
        }
        // Heads-up alarm a day before so the user remembers to leave.
        let alarm = EKAlarm(relativeOffset: -24 * 60 * 60)
        event.addAlarm(alarm)

        try store.save(event, span: .thisEvent)
        return event.eventIdentifier ?? ""
    }

    private func requestAccess() async throws {
        if #available(iOS 17.0, *) {
            let granted = try await store.requestFullAccessToEvents()
            guard granted else { throw CalendarAddError.denied }
        } else {
            let granted: Bool = try await withCheckedThrowingContinuation { continuation in
                store.requestAccess(to: .event) { granted, error in
                    if let error = error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: granted)
                    }
                }
            }
            guard granted else { throw CalendarAddError.denied }
        }
    }
}
