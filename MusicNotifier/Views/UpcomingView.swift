//
//  UpcomingView.swift
//  MusicNotifier
//
//  Top-level tab showing announced-but-unreleased records from tracked artists.
//  Three layouts (list / grid / calendar) accessible via the header toggle;
//  the redesigned list mode is the default. The inline type filter is gone —
//  global per-kind visibility (Settings → View) is the only kind filter.
//

import SwiftUI
import SwiftData
import UIKit

private enum UpcomingLayout: String, CaseIterable, Identifiable {
    case list = "list"
    case grid = "grid"
    case calendar = "calendar"
    var id: String { rawValue }
    var systemImage: String {
        switch self {
        case .list: "list.bullet"
        case .grid: "square.grid.2x2.fill"
        case .calendar: "calendar"
        }
    }
}

enum CalendarDirection: String, CaseIterable, Identifiable {
    case future = "future"
    case past = "past"
    case balanced = "balanced"
    var id: String { rawValue }
    /// Short label (fits inline in a menu picker without wrapping).
    var label: String {
        switch self {
        case .future: "Forward"
        case .past: "Backward"
        case .balanced: "Balanced"
        }
    }
    /// Longer description used in the Settings footer.
    var description: String {
        switch self {
        case .future: "This month + next month"
        case .past: "Last month + this month"
        case .balanced: "Last, this, and next month"
        }
    }
}

struct UpcomingView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<ArtistData> { artist in
        artist.isTracked
    }, sort: \ArtistData.name) private var trackedArtists: [ArtistData]
    @Query(sort: \ReleaseData.releaseDate) private var storedReleases: [ReleaseData]
    @AppStorage("upcomingLayout") private var layoutRaw = UpcomingLayout.list.rawValue
    @AppStorage(AppSettings.upcomingCalendarDirection) private var calendarDirectionRaw = CalendarDirection.future.rawValue
    @AppStorage(AppSettings.showAlbums) private var showAlbums = true
    @AppStorage(AppSettings.showSingles) private var showSingles = true
    @AppStorage(AppSettings.showEPs) private var showEPs = true
    @AppStorage(AppSettings.showLiveAlbums) private var showLiveAlbums = true
    @AppStorage(AppSettings.showCompilations) private var showCompilations = true
    @AppStorage(AppSettings.showRemixes) private var showRemixes = true
    @State private var selectedDay: Date?

    private var layout: UpcomingLayout {
        UpcomingLayout(rawValue: layoutRaw) ?? .list
    }

    /// Single-pass derivation. Previously `upcomingReleases` and `calendarReleases`
    /// each walked the entire release table independently (and recomputed
    /// `Set(trackedArtists.map…)` each time). With a few hundred releases that's
    /// noticeable. Batched here into one walk per body render.
    private struct UpcomingDerived {
        var upcoming: [ReleaseData] = []
        var calendar: [ReleaseData] = []
    }

    private func makeUpcomingDerived() -> UpcomingDerived {
        let trackedIDs = Set(trackedArtists.map(\.providerID))
        let cutoff = Calendar.current.date(byAdding: .day, value: -45, to: Date()) ?? .distantPast
        var out = UpcomingDerived()
        for release in storedReleases {
            guard release.dismissedAt == nil else { continue }
            guard trackedIDs.contains(release.artistProviderID) else { continue }
            guard kindIsGloballyVisible(release.kind) else { continue }
            if release.isUpcoming {
                out.upcoming.append(release)
                out.calendar.append(release)
            } else if let date = release.releaseDate, date >= cutoff {
                out.calendar.append(release)
            }
        }
        out.upcoming.sort { ($0.releaseDate ?? .distantFuture) < ($1.releaseDate ?? .distantFuture) }
        return out
    }

    private func kindIsGloballyVisible(_ kind: ReleaseKind) -> Bool {
        switch kind {
        case .album: return showAlbums
        case .single: return showSingles
        case .ep: return showEPs
        case .liveAlbum: return showLiveAlbums
        case .compilation: return showCompilations
        case .remix: return showRemixes
        }
    }

    var body: some View {
        let derived = makeUpcomingDerived()
        return NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    headerView(upcomingCount: derived.upcoming.count)

                    if derived.upcoming.isEmpty {
                        emptyState
                    } else {
                        switch layout {
                        case .list: listLayoutView(upcoming: derived.upcoming)
                        case .grid: gridLayoutView(upcoming: derived.upcoming)
                        case .calendar: calendarLayoutView(calendar: derived.calendar)
                        }
                    }

                    Spacer(minLength: 24)
                }
                .padding(.top, 4)
            }
            .overlay(alignment: .top) { topFadeOverlay }
            .navigationTitle("")
            .appScreenBackground()
            .navigationDestination(for: ReleaseData.self) { release in
                AlbumView(release: release)
            }
            .task {
                ImagePrefetcher.prefetch(derived.upcoming.prefix(60).map(\.artworkURL))
                let topIDs = derived.upcoming.prefix(10).map(\.providerID)
                Task.detached(priority: .utility) {
                    await TrackPrefetcher.prefetchBatch(providerIDs: topIDs)
                }
            }
        }
    }

    // MARK: - Top fade

    /// Opaque-to-transparent gradient over the very top of the scroll view so
    /// content scrolling under the system status bar doesn't overlap with the
    /// big "Upcoming" header text or month titles.
    private var topFadeOverlay: some View {
        LinearGradient(
            colors: [AppTheme.background, AppTheme.background.opacity(0)],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: 60)
        .ignoresSafeArea(edges: .top)
        .allowsHitTesting(false)
    }

    // MARK: - Header

    private func headerView(upcomingCount: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Upcoming")
                .font(.system(size: 36, weight: .bold, design: .rounded))
                .foregroundStyle(AppTheme.primaryText)

            HStack(spacing: 8) {
                inlineMetric(value: upcomingCount, label: "upcoming", color: .white)
                Spacer()
                layoutToggle
            }
        }
        .padding(.horizontal, 18)
    }

    private var dot: some View {
        Circle().fill(AppTheme.secondary.opacity(0.6)).frame(width: 3, height: 3)
    }

    private func inlineMetric(value: Int, label: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Text("\(value)")
                .font(.caption.weight(.bold))
                .foregroundStyle(color)
            Text(label)
                .font(.caption)
                .foregroundStyle(AppTheme.secondary)
        }
    }

    private var layoutToggle: some View {
        Button {
            // Same reasoning as Home.layoutToggleChip — animating the layout flip
            // forces every visible upcoming row to re-position, which costs more
            // than the visual reward of the crossfade.
            let next: UpcomingLayout = switch layout {
            case .list: .grid
            case .grid: .calendar
            case .calendar: .list
            }
            layoutRaw = next.rawValue
            if next == .calendar { selectedDay = nil }
        } label: {
            Image(systemName: layout.systemImage)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(AppTheme.secondary)
                .frame(width: 30, height: 30)
                .background(Capsule().fill(AppTheme.surface))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Layout: \(layout.rawValue)")
    }

    // MARK: - List layout

    private func listLayoutView(upcoming: [ReleaseData]) -> some View {
        ForEach(monthBuckets(from: upcoming), id: \.label) { bucket in
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: bucket.label)
                    .padding(.horizontal, 20)
                VStack(spacing: 12) {
                    ForEach(bucket.releases) { release in
                        NavigationLink(value: release) {
                            UpcomingRow(release: release)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }

    // MARK: - Grid layout

    private func gridLayoutView(upcoming: [ReleaseData]) -> some View {
        let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
        return ForEach(monthBuckets(from: upcoming), id: \.label) { bucket in
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: bucket.label)
                    .padding(.horizontal, 20)
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(bucket.releases) { release in
                        NavigationLink(value: release) {
                            UpcomingGridCard(release: release)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }

    // MARK: - Calendar layout (rolling 2 months — direction set in Settings)

    private func calendarLayoutView(calendar: [ReleaseData]) -> some View {
        let calReleases = calendar
        let cal = Calendar.current
        let thisMonth = cal.startOfMonth(for: Date())
        let direction = CalendarDirection(rawValue: calendarDirectionRaw) ?? .future
        let prevMonth = cal.date(byAdding: .month, value: -1, to: thisMonth) ?? thisMonth
        let nextMonth = cal.date(byAdding: .month, value: 1, to: thisMonth) ?? thisMonth

        let months: [Date] = {
            switch direction {
            case .future: return [thisMonth, nextMonth]
            case .past: return [prevMonth, thisMonth]
            case .balanced: return [prevMonth, thisMonth, nextMonth]
            }
        }()

        let byDay = releasesByDay(from: calReleases)

        return VStack(spacing: 22) {
            ForEach(Array(months.enumerated()), id: \.offset) { _, month in
                monthBlock(for: month, byDay: byDay)
            }

            if let selectedDay {
                let dayReleases = byDay[cal.startOfDay(for: selectedDay)] ?? []
                if !dayReleases.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeader(title: selectedDay.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                            .padding(.horizontal, 20)
                        VStack(spacing: 12) {
                            ForEach(dayReleases) { release in
                                NavigationLink(value: release) {
                                    UpcomingRow(release: release)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 20)
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }

    private func monthBlock(for month: Date, byDay: [Date: [ReleaseData]]) -> some View {
        let cal = Calendar.current
        let isCurrentMonth = cal.isDate(month, equalTo: Date(), toGranularity: .month)
        let cells = monthCells(for: month, byDay: byDay)
        let releaseCount = cells.compactMap { $0.date }.reduce(0) { acc, d in
            acc + (byDay[cal.startOfDay(for: d)]?.count ?? 0)
        }
        let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 7)

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(month.formatted(.dateTime.month(.wide)))
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(AppTheme.primaryText)
                Text(month.formatted(.dateTime.year()))
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(AppTheme.secondary)
                if isCurrentMonth {
                    Text("NOW")
                        .font(.caption2.weight(.bold))
                        .tracking(0.8)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .foregroundStyle(AppTheme.accent)
                        .background(Capsule().fill(AppTheme.accentSoft))
                }
                Spacer()
                if releaseCount > 0 {
                    Text("\(releaseCount)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(AppTheme.accent)
                    Text(releaseCount == 1 ? "release" : "releases")
                        .font(.caption)
                        .foregroundStyle(AppTheme.secondary)
                }
            }
            .padding(.horizontal, 20)

            HStack(spacing: 0) {
                ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol)
                        .font(.caption2.weight(.semibold))
                        .tracking(0.5)
                        .foregroundStyle(AppTheme.secondary.opacity(0.7))
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 14)

            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                    CalendarDayCell(
                        cell: cell,
                        isSelected: cell.date.map { cal.isDate($0, inSameDayAs: selectedDay ?? .distantPast) } ?? false,
                        isToday: cell.date.map { cal.isDateInToday($0) } ?? false,
                        isPast: cell.date.map { cal.startOfDay(for: $0) < cal.startOfDay(for: Date()) } ?? false
                    )
                    .onTapGesture {
                        guard let date = cell.date else { return }
                        withAnimation(.easeInOut(duration: 0.18)) {
                            if let selectedDay, cal.isDate(selectedDay, inSameDayAs: date) {
                                self.selectedDay = nil
                            } else {
                                self.selectedDay = date
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
        }
    }

    private var weekdaySymbols: [String] {
        let cal = Calendar.current
        let symbols = cal.veryShortWeekdaySymbols
        let firstIdx = cal.firstWeekday - 1
        return Array(symbols[firstIdx...]) + Array(symbols[..<firstIdx])
    }

    private func releasesByDay(from source: [ReleaseData]) -> [Date: [ReleaseData]] {
        let cal = Calendar.current
        return Dictionary(grouping: source) { release -> Date in
            cal.startOfDay(for: release.releaseDate ?? .distantFuture)
        }
    }

    private func monthCells(for month: Date, byDay: [Date: [ReleaseData]]) -> [CalendarCellModel] {
        let cal = Calendar.current
        let monthStart = cal.startOfMonth(for: month)
        let monthRange = cal.range(of: .day, in: .month, for: monthStart) ?? 1..<30
        let leadingWeekdayOffset: Int = {
            let weekday = cal.component(.weekday, from: monthStart)
            return (weekday - cal.firstWeekday + 7) % 7
        }()

        var cells: [CalendarCellModel] = []
        for _ in 0..<leadingWeekdayOffset { cells.append(CalendarCellModel(date: nil, artworkURLs: [])) }
        for day in monthRange {
            guard let date = cal.date(byAdding: .day, value: day - 1, to: monthStart) else { continue }
            let releases = byDay[cal.startOfDay(for: date)] ?? []
            cells.append(CalendarCellModel(
                date: date,
                artworkURLs: releases.prefix(3).compactMap(\.artworkURL)
            ))
        }
        while cells.count % 7 != 0 {
            cells.append(CalendarCellModel(date: nil, artworkURLs: []))
        }
        return cells
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "calendar")
                .font(.largeTitle)
                .foregroundStyle(AppTheme.secondary)
            Text("No upcoming releases")
                .font(.headline)
                .foregroundStyle(AppTheme.primaryText)
            Text("Tracked artists with announced future releases will show up here.")
                .font(.footnote)
                .foregroundStyle(AppTheme.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }

    // MARK: - Month bucketing

    private struct MonthBucket {
        let label: String
        let releases: [ReleaseData]
    }

    private static let monthBucketFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMMM yyyy"
        return f
    }()

    private func monthBuckets(from source: [ReleaseData]) -> [MonthBucket] {
        let formatter = Self.monthBucketFormatter
        let grouped = Dictionary(grouping: source) { release -> String in
            guard let date = release.releaseDate else { return "Date unknown" }
            return formatter.string(from: date)
        }
        return grouped
            .map { MonthBucket(label: $0.key, releases: $0.value) }
            .sorted { lhs, rhs in
                let lhsDate = lhs.releases.first?.releaseDate ?? .distantFuture
                let rhsDate = rhs.releases.first?.releaseDate ?? .distantFuture
                return lhsDate < rhsDate
            }
    }
}

// MARK: - Calendar cell

private struct CalendarCellModel: Hashable {
    let date: Date?
    let artworkURLs: [URL]
}

private struct CalendarDayCell: View {
    let cell: CalendarCellModel
    let isSelected: Bool
    let isToday: Bool
    let isPast: Bool

    var body: some View {
        ZStack {
            background

            if let date = cell.date {
                if hasReleases, let firstURL = cell.artworkURLs.first {
                    CachedAsyncImage(url: firstURL) {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(AppTheme.elevatedSurface)
                    }
                    .aspectRatio(1, contentMode: .fill)
                    .saturation(isPast ? 0.35 : 1)
                    .opacity(isPast ? 0.55 : 1)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        LinearGradient(
                            colors: [.black.opacity(isPast ? 0.25 : 0.0), .black.opacity(isPast ? 0.75 : 0.7)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }

                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    Text("\(Calendar.current.component(.day, from: date))")
                        .font(.system(size: hasReleases ? 16 : 14,
                                      weight: isToday ? .heavy : (hasReleases ? .bold : .semibold),
                                      design: .rounded))
                        .foregroundStyle(numberColor)
                    Spacer(minLength: 0)
                    if hasReleases {
                        countDot
                            .padding(.bottom, 5)
                    }
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(borderColor, lineWidth: isToday || isSelected ? 1.5 : 0)
        )
    }

    private var hasReleases: Bool { !cell.artworkURLs.isEmpty }

    @ViewBuilder
    private var background: some View {
        if cell.date == nil {
            Color.clear
        } else if isSelected && !hasReleases {
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(AppTheme.accentSoft)
        } else if !hasReleases {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(AppTheme.surface.opacity(isPast ? 0.25 : 0.5))
        } else {
            Color.clear
        }
    }

    private var numberColor: Color {
        if isToday { return AppTheme.accent }
        if hasReleases { return .white }
        if isPast { return AppTheme.secondary.opacity(0.5) }
        return AppTheme.secondary
    }

    private var borderColor: Color {
        if isSelected { return AppTheme.accent }
        if isToday { return AppTheme.accent.opacity(0.7) }
        return .clear
    }

    private var countDot: some View {
        HStack(spacing: 3) {
            ForEach(0..<min(cell.artworkURLs.count, 3), id: \.self) { _ in
                Circle()
                    .fill(Color.white)
                    .frame(width: 4, height: 4)
            }
        }
    }
}

extension Calendar {
    func startOfMonth(for date: Date) -> Date {
        self.date(from: dateComponents([.year, .month], from: date)) ?? date
    }
}

// MARK: - List card

/// Editorial row: date "stamp" tile on the left (month + day, accent when
/// imminent), artwork in the middle, artist/title/type stacked on the right.
/// Countdown lives inline under the title — no floating pill.
private struct UpcomingRow: View {
    let release: ReleaseData
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        // Two-tier card. Top tier: date stamp, artwork, artist + title, then
        // the calendar button hard against the right edge. Bottom tier:
        // single inline metadata line "[icon] Album · 3 days" — gives both
        // the kind and the countdown room without crowding the title.
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                dateStamp

                CachedAsyncImage(url: release.artworkURL) {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(AppTheme.elevatedSurface)
                        .overlay {
                            Image(systemName: "music.note")
                                .foregroundStyle(AppTheme.secondary)
                        }
                }
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(release.artistName.uppercased())
                        .font(.caption2.weight(.semibold))
                        .tracking(0.8)
                        .foregroundStyle(AppTheme.accent)
                        .lineLimit(1)

                    Text(ReleaseTitleFormatter.displayTitle(release.title))
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(AppTheme.primaryText)
                        // `reservesSpace: true` keeps the title slot two
                        // lines tall regardless of how short the text is,
                        // so every row has a uniform height instead of
                        // jumping between one and two visual lines.
                        .lineLimit(2, reservesSpace: true)
                        .multilineTextAlignment(.leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                AddToCalendarButton(release: release)
            }

            // Bottom inline meta strip — two capsules: [type icon Album] [3 days].
            HStack(spacing: 6) {
                HStack(spacing: 4) {
                    Image(systemName: typeIconName)
                        .font(.caption2)
                    Text(release.type.capitalized)
                        .font(.caption.weight(.medium))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(AppTheme.elevatedSurface))
                .foregroundStyle(AppTheme.secondary)

                if let date = release.releaseDate {
                    let imminent = isImminent(date: date)
                    Text(countdownText(for: date))
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(imminent ? AppTheme.accent : AppTheme.elevatedSurface))
                        .foregroundStyle(imminent ? .white : AppTheme.secondary)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(10)
        .padding(.trailing, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(AppTheme.surface)
        )
        .contextMenu {
            Button {
                Task { _ = try? await CalendarService().addRelease(release) }
            } label: {
                Label("Add to Calendar", systemImage: "calendar.badge.plus")
            }
            if let url = release.albumURL {
                Button {
                    UIApplication.shared.open(url)
                } label: {
                    Label("Open in Apple Music", systemImage: "music.note")
                }
                ShareLink(item: url) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            }
            Divider()
            Button(role: .destructive) {
                release.dismissedAt = Date()
                try? modelContext.save()
            } label: {
                Label("Dismiss", systemImage: "xmark")
            }
        }
    }

    /// SF Symbol used in the bottom meta strip to hint at the release kind.
    /// Falls back to the disc icon for anything we don't have a dedicated
    /// symbol for.
    private var typeIconName: String {
        switch ReleaseKind(rawValue: release.type) ?? .album {
        case .album, .compilation, .liveAlbum: return "opticaldisc"
        case .ep: return "square.stack"
        case .single: return "music.note"
        case .remix: return "waveform"
        }
    }

    /// Mixed-case countdown string for the inline meta line. Same logic as
    /// `InlineCountdown` but lower-cased to read as part of a sentence
    /// ("Album · 3 days") instead of the standalone uppercase pill style.
    /// "Imminent" = 0–7 days out (inclusive of today, exclusive of past).
    /// Drives the red accent fill on the countdown pill so soon-to-drop
    /// releases are scannable at a glance.
    private func isImminent(date: Date) -> Bool {
        let days = Calendar.current.dateComponents(
            [.day],
            from: Calendar.current.startOfDay(for: Date()),
            to: Calendar.current.startOfDay(for: date)
        ).day ?? 0
        return days >= 0 && days <= 7
    }

    private func countdownText(for date: Date) -> String {
        let days = Calendar.current.dateComponents(
            [.day],
            from: Calendar.current.startOfDay(for: Date()),
            to: Calendar.current.startOfDay(for: date)
        ).day ?? 0
        if days < 0 {
            let abs = -days
            if abs == 1 { return "yesterday" }
            if abs < 14 { return "\(abs) days ago" }
            if abs < 60 { return "\(abs / 7) weeks ago" }
            return "released"
        }
        if days == 0 { return "today" }
        if days == 1 { return "tomorrow" }
        if days < 14 { return "\(days) days" }
        if days < 60 { return "\(days / 7) weeks" }
        return "\(days / 30) months"
    }

    private var dateStamp: some View {
        let date = release.releaseDate
        let imminent: Bool = {
            guard let date else { return false }
            let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: Date()), to: Calendar.current.startOfDay(for: date)).day ?? 0
            return days >= 0 && days <= 7
        }()
        let fg: Color = imminent ? .white : AppTheme.accent
        let bg: Color = imminent ? AppTheme.accent : AppTheme.accentSoft

        return VStack(spacing: 0) {
            Text(date.map { $0.formatted(.dateTime.month(.abbreviated)) }?.uppercased() ?? "TBA")
                .font(.caption2.weight(.heavy))
                .tracking(1.0)
                .foregroundStyle(fg.opacity(imminent ? 0.95 : 1))
                .padding(.top, 6)
            Spacer(minLength: 0)
            Text(date.map { "\(Calendar.current.component(.day, from: $0))" } ?? "—")
                .font(.system(size: 26, weight: .heavy, design: .rounded))
                .foregroundStyle(fg)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            Spacer(minLength: 0)
            Text(date.map { $0.formatted(.dateTime.weekday(.abbreviated)) }?.uppercased() ?? "")
                .font(.caption2.weight(.semibold))
                .tracking(0.6)
                .foregroundStyle(fg.opacity(0.75))
                .padding(.bottom, 6)
        }
        .frame(width: 58, height: 72)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(bg))
    }
}

/// Inline circular button — taps add the release to the user's iOS Calendar
/// via `CalendarService`. Icon swaps to a checkmark for ~1.5s on success.
struct AddToCalendarButton: View {
    let release: ReleaseData
    @State private var state: ButtonState = .idle

    private enum ButtonState { case idle, loading, success, failed }

    var body: some View {
        Button {
            Task { await addToCalendar() }
        } label: {
            ZStack {
                Circle()
                    .fill(state == .success ? AppTheme.accent : AppTheme.elevatedSurface)
                    .frame(width: 36, height: 36)
                Group {
                    switch state {
                    case .idle: Image(systemName: "calendar.badge.plus")
                    case .loading: ProgressView().controlSize(.small)
                    case .success: Image(systemName: "checkmark")
                    case .failed: Image(systemName: "exclamationmark")
                    }
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(state == .success ? Color.white : AppTheme.secondary)
            }
        }
        .buttonStyle(.plain)
        .disabled(state == .loading || state == .success)
        .accessibilityLabel("Add to Calendar")
    }

    @MainActor
    private func addToCalendar() async {
        state = .loading
        do {
            _ = try await CalendarService().addRelease(release)
            state = .success
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            state = .idle
        } catch {
            state = .failed
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            state = .idle
        }
    }
}

/// Compact inline countdown that sits alongside the release type tag.
private struct InlineCountdown: View {
    let date: Date

    var body: some View {
        let days = Calendar.current.dateComponents(
            [.day],
            from: Calendar.current.startOfDay(for: Date()),
            to: Calendar.current.startOfDay(for: date)
        ).day ?? 0
        let released = days < 0
        let imminent = !released && days <= 7

        HStack(spacing: 4) {
            Image(systemName: released ? "checkmark.circle.fill" : (imminent ? "flame.fill" : "clock"))
                .font(.caption2.weight(.bold))
            Text(label(for: days))
                .font(.caption2.weight(.bold))
                .tracking(0.3)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .foregroundStyle(imminent ? AppTheme.accent : AppTheme.secondary)
    }

    /// Concise countdown labels. "IN " prefix dropped because it pushes the
    /// label onto a second line in narrow grid cells; "3 DAYS" or "7 WEEKS"
    /// reads the same and always fits on one line.
    private func label(for days: Int) -> String {
        if days < 0 {
            let abs = -days
            if abs == 1 { return "YESTERDAY" }
            if abs < 14 { return "\(abs) DAYS AGO" }
            if abs < 60 { return "\(abs / 7) WEEKS AGO" }
            return "RELEASED"
        }
        if days == 0 { return "TODAY" }
        if days == 1 { return "TOMORROW" }
        if days < 14 { return "\(days) DAYS" }
        if days < 60 { return "\(days / 7) WEEKS" }
        return "\(days / 30) MONTHS"
    }
}

/// Top-right "in X days" pill. Within 7 days → accent (red); further out →
/// neutral dark capsule.
private struct CountdownPill: View {
    let date: Date

    var body: some View {
        let days = Calendar.current.dateComponents(
            [.day],
            from: Calendar.current.startOfDay(for: Date()),
            to: Calendar.current.startOfDay(for: date)
        ).day ?? 0
        let isImminent = days >= 0 && days <= 7
        let bg = isImminent ? AppTheme.accent : AppTheme.elevatedSurface
        let fg: Color = isImminent ? .white : AppTheme.secondary

        Text(label(for: days))
            .font(.caption2.weight(.bold))
            .tracking(0.3)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .foregroundStyle(fg)
            .background(Capsule().fill(bg))
    }

    private func label(for days: Int) -> String {
        if days <= 0 { return "TODAY" }
        if days == 1 { return "1 DAY" }
        if days < 14 { return "\(days) DAYS" }
        if days < 60 { return "\(days / 7)W" }
        return "\(days / 30) MO"
    }
}

// MARK: - Grid card

private struct UpcomingGridCard: View {
    let release: ReleaseData

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CachedAsyncImage(url: release.artworkURL) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(AppTheme.elevatedSurface)
                    .overlay {
                        Image(systemName: "calendar")
                            .foregroundStyle(AppTheme.secondary)
                    }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(alignment: .topTrailing) {
                if let date = release.releaseDate {
                    CountdownPill(date: date)
                        .padding(6)
                }
            }

            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(release.artistName.uppercased())
                        .font(.caption2.weight(.semibold))
                        .tracking(0.6)
                        .foregroundStyle(AppTheme.secondary)
                        .lineLimit(1)
                    Text(ReleaseTitleFormatter.displayTitle(release.title))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.primaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                AddToCalendarButton(release: release)
            }
        }
    }
}
