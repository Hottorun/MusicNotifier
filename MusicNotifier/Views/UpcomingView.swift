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
    /// Gates the debounce in `.task(id:)` — first walk runs immediately so the
    /// list isn't empty on appear; later ones coalesce.
    @State private var hasComputedUpcomingOnce = false

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

    /// Sendable projection for the off-main walk — only the scalars the
    /// bucketing reads.
    private struct UpcomingSnapshot: Sendable {
        let id: PersistentIdentifier
        let artistProviderID: String
        let kind: ReleaseKind
        let releaseDate: Date?
        let isDismissed: Bool
    }

    private struct UpcomingDerivedIDs: Sendable {
        var upcomingIDs: [PersistentIdentifier] = []
        var calendarIDs: [PersistentIdentifier] = []
    }

    /// Genuinely off-main variant of `makeUpcomingDerived`.
    ///
    /// `.task(id:)` closures inherit the view's MainActor isolation, so the
    /// previous `let next = makeUpcomingDerived(); await MainActor.run { … }`
    /// ran the whole walk on the main thread — the `MainActor.run` hop was a
    /// no-op. The walk was deferred by a frame but never moved off, so every
    /// SwiftData save during a fetch still stalled scrolling on this tab.
    private func makeUpcomingDerivedAsync() async -> UpcomingDerived {
        var snapshots: [UpcomingSnapshot] = []
        snapshots.reserveCapacity(storedReleases.count)
        var lookup: [PersistentIdentifier: ReleaseData] = [:]
        lookup.reserveCapacity(storedReleases.count)
        for release in storedReleases {
            let id = release.persistentModelID
            snapshots.append(
                UpcomingSnapshot(
                    id: id,
                    artistProviderID: release.artistProviderID,
                    kind: release.kind,
                    releaseDate: release.releaseDate,
                    isDismissed: release.dismissedAt != nil
                )
            )
            if lookup[id] == nil { lookup[id] = release }
        }

        let trackedIDs = Set(trackedArtists.map(\.providerID))
        let day = ReleaseDayBoundaries.snapshot()
        let cutoff = Calendar.current.date(byAdding: .day, value: -45, to: Date()) ?? .distantPast
        let kinds = visibleKindsSet()

        let ids = await Task.detached(priority: .userInitiated) {
            var out = UpcomingDerivedIDs()
            for snapshot in snapshots {
                guard !snapshot.isDismissed else { continue }
                guard trackedIDs.contains(snapshot.artistProviderID) else { continue }
                guard kinds.contains(snapshot.kind) else { continue }
                guard let releaseDate = snapshot.releaseDate else { continue }
                if releaseDate >= day.startOfTomorrow {
                    out.upcomingIDs.append(snapshot.id)
                    out.calendarIDs.append(snapshot.id)
                } else if releaseDate >= cutoff {
                    out.calendarIDs.append(snapshot.id)
                }
            }
            return out
        }.value

        var out = UpcomingDerived()
        out.upcoming = ids.upcomingIDs.compactMap { lookup[$0] }
        out.calendar = ids.calendarIDs.compactMap { lookup[$0] }
        // `storedReleases` is already `@Query(sort: \.releaseDate)` ascending,
        // so the upcoming bucket comes out in order — but re-sort explicitly
        // rather than depending on the query's ordering.
        out.upcoming.sort { ($0.releaseDate ?? .distantFuture) < ($1.releaseDate ?? .distantFuture) }
        return out
    }

    private func visibleKindsSet() -> Set<ReleaseKind> {
        var kinds: Set<ReleaseKind> = []
        if showAlbums { kinds.insert(.album) }
        if showSingles { kinds.insert(.single) }
        if showEPs { kinds.insert(.ep) }
        if showLiveAlbums { kinds.insert(.liveAlbum) }
        if showCompilations { kinds.insert(.compilation) }
        if showRemixes { kinds.insert(.remix) }
        return kinds
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
            // Artist pushes from AlbumView / ArtistDetailView resolve here —
            // see the note at the Artists tab's stack root.
            .navigationDestination(for: ArtistData.self) { artist in
                ArtistDetailView(artist: artist)
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
                // Debounce after the first walk — see the note in
                // `makeUpcomingDerivedAsync`. Each SwiftData batch commit
                // during a refresh changes `releaseCount`, restarting this
                // task; sleeping first collapses a burst into one walk.
                if hasComputedUpcomingOnce {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    if Task.isCancelled { return }
                }
                let next = await makeUpcomingDerivedAsync()
                if Task.isCancelled { return }
                cachedUpcomingDerived = next
                hasComputedUpcomingOnce = true
            }
        }
    }

    // MARK: - Header

    private func headerView(upcomingCount: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("UPCOMING")
                .font(AppFont.display(40, .heavy))
                .tracking(0.5)
                .foregroundStyle(AppTheme.primaryText)

            // The anchor: everything below this rule is still to come. In a
            // list made entirely of future dates, marking where "now" sits is
            // what makes the countdowns mean something.
            TodayDivider(label: "Today \(Self.todayStampFormatter.string(from: Date()))")

            HStack(spacing: 8) {
                // `.white` made the count invisible on the light background.
                // Match the Feed's unread metric: accent when non-zero.
                inlineMetric(
                    value: upcomingCount,
                    label: "upcoming",
                    color: upcomingCount > 0 ? AppTheme.accent : AppTheme.secondary
                )
                Spacer()
                layoutToggle
            }
        }
        .padding(.horizontal, 18)
    }

    private var dot: some View {
        Circle().fill(AppTheme.secondary.opacity(0.6)).frame(width: 3, height: 3)
    }

    /// "d MMM" stamp used in the header's today rule.
    fileprivate static let todayStampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d MMM"
        return f
    }()

    private func inlineMetric(value: Int, label: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Text("\(value)")
                .font(AppFont.display(16, .heavy))
                .monospacedDigit()
                .foregroundStyle(color)
            Text(label.uppercased())
                .font(AppFont.display(11, .bold))
                .tracking(0.9)
                .foregroundStyle(AppTheme.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(value) \(label)")
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
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(AppTheme.secondary)
                .frame(width: 34, height: 34)
                .background(Capsule().fill(AppTheme.surface))
                .overlay(Capsule().strokeBorder(AppTheme.hairline, lineWidth: 1))
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
                SectionHeader(title: bucket.label, count: bucket.releases.count)
                    .padding(.horizontal, AppTheme.Space.gutter)
                LazyVStack(spacing: AppTheme.Space.rowGap) {
                    ForEach(bucket.releases) { release in
                        NavigationLink(value: release) {
                            UpcomingRow(release: release)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, AppTheme.Space.gutter)
            }
        }
        }
    }

    // MARK: - Grid layout

    private func gridLayoutView(upcoming: [ReleaseData]) -> some View {
        let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
        return ForEach(monthBuckets(from: upcoming), id: \.label) { bucket in
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: bucket.label, count: bucket.releases.count)
                    .padding(.horizontal, AppTheme.Space.gutter)
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(bucket.releases) { release in
                        NavigationLink(value: release) {
                            UpcomingGridCard(release: release)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, AppTheme.Space.gutter)
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
                    .font(AppFont.display(28, .heavy))
                    .foregroundStyle(AppTheme.primaryText)
                Text(month.formatted(.dateTime.year()))
                    .font(AppFont.display(20, .bold)).monospacedDigit()
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

    /// Closes the list the same way the header opens it — with a rule. The
    /// schedule has a start and an end, and saying so stops the user from
    /// wondering whether more is still loading.
    private func endOfListFooter(count: Int) -> some View {
        HStack(spacing: 10) {
            Rectangle()
                .fill(AppTheme.hairline)
                .frame(height: 1)
            Text("\(count) SCHEDULED")
                .font(AppFont.display(11, .heavy))
                .tracking(1.2)
                .monospacedDigit()
                .foregroundStyle(AppTheme.secondary)
            Rectangle()
                .fill(AppTheme.hairline)
                .frame(height: 1)
        }
        .padding(.horizontal, AppTheme.Space.gutter)
        .padding(.top, 14)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        AppEmptyState(
            title: "Nothing announced",
            message: "When a tracked artist announces a release date, it lands here with a countdown.",
            systemImage: "calendar"
        ) {
            EmptyView()
        }
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
                        .font(AppFont.display(
                            hasReleases ? 18 : 16,
                            isToday ? .heavy : (hasReleases ? .bold : .semibold)
                        ))
                        .monospacedDigit()
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
        HStack(alignment: .top, spacing: 10) {
            // Same rail as the Feed, so both tabs share one left edge. The
            // rail is neutral even here: previously every upcoming row wore
            // an accent-filled date tile, which meant nothing stood out.
            // Urgency now lives in the countdown chip alone.
            DateRail(date: release.releaseDate, showsWeekday: true)
                .padding(.top, 2)

            CachedAsyncImage(url: release.artworkURL) {
                RoundedRectangle(cornerRadius: AppTheme.Radius.tile, style: .continuous)
                    .fill(AppTheme.elevatedSurface)
                    .overlay {
                        Image(systemName: "music.note")
                            .foregroundStyle(AppTheme.secondary)
                    }
            }
            .frame(width: 64, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.tile, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.tile, style: .continuous)
                    .strokeBorder(AppTheme.hairline, lineWidth: 1)
            )

            VStack(alignment: .leading, spacing: 4) {
                EyebrowText(text: release.artistName)

                Text(ReleaseTitleFormatter.displayTitle(release.title))
                    .font(AppFont.text(15, .semibold))
                    .foregroundStyle(AppTheme.primaryText)
                    // `reservesSpace: true` keeps the title slot two lines
                    // tall regardless of how short the text is, so every row
                    // has a uniform height instead of jumping between one and
                    // two visual lines.
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.leading)

                HStack(spacing: 6) {
                    HStack(spacing: 4) {
                        Image(systemName: typeIconName)
                            .font(.system(size: 9, weight: .bold))
                        Text(release.type.uppercased())
                            .font(AppFont.display(10, .heavy))
                            .tracking(0.7)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(AppTheme.elevatedSurface))
                    .foregroundStyle(AppTheme.secondary)

                    if let date = release.releaseDate {
                        CountdownChip(date: date)
                    }
                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            AddToCalendarButton(release: release)
        }
        .appCard(padding: 10)
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

// Countdown rendering now lives in `CountdownChip` (AppTheme.swift) so the
// Feed, Upcoming, and the album detail page all draw the same chip from the
// same `ReleaseCountdown` rules.

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
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.heroTile, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.heroTile, style: .continuous)
                    .strokeBorder(AppTheme.hairline, lineWidth: 1)
            )
            .overlay(alignment: .topTrailing) {
                if let date = release.releaseDate {
                    CountdownChip(date: date, prominent: true)
                        .padding(6)
                }
            }

            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    EyebrowText(text: release.artistName, size: 10)
                    Text(ReleaseTitleFormatter.displayTitle(release.title))
                        .font(AppFont.text(14, .semibold))
                        .foregroundStyle(AppTheme.primaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                AddToCalendarButton(release: release)
            }
        }
    }
}
