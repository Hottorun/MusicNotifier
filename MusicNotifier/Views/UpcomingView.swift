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
    // Default to today so the first visit to the calendar layout already
    // shows the user-relevant releases instead of an empty pane that only
    // populates after they tap a date.
    @State private var selectedDay: Date? = Calendar.current.startOfDay(for: Date())

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

    /// Cached derivation so `body` never runs the O(N) release walk inline.
    /// Same pattern as `HomeView.cachedDerived`: during a refresh, SwiftData
    /// `@Query` invalidations would otherwise force `makeUpcomingDerived()`
    /// to re-walk every release synchronously on body, which is exactly the
    /// "tab switch takes 2s during refresh" hitch users reported. The walk
    /// now runs in `.task(id:)` after the first frame paints.
    @State private var cachedUpcomingDerived = UpcomingDerived()

    /// Identity key for `.task(id:)`. When any of these change, the cache
    /// recomputes off the body's hot path.
    private struct UpcomingDerivedKey: Hashable {
        var releaseCount: Int
        var trackedCount: Int
        var showAlbums: Bool
        var showSingles: Bool
        var showEPs: Bool
        var showLiveAlbums: Bool
        var showCompilations: Bool
        var showRemixes: Bool
    }

    private var upcomingDerivedKey: UpcomingDerivedKey {
        UpcomingDerivedKey(
            releaseCount: storedReleases.count,
            trackedCount: trackedArtists.count,
            showAlbums: showAlbums,
            showSingles: showSingles,
            showEPs: showEPs,
            showLiveAlbums: showLiveAlbums,
            showCompilations: showCompilations,
            showRemixes: showRemixes
        )
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
        // Render from the cached projection; `.task(id:)` keeps it fresh.
        // Walking storedReleases inline here was the source of the tab-switch
        // hitch during refresh — SwiftData invalidations triggered a full
        // re-walk on every `@Query` fire.
        let derived = cachedUpcomingDerived
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
                        endOfListFooter(count: derived.upcoming.count)
                    }

                    Spacer(minLength: 24)
                }
                .padding(.top, 4)
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
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
            // Deferred derivation. `.task(id:)` runs after the current frame
            // paints, so the O(N) release walk never blocks the body render —
            // critical during refresh, when SwiftData @Query invalidations
            // would otherwise force a synchronous walk on every save.
            .task(id: upcomingDerivedKey) {
                let next = makeUpcomingDerived()
                await MainActor.run { cachedUpcomingDerived = next }
            }
        }
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
            if next == .calendar { selectedDay = Calendar.current.startOfDay(for: Date()) }
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
        // LazyVStack outer + inner — without these, every upcoming row across
        // every month bucket was instantiated up-front, freezing the tab
        // switch for ~2s on libraries with many upcoming releases.
        LazyVStack(alignment: .leading, spacing: 18) {
        ForEach(monthBuckets(from: upcoming), id: \.label) { bucket in
            LazyVStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: bucket.label)
                    .padding(.horizontal, 20)
                LazyVStack(spacing: 12) {
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

    // MARK: - End-of-list footer

    private func endOfListFooter(count: Int) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "checkmark.circle")
                .font(.title3)
                .foregroundStyle(AppTheme.secondary.opacity(0.7))
            Text("That's all upcoming")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(AppTheme.secondary)
            Text("\(count) release\(count == 1 ? "" : "s") on the horizon")
                .font(.caption)
                .foregroundStyle(AppTheme.secondary.opacity(0.7))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 18)
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
    @Query(filter: #Predicate<ArtistData> { artist in
        artist.isTracked
    }, sort: \ArtistData.name) private var trackedArtists: [ArtistData]

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
                .frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

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
            // Order: primary → share → state action → destructive (last).
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
            if release.isUpcoming {
                Button {
                    Task { _ = try? await CalendarService().addRelease(release) }
                } label: {
                    Label("Add to Calendar", systemImage: "calendar.badge.plus")
                }
            }
            Divider()
            // Direct unfollow from the release row — saves a trip to Artists.
            if let trackedArtist = trackedArtists.first(where: { $0.providerID == release.artistProviderID }) {
                Button(role: .destructive) {
                    trackedArtist.isTracked = false
                    try? modelContext.save()
                } label: {
                    Label("Unfollow \(trackedArtist.name)", systemImage: "person.fill.xmark")
                }
            }
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
    private func isImminent(date: Date) -> Bool { ReleaseCountdown.isImminent(date) }
    private func countdownText(for date: Date) -> String { ReleaseCountdown.inlineLabel(for: date) }

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
        // Past / today releases are already out — adding them to a calendar
        // would just create a past event. Hide the affordance entirely.
        if release.isUpcoming {
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

/// One source of truth for countdown text + imminent classification. Both
/// `InlineCountdown` and `CountdownPill` (and the list-row metadata strip
/// further up the file) consult this, so a release dated "tomorrow" reads
/// the same word everywhere and the red ≤7d / grey >7d split is one rule
/// instead of three near-identical implementations.
enum ReleaseCountdown {
    static func days(to date: Date) -> Int {
        let cal = Calendar.current
        return cal.dateComponents([.day], from: cal.startOfDay(for: Date()), to: cal.startOfDay(for: date)).day ?? 0
    }

    static func isImminent(_ date: Date) -> Bool {
        let d = days(to: date)
        return d >= 0 && d <= 7
    }

    /// Concise uppercase label for badges/pills.
    static func label(for date: Date) -> String {
        let d = days(to: date)
        if d < 0 {
            let abs = -d
            if abs == 1 { return "YESTERDAY" }
            if abs < 14 { return "\(abs) DAYS AGO" }
            if abs < 60 { return "\(abs / 7) WEEKS AGO" }
            return "RELEASED"
        }
        if d == 0 { return "TODAY" }
        if d == 1 { return "TOMORROW" }
        if d < 14 { return "\(d) DAYS" }
        if d < 60 { return "\(d / 7) WEEKS" }
        return date.formatted(.dateTime.month(.abbreviated).year())
            .uppercased()
    }

    /// Lowercase form for inline metadata strips ("Album · tomorrow").
    static func inlineLabel(for date: Date) -> String {
        label(for: date).lowercased()
    }
}

/// Compact inline countdown that sits alongside the release type tag.
private struct InlineCountdown: View {
    let date: Date

    var body: some View {
        let imminent = ReleaseCountdown.isImminent(date)
        let released = ReleaseCountdown.days(to: date) < 0

        HStack(spacing: 4) {
            Image(systemName: released ? "checkmark.circle.fill" : (imminent ? "flame.fill" : "clock"))
                .font(.caption2.weight(.bold))
            Text(ReleaseCountdown.label(for: date))
                .font(.caption2.weight(.bold))
                .tracking(0.3)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .foregroundStyle(imminent ? AppTheme.accent : AppTheme.secondary)
    }
}

/// Top-right "in X days" pill. Within 7 days → accent (red); further out →
/// neutral dark capsule.
private struct CountdownPill: View {
    let date: Date

    var body: some View {
        let isImminent = ReleaseCountdown.isImminent(date)
        let bg = isImminent ? AppTheme.accent : AppTheme.elevatedSurface
        let fg: Color = isImminent ? .white : AppTheme.secondary

        Text(ReleaseCountdown.label(for: date))
            .font(.caption2.weight(.bold))
            .tracking(0.3)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .foregroundStyle(fg)
            .background(Capsule().fill(bg))
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
