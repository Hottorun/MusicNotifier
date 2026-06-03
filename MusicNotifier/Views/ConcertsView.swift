//
//  ConcertsView.swift
//  MusicNotifier
//

import SwiftUI
import SwiftData
import CoreLocation

struct ConcertsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ConcertData.date) private var concerts: [ConcertData]
    @AppStorage(AppSettings.nearbyRadiusKm) private var nearbyRadiusKm: Double = 50
    @AppStorage(AppSettings.useLocationForNearby) private var useLocationForNearby: Bool = false
    @AppStorage(AppSettings.manualCityOverride) private var manualCityOverride: String = ""
    @State private var filter: ConcertFilter = .upcoming
    @State private var searchText: String = ""

    private enum ConcertFilter: String, CaseIterable, Identifiable {
        case upcoming = "Upcoming"
        case nearby = "Nearby"
        case saved = "Saved"
        var id: String { rawValue }

        var icon: String {
            switch self {
            case .upcoming: return "calendar"
            case .nearby: return "location.fill"
            case .saved: return "heart.fill"
            }
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 20) {
                    filterRow
                        .padding(.horizontal, 20)
                    if filteredConcerts.isEmpty {
                        emptyState
                            .padding(.top, 24)
                    } else {
                        if filter == .upcoming, let next = filteredConcerts.first {
                            NextShowHero(concert: next)
                                .padding(.horizontal, 20)
                        }
                        concertList
                    }
                }
                .padding(.top, 4)
                .padding(.bottom, 32)
            }
            .navigationTitle("Concerts")
            .navigationBarTitleDisplayMode(.large)
            .appScreenBackground()
            .searchable(text: $searchText, prompt: "Search venue, city, lineup")
            .navigationDestination(for: ConcertData.self) { concert in
                ConcertDetailView(concert: concert)
            }
        }
        .tint(AppTheme.accent)
    }

    private var filterRow: some View {
        HStack(spacing: 8) {
            ForEach(ConcertFilter.allCases) { option in
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { filter = option }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: option.icon)
                            .font(.caption.weight(.bold))
                        Text(option.rawValue)
                            .font(.footnote.weight(.semibold))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(
                        Capsule().fill(filter == option ? Color.white.opacity(0.95) : AppTheme.elevatedSurface)
                    )
                    .foregroundStyle(filter == option ? AppTheme.background : AppTheme.secondary)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }

    private var concertList: some View {
        let items: [ConcertData] = {
            if filter == .upcoming, !filteredConcerts.isEmpty {
                return Array(filteredConcerts.dropFirst())
            }
            return filteredConcerts
        }()
        return LazyVStack(spacing: 12) {
            ForEach(items) { concert in
                NavigationLink(value: concert) {
                    ConcertTicketRow(concert: concert)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20)
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            EmptyTicketArt()
                .frame(width: 220, height: 130)

            VStack(spacing: 8) {
                Text(emptyTitle)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(AppTheme.primaryText)
                Text(emptySubtitle)
                    .font(.footnote)
                    .foregroundStyle(AppTheme.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            if filter == .nearby && !useLocationForNearby && manualCityOverride.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "gearshape.fill")
                    Text("Set city in Settings")
                }
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Capsule().fill(AppTheme.elevatedSurface))
                .foregroundStyle(AppTheme.primaryText)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private var emptyTitle: String {
        switch filter {
        case .upcoming: return "No upcoming shows"
        case .nearby: return useLocationForNearby ? "No shows in your radius" : "Pick a city"
        case .saved: return "Nothing saved yet"
        }
    }

    private var emptySubtitle: String {
        switch filter {
        case .upcoming:
            return "Tour dates for your tracked artists appear here as soon as Bandsintown returns them."
        case .nearby:
            if useLocationForNearby {
                return "Try a wider radius in Settings → Concerts."
            }
            return manualCityOverride.isEmpty
                ? "Set a city in Settings → Concerts, or turn on location."
                : "No shows near \(manualCityOverride) within \(Int(nearbyRadiusKm)) km."
        case .saved:
            return "Tap the heart on any show to keep it close at hand."
        }
    }

    // MARK: - Filter logic

    private var filteredConcerts: [ConcertData] {
        let now = Date()
        let base: [ConcertData]
        switch filter {
        case .upcoming:
            base = concerts.filter {
                guard $0.dismissedAt == nil, let date = $0.date else { return false }
                return date >= now
            }
        case .nearby:
            base = concertsNearby(now: now)
        case .saved:
            base = concerts.filter { $0.savedAt != nil && $0.dismissedAt == nil }
        }

        guard !searchText.trimmingCharacters(in: .whitespaces).isEmpty else { return base }
        let needle = searchText.lowercased()
        return base.filter {
            $0.venueName.lowercased().contains(needle)
                || $0.city.lowercased().contains(needle)
                || $0.artistName.lowercased().contains(needle)
                || ($0.lineup ?? []).contains(where: { $0.lowercased().contains(needle) })
        }
    }

    private func concertsNearby(now: Date) -> [ConcertData] {
        let defaults = UserDefaults.standard
        let lat = defaults.double(forKey: AppSettings.cachedLatitude)
        let lon = defaults.double(forKey: AppSettings.cachedLongitude)
        guard lat != 0 || lon != 0 else { return [] }
        let user = CLLocation(latitude: lat, longitude: lon)
        let radiusMeters = nearbyRadiusKm * 1000.0

        return concerts.filter {
            guard $0.dismissedAt == nil else { return false }
            guard let date = $0.date, date >= now else { return false }
            guard let venueLat = $0.latitude, let venueLon = $0.longitude else { return false }
            let venue = CLLocation(latitude: venueLat, longitude: venueLon)
            return user.distance(from: venue) <= radiusMeters
        }
    }
}

// MARK: - Hero card for next upcoming show

private struct NextShowHero: View {
    @Environment(\.modelContext) private var modelContext
    let concert: ConcertData

    private var daysAway: Int? {
        guard let date = concert.date else { return nil }
        let cal = Calendar.current
        return cal.dateComponents([.day], from: cal.startOfDay(for: Date()), to: cal.startOfDay(for: date)).day
    }

    private var countdownLabel: String {
        guard let days = daysAway else { return "TBA" }
        if days == 0 { return "TONIGHT" }
        if days == 1 { return "TOMORROW" }
        if days < 7 { return "IN \(days) DAYS" }
        if days < 30 { return "IN \(days / 7) WEEKS" }
        return "IN \(days / 30) MONTHS"
    }

    var body: some View {
        NavigationLink(value: concert) {
            ZStack(alignment: .topLeading) {
                AppTheme.accentGradient

                // Subtle pattern
                GeometryReader { geo in
                    Path { path in
                        let step: CGFloat = 24
                        for i in stride(from: -geo.size.height, through: geo.size.width, by: step) {
                            path.move(to: CGPoint(x: i, y: 0))
                            path.addLine(to: CGPoint(x: i + geo.size.height, y: geo.size.height))
                        }
                    }
                    .stroke(.white.opacity(0.06), lineWidth: 1)
                }

                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        HStack(spacing: 5) {
                            Image(systemName: "sparkles")
                                .font(.caption2.weight(.bold))
                            Text("NEXT SHOW")
                                .font(.caption2.weight(.heavy))
                                .tracking(1.2)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(.white.opacity(0.22)))
                        .foregroundStyle(AppTheme.primaryText)
                        Spacer()
                        Text(countdownLabel)
                            .font(.caption.weight(.heavy))
                            .tracking(1.0)
                            .foregroundStyle(AppTheme.primaryText)
                    }

                    Text(concert.artistName)
                        .font(.system(size: 30, weight: .heavy, design: .rounded))
                        .foregroundStyle(AppTheme.primaryText)
                        .lineLimit(2)

                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Image(systemName: "building.2.fill")
                                .font(.caption.weight(.bold))
                            Text(concert.venueName.isEmpty ? "Venue TBA" : concert.venueName)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                        }
                        HStack(spacing: 6) {
                            Image(systemName: "mappin.and.ellipse")
                                .font(.caption.weight(.bold))
                            Text(locationLabel)
                                .font(.subheadline.weight(.medium))
                                .lineLimit(1)
                        }
                        if let date = concert.date {
                            HStack(spacing: 6) {
                                Image(systemName: "calendar")
                                    .font(.caption.weight(.bold))
                                Text(date.formatted(date: .complete, time: .shortened))
                                    .font(.subheadline.weight(.medium))
                                    .lineLimit(1)
                            }
                        }
                    }
                    .foregroundStyle(.white.opacity(0.92))

                    HStack(spacing: 10) {
                        if concert.ticketURL != nil {
                            HStack(spacing: 6) {
                                Image(systemName: "ticket.fill")
                                Text("Tickets")
                            }
                            .font(.footnote.weight(.bold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background(Capsule().fill(.white))
                            .foregroundStyle(AppTheme.accent)
                        }
                        Button {
                            concert.savedAt = concert.savedAt == nil ? Date() : nil
                            try? modelContext.save()
                        } label: {
                            Image(systemName: concert.savedAt == nil ? "heart" : "heart.fill")
                                .font(.footnote.weight(.bold))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 9)
                                .background(Capsule().fill(.white.opacity(0.22)))
                                .foregroundStyle(AppTheme.primaryText)
                        }
                        .buttonStyle(.plain)
                        Spacer()
                    }
                }
                .padding(20)
            }
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .shadow(color: AppTheme.accent.opacity(0.35), radius: 18, y: 10)
        }
        .buttonStyle(.plain)
    }

    private var locationLabel: String {
        let parts: [String] = [concert.city, concert.region ?? "", concert.country].filter { !$0.isEmpty }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Ticket-stub row

private struct ConcertTicketRow: View {
    @Environment(\.modelContext) private var modelContext
    let concert: ConcertData

    var body: some View {
        HStack(spacing: 0) {
            // Date stub
            VStack(spacing: 2) {
                Text(monthLabel)
                    .font(.system(size: 11, weight: .heavy))
                    .tracking(1.2)
                    .foregroundStyle(.white.opacity(0.85))
                Text(dayLabel)
                    .font(.system(size: 30, weight: .heavy, design: .rounded))
                    .foregroundStyle(AppTheme.primaryText)
                Text(weekdayLabel)
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(.white.opacity(0.75))
            }
            .frame(width: 76)
            .frame(maxHeight: .infinity)
            .background(AppTheme.accentGradient)

            // Perforated divider
            PerforatedDivider()

            // Body
            VStack(alignment: .leading, spacing: 6) {
                Text(concert.artistName)
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(AppTheme.primaryText)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Image(systemName: "building.2.fill")
                        .font(.system(size: 10, weight: .bold))
                    Text(concert.venueName.isEmpty ? "Venue TBA" : concert.venueName)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                }
                .foregroundStyle(AppTheme.secondary)
                HStack(spacing: 5) {
                    Image(systemName: "mappin.and.ellipse")
                        .font(.system(size: 10, weight: .bold))
                    Text(locationLabel)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                }
                .foregroundStyle(AppTheme.secondary)
                if let timeLabel {
                    HStack(spacing: 5) {
                        Image(systemName: "clock.fill")
                            .font(.system(size: 10, weight: .bold))
                        Text(timeLabel)
                            .font(.caption.weight(.medium))
                    }
                    .foregroundStyle(AppTheme.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)

            // Actions
            VStack(spacing: 8) {
                Button {
                    concert.savedAt = concert.savedAt == nil ? Date() : nil
                    try? modelContext.save()
                } label: {
                    Image(systemName: concert.savedAt == nil ? "heart" : "heart.fill")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(concert.savedAt == nil ? AppTheme.secondary : AppTheme.accent)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(AppTheme.elevatedSurface))
                }
                .buttonStyle(.plain)
                if concert.ticketURL != nil {
                    Button {
                        if let url = concert.ticketURL { UIApplication.shared.open(url) }
                    } label: {
                        Image(systemName: "ticket.fill")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(AppTheme.primaryText)
                            .frame(width: 34, height: 34)
                            .background(Circle().fill(AppTheme.accent))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.trailing, 12)
        }
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(AppTheme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(AppTheme.hairline, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contextMenu {
            Button {
                Task { _ = try? await CalendarService().addConcert(concert) }
            } label: {
                Label("Add to Calendar", systemImage: "calendar.badge.plus")
            }
            Button(role: .destructive) {
                concert.dismissedAt = Date()
                try? modelContext.save()
            } label: {
                Label("Dismiss", systemImage: "xmark")
            }
        }
    }

    private var monthLabel: String {
        concert.date?.formatted(.dateTime.month(.abbreviated)).uppercased() ?? "TBA"
    }

    private var dayLabel: String {
        guard let d = concert.date else { return "—" }
        return "\(Calendar.current.component(.day, from: d))"
    }

    private var weekdayLabel: String {
        concert.date?.formatted(.dateTime.weekday(.abbreviated)).uppercased() ?? ""
    }

    private var timeLabel: String? {
        guard let d = concert.date else { return nil }
        let comps = Calendar.current.dateComponents([.hour, .minute], from: d)
        guard (comps.hour ?? 0) != 0 || (comps.minute ?? 0) != 0 else { return nil }
        return d.formatted(date: .omitted, time: .shortened)
    }

    private var locationLabel: String {
        let parts: [String] = [concert.city, concert.region ?? "", concert.country].filter { !$0.isEmpty }
        return parts.joined(separator: ", ")
    }
}

private struct PerforatedDivider: View {
    var body: some View {
        ZStack {
            Rectangle()
                .fill(AppTheme.background)
                .frame(width: 1)
            VStack(spacing: 4) {
                ForEach(0..<14, id: \.self) { _ in
                    Circle()
                        .fill(AppTheme.background)
                        .frame(width: 5, height: 5)
                }
            }
        }
        .frame(width: 5)
        .padding(.vertical, -2)
    }
}

private struct EmptyTicketArt: View {
    var body: some View {
        ZStack {
            // Back ticket
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(AppTheme.elevatedSurface)
                .frame(width: 180, height: 100)
                .rotationEffect(.degrees(-8))
                .offset(x: -22, y: 8)

            // Middle ticket
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(AppTheme.surface)
                .frame(width: 190, height: 105)
                .rotationEffect(.degrees(4))
                .offset(x: 14, y: 4)
                .overlay(
                    HStack(spacing: 6) {
                        Image(systemName: "music.note")
                            .font(.caption.weight(.bold))
                        Text("?")
                            .font(.headline.weight(.heavy))
                    }
                    .foregroundStyle(AppTheme.secondary.opacity(0.5))
                    .rotationEffect(.degrees(4))
                    .offset(x: 14, y: 4)
                )

            // Front ticket
            HStack(spacing: 0) {
                ZStack {
                    AppTheme.accentGradient
                    VStack(spacing: 0) {
                        Text("???")
                            .font(.system(size: 11, weight: .heavy))
                            .tracking(1.2)
                            .foregroundStyle(.white.opacity(0.85))
                        Image(systemName: "ticket.fill")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(AppTheme.primaryText)
                            .padding(.top, 2)
                    }
                }
                .frame(width: 62)

                VStack(alignment: .leading, spacing: 6) {
                    RoundedRectangle(cornerRadius: 3).fill(AppTheme.secondary.opacity(0.35)).frame(width: 90, height: 8)
                    RoundedRectangle(cornerRadius: 3).fill(AppTheme.secondary.opacity(0.22)).frame(width: 70, height: 6)
                    RoundedRectangle(cornerRadius: 3).fill(AppTheme.secondary.opacity(0.22)).frame(width: 55, height: 6)
                }
                .padding(.horizontal, 12)
                Spacer(minLength: 0)
            }
            .frame(width: 200, height: 110)
            .background(AppTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(AppTheme.hairline, lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.4), radius: 12, y: 6)
        }
    }
}
