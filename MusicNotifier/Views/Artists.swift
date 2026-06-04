//
//  Artists.swift
//  MusicNotifier
//
//  Created by Dimitris Kern on 28.07.25.
//

import SwiftUI
import MusicKit
import SwiftData
import UIKit

private enum ArtistListFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case tracked = "Tracked"
    case untracked = "Untracked"

    var id: String { rawValue }
}

/// A suggested artist that's been resolved to a catalog item, with artwork
/// for the discovery carousel.
struct DiscoverySuggestion: Hashable, Identifiable {
    let name: String
    let artworkURL: URL?
    var id: String { name }
}

private enum SearchMode: String, CaseIterable, Identifiable {
    case artist = "Artist"
    case label = "Label"
    var id: String { rawValue }
}

/// Lightweight projection of a MusicKit RecordLabel for the search result list.
/// Built directly into the Artists view since it's only used here.
struct LabelSearchResult: Identifiable, Hashable {
    let id: String
    let name: String
    let artworkURL: URL?
}

private enum ArtistSortOption: String, CaseIterable, Identifiable {
    case name = "A-Z"
    case recentlyAdded = "Recent"
    case recentlyUpdated = "Updated"

    var id: String { rawValue }
}

struct Artists: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ArtistData.name) private var artists: [ArtistData]
    @Query private var allReleases: [ReleaseData]
    // Global per-kind visibility — releases of hidden kinds don't affect a
    // tile's ring or subtitle either.
    @AppStorage(AppSettings.showAlbums) private var showAlbums = true
    @AppStorage(AppSettings.showSingles) private var showSingles = true
    @AppStorage(AppSettings.showEPs) private var showEPs = true
    @AppStorage(AppSettings.showLiveAlbums) private var showLiveAlbums = true
    @AppStorage(AppSettings.showCompilations) private var showCompilations = true
    @AppStorage(AppSettings.showRemixes) private var showRemixes = true
    @AppStorage(AppSettings.lastFMAPIKey) private var lastFMAPIKey = AppSettings.defaultLastFMAPIKey
    @AppStorage(AppSettings.selectedMusicProvider) private var selectedMusicProvider = MusicProvider.appleMusic.rawValue
    @AppStorage("artistsLayout") private var artistsLayoutRaw: String = "list"
    @State private var importMode: ArtistImportMode = .all
    @State private var searchText = ""
    @State private var artistSearchTerm = ""
    @State private var artistSearchResults: [ProviderArtistSearchResult] = []
    @State private var labelSearchResults: [LabelSearchResult] = []
    @State private var searchMode: SearchMode = .artist
    @State private var discoverySuggestions: [DiscoverySuggestion] = []
    @State private var listFilter: ArtistListFilter = .all
    @State private var sortOption: ArtistSortOption = .name
    @State private var isImporting = false
    @State private var isSearching = false
    @State private var isLoadingDiscovery = false
    @State private var showingDiscovery = false
    @State private var importMessage: String?
    @State private var showingImportSheet = false
    @State private var showingSearchSheet = false
    /// IDs (artist providerID / label providerID) imported during this search
    /// session — used to flash a checkmark on the +/✓ button so the user gets
    /// an immediate confirmation that the add succeeded.
    @State private var justImportedSearchIDs: Set<String> = []
    /// Owns the in-flight search task so each keystroke can cancel the
    /// previous one instead of spawning N parallel network calls.
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var searchFieldFocused: Bool
    /// Controls the custom inline search field's visibility. Hidden by
    /// default; flipped by the toolbar magnifying-glass button. The standard
    /// `.searchable` modifier was replaced because its built-in
    /// pull-to-reveal at the top of a scroll surface can't be opted out of,
    /// and that was making the search bar pop in unintentionally.
    @State private var artistSearchFieldShown = false
    @FocusState private var artistListSearchFocused: Bool
    @State private var selectedGenre: String? = nil
    @State private var scrubLetter: String? = nil
    @State private var lastScrubIndex: Int? = nil
    @State private var gridSelectedArtist: ArtistData?

    private var trackedCount: Int { artists.filter(\.isTracked).count }

    /// Per-artist release summary — single O(N) pass over the release table so
    /// every tile in the grid renders with the right ring/subtitle without
    /// doing its own lookup.
    private struct ArtistReleaseSummary {
        var hasUnseen = false
        var hasUpcoming = false
        var mostRecent: ReleaseData?
    }

    private var artistSummaries: [String: ArtistReleaseSummary] {
        var map: [String: ArtistReleaseSummary] = [:]
        for release in allReleases where release.dismissedAt == nil {
            guard kindIsGloballyVisible(release.kind) else { continue }
            var summary = map[release.artistProviderID] ?? ArtistReleaseSummary()
            if release.isUpcoming { summary.hasUpcoming = true }
            if !release.isSeen && release.isNewRelease { summary.hasUnseen = true }
            // "Most recent" = most recent past release (released, not upcoming).
            if !release.isUpcoming {
                let candidateDate = release.releaseDate ?? release.firstSeenAt
                if let existing = summary.mostRecent {
                    let existingDate = existing.releaseDate ?? existing.firstSeenAt
                    if candidateDate > existingDate { summary.mostRecent = release }
                } else {
                    summary.mostRecent = release
                }
            }
            map[release.artistProviderID] = summary
        }
        return map
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

    /// Memoized: previously computed-per-access, which walked all artists × all
    /// genres on every render (filterRow re-evaluates often when toggles change).
    @State private var availableGenres: [String] = []

    private func refreshAvailableGenres() {
        var set: Set<String> = []
        for artist in artists {
            if let g = artist.genres { for v in g { set.insert(v) } }
        }
        let sorted = set.sorted()
        if sorted != availableGenres { availableGenres = sorted }
    }

    private var visibleArtists: [ArtistData] {
        artists
            .filter { artist in
                switch listFilter {
                case .all:
                    true
                case .tracked:
                    artist.isTracked
                case .untracked:
                    !artist.isTracked
                }
            }
            .filter { artist in
                searchText.isEmpty || artist.name.localizedCaseInsensitiveContains(searchText)
            }
            .filter { artist in
                guard let selectedGenre else { return true }
                return artist.genres?.contains(selectedGenre) ?? false
            }
            .sorted { first, second in
                switch sortOption {
                case .name:
                    first.name.localizedCaseInsensitiveCompare(second.name) == .orderedAscending
                case .recentlyAdded:
                    first.addedAt > second.addedAt
                case .recentlyUpdated:
                    (first.lastCheckedAt ?? .distantPast) > (second.lastCheckedAt ?? .distantPast)
                }
            }
    }

    /// Memoized snapshot computed once per body render. Hot computed properties
    /// (`visibleArtists`, `sectionLetters`, `letterIndex`) used to each walk the
    /// full artist list independently; this batches them into a single pass.
    private struct ArtistsSnapshot {
        let visible: [ArtistData]
        let sectionLetters: [String]
        let letterIndex: [String: String]
    }

    private func makeSnapshot() -> ArtistsSnapshot {
        let visible = visibleArtists
        var letters: [String] = []
        var lettersSet: Set<String> = []
        var index: [String: String] = [:]
        for artist in visible {
            let key = letterKey(for: artist.name)
            if !lettersSet.contains(key) {
                lettersSet.insert(key)
                letters.append(key)
            }
            if index[key] == nil { index[key] = artist.providerID }
        }
        return ArtistsSnapshot(visible: visible, sectionLetters: letters, letterIndex: index)
    }

    private func letterKey(for name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first else { return "#" }
        if first.isLetter { return String(first).uppercased() }
        return "#"
    }

    var body: some View {
        let snapshot = makeSnapshot()
        return NavigationStack {
            ScrollViewReader { scrollProxy in
                ZStack(alignment: .trailing) {
                    listBody(scrollProxy: scrollProxy, snapshot: snapshot)
                    // Scrubber is only meaningful in list mode — in grid mode every
                    // tile lives inside a single List row, so scrollProxy.scrollTo
                    // can't reach interior items.
                    if artistsLayoutRaw != "grid" && sortOption == .name && snapshot.visible.count > 50 {
                        scrubber(scrollProxy: scrollProxy, snapshot: snapshot)
                    }
                }
            }
            // Single destination shared by both grid + (potentially) other state-driven
            // pushes. Inside NavigationStack so it lives in the same nav tree.
            .navigationDestination(item: $gridSelectedArtist) { artist in
                ArtistDetailView(artist: artist)
            }
        }
    }

    /// Drag-to-scrub alphabet (iOS Contacts style). Touching down on a letter
    /// jumps the list there; dragging up/down continuously updates as the
    /// finger crosses letter boundaries, with a haptic tap on each change and
    /// a floating HUD showing the current letter.
    private func scrubber(scrollProxy: ScrollViewProxy, snapshot: ArtistsSnapshot) -> some View {
        let letters = snapshot.sectionLetters
        let letterIndex = snapshot.letterIndex
        let letterHeight: CGFloat = 14
        return VStack(spacing: 0) {
            ForEach(Array(letters.enumerated()), id: \.offset) { _, letter in
                Text(letter)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(scrubLetter == letter ? AppTheme.accent : AppTheme.secondary)
                    .frame(width: 14, height: letterHeight)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 2)
        .background(Capsule().fill(AppTheme.surface.opacity(0.4)))
        .padding(.trailing, 2)
        // Single drag gesture spanning the whole strip; tap-down on a letter
        // counts as a drag of zero distance, so this handles both modes.
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let count = letters.count
                    guard count > 0 else { return }
                    let stripHeight = CGFloat(count) * letterHeight
                    // Clamp the y position to inside the strip.
                    let y = min(max(0, value.location.y - 4), stripHeight - 1)
                    let index = Int(y / letterHeight)
                    let safeIndex = min(max(0, index), count - 1)
                    let letter = letters[safeIndex]
                    scrubLetter = letter
                    if lastScrubIndex != safeIndex {
                        lastScrubIndex = safeIndex
                        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                    }
                    if let target = letterIndex[letter] {
                        scrollProxy.scrollTo(target, anchor: .top)
                    }
                }
                .onEnded { _ in
                    // Brief delay before clearing the HUD so the user sees the final letter.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        scrubLetter = nil
                        lastScrubIndex = nil
                    }
                }
        )
        .overlay(alignment: .leading) {
            // Floating HUD shown while scrubbing. Positioned to the left of the
            // strip so the user's finger isn't covering it.
            if let scrubLetter {
                Text(scrubLetter)
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .foregroundStyle(AppTheme.primaryText)
                    .frame(width: 70, height: 70)
                    .background(Circle().fill(AppTheme.elevatedSurface))
                    .overlay(Circle().stroke(AppTheme.accent, lineWidth: 1.5))
                    .shadow(color: .black.opacity(0.5), radius: 14, x: 0, y: 4)
                    .offset(x: -86)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: scrubLetter)
    }

    private func listBody(scrollProxy: ScrollViewProxy, snapshot: ArtistsSnapshot) -> some View {
            let visibleArtists = snapshot.visible
            return List {
                Group {
                    header
                    if artistSearchFieldShown {
                        inlineArtistSearchField
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    filterRow
                    genreBulkActionBar

                    if let importMessage {
                        Text(importMessage)
                            .font(.footnote)
                            .foregroundStyle(AppTheme.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 20)
                    }
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))

                if visibleArtists.isEmpty {
                    emptyState
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets())
                } else {
                    if artistsLayoutRaw == "grid" {
                        // Single List row containing a 3-column grid of artist tiles.
                        artistsGrid(visibleArtists: visibleArtists)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 6, leading: 18, bottom: 6, trailing: 18))
                    } else {
                        ForEach(visibleArtists, id: \.providerID) { artist in
                            artistRow(artist)
                                .background(
                                    NavigationLink("", destination: ArtistDetailView(artist: artist))
                                        .opacity(0)
                                )
                                .id(artist.providerID)
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(top: 3, leading: 18, bottom: 3, trailing: 18))
                                .contextMenu { artistContextMenu(artist) } preview: { artistContextMenuPreview(artist) }
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        deleteArtist(artist)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                    .tint(.red)
                                }
                        }
                    }

                    // Discover hidden behind a single button now — it lives below
                    // the main list so it doesn't compete with the watchlist itself.
                    discoverySection
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 16, leading: 18, bottom: 8, trailing: 18))

                    Color.clear
                        .frame(height: 96)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets())
                }
            }
            .listStyle(.plain)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .appScreenBackground()
            // `.searchable` was removed — see `inlineArtistSearchField` below.
            // SwiftUI's searchable installs a pull-to-reveal gesture on the
            // surrounding scroll surface that can't be disabled; users were
            // tripping it by overscrolling at the top of the list.
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 12) {
                        Button {
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                                artistSearchFieldShown.toggle()
                            }
                            if !artistSearchFieldShown {
                                searchText = ""
                                artistListSearchFocused = false
                            }
                            // Focus is requested by the field's own `.onAppear`.
                        } label: {
                            Image(systemName: "magnifyingglass")
                                .font(.headline.weight(.semibold))
                                .foregroundStyle(artistSearchFieldShown ? AppTheme.accent : AppTheme.primaryText)
                        }
                        .accessibilityLabel(artistSearchFieldShown ? "Hide search" : "Search artists")

                        Menu {
                            Button {
                                showingImportSheet = true
                            } label: {
                                Label("Import from \(selectedMusicProvider)", systemImage: "square.and.arrow.down")
                            }
                            Button {
                                showingSearchSheet = true
                            } label: {
                                Label("Add artist or label", systemImage: "magnifyingglass")
                            }
                        } label: {
                            Image(systemName: "plus")
                                .font(.headline.weight(.semibold))
                                .foregroundStyle(AppTheme.primaryText)
                        }
                        .accessibilityLabel("Add artists")
                    }
                }
            }
            .onAppear { refreshAvailableGenres() }
            .onChange(of: artists.count) { _, _ in refreshAvailableGenres() }
            .task {
                // Warm the on-screen artist artwork cache up-front so list/grid
                // scrolling paints instantly instead of fading in per-row.
                ImagePrefetcher.prefetch(artists.prefix(120).map(\.artworkURL))
                // Fire-and-forget: fills missing artist artwork from the Apple Music
                // catalog for any Apple-imported artist whose library entry has nil artwork.
                await AppleMusicLibraryImportService().backfillMissingArtwork(in: modelContext)
                await loadDiscoverySuggestions()
            }
            .sheet(isPresented: $showingImportSheet) {
                importSheet
            }
            .sheet(isPresented: $showingSearchSheet) {
                searchSheet
            }
    }

    private var header: some View {
        HStack(alignment: .lastTextBaseline, spacing: 12) {
            Text("Artists")
                .font(.system(size: 36, weight: .bold, design: .rounded))
                .foregroundStyle(AppTheme.primaryText)

            Spacer()

            Text("\(trackedCount) of \(artists.count)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Capsule().fill(AppTheme.surface))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
    }

    /// Inline search bar rendered as a List row when the user taps the
    /// toolbar magnifier. Replaces `.searchable` here for the same reason as
    /// HomeView — to remove SwiftUI's pull-down-at-top auto-reveal.
    private var inlineArtistSearchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.secondary)
            TextField("Search artists", text: $searchText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .foregroundStyle(AppTheme.primaryText)
                .focused($artistListSearchFocused)
                .submitLabel(.search)
                .onAppear { artistListSearchFocused = true }
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(AppTheme.secondary)
                }
                .buttonStyle(.plain)
            }
            Button("Cancel") {
                searchText = ""
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    artistSearchFieldShown = false
                }
                artistListSearchFocused = false
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(AppTheme.accent)
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(AppTheme.surface))
        .padding(.horizontal, 18)
    }

    private var artistSearchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.secondary)
            TextField("Search artists", text: $searchText)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .font(.subheadline)
                .foregroundStyle(AppTheme.primaryText)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(AppTheme.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 42)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(AppTheme.surface))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(AppTheme.hairline, lineWidth: 1)
        )
        .padding(.horizontal, 18)
    }

    private var actionRow: some View {
        HStack(spacing: 8) {
            Button {
                showingImportSheet = true
            } label: {
                Label("Import", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(CompactActionButtonStyle(tint: AppTheme.accent))

            Button {
                showingSearchSheet = true
            } label: {
                Label("Add", systemImage: "magnifyingglass")
            }
            .buttonStyle(CompactActionButtonStyle(tint: AppTheme.elevatedSurface))
        }
        .padding(.horizontal, 18)
    }

    private var filterRow: some View {
        HStack(spacing: 7) {
            Spacer()

            // Genre filter — only shown if any artist has at least one genre.
            if !availableGenres.isEmpty {
                Menu {
                    Button {
                        selectedGenre = nil
                    } label: {
                        Label("All genres", systemImage: selectedGenre == nil ? "checkmark" : "")
                    }
                    Divider()
                    ForEach(availableGenres, id: \.self) { genre in
                        Button {
                            selectedGenre = genre
                        } label: {
                            Label(genre, systemImage: selectedGenre == genre ? "checkmark" : "")
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: selectedGenre == nil ? "guitars" : "guitars.fill")
                            .font(.footnote.weight(.semibold))
                        if let selectedGenre {
                            Text(selectedGenre)
                                .font(.footnote.weight(.semibold))
                                .lineLimit(1)
                        }
                    }
                    .foregroundStyle(selectedGenre == nil ? AppTheme.secondary : AppTheme.accent)
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(Capsule().fill(selectedGenre == nil ? AppTheme.surface : AppTheme.accentSoft))
                }
            }

            Button {
                // Drop the animation: flipping the layout makes every artist row /
                // tile re-position, which the system-default transition handles fine
                // without an explicit eased timing that the whole list has to follow.
                artistsLayoutRaw = (artistsLayoutRaw == "grid" ? "list" : "grid")
            } label: {
                Image(systemName: artistsLayoutRaw == "grid" ? "square.grid.3x3.fill" : "list.bullet")
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(AppTheme.surface))
                    .foregroundStyle(AppTheme.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(artistsLayoutRaw == "grid" ? "Switch to list" : "Switch to grid")

            Menu {
                Picker("Show", selection: $listFilter) {
                    Label("All artists", systemImage: "person.2").tag(ArtistListFilter.all)
                    Label("Tracked", systemImage: "bell.fill").tag(ArtistListFilter.tracked)
                    Label("Untracked", systemImage: "bell.slash").tag(ArtistListFilter.untracked)
                }
                Divider()
                Picker("Sort", selection: $sortOption) {
                    Label("A-Z", systemImage: "textformat").tag(ArtistSortOption.name)
                    Label("Recently added", systemImage: "clock").tag(ArtistSortOption.recentlyAdded)
                    Label("Recently checked", systemImage: "checkmark.circle").tag(ArtistSortOption.recentlyUpdated)
                }
            } label: {
                // Tint accent when a non-default filter is active so the user
                // sees at a glance whether the list is being narrowed.
                let nonDefaultFilter = listFilter != .all
                Image(systemName: nonDefaultFilter ? "line.3.horizontal.decrease.circle.fill" : "arrow.up.arrow.down")
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(nonDefaultFilter ? AppTheme.accentSoft : AppTheme.surface))
                    .foregroundStyle(nonDefaultFilter ? AppTheme.accent : AppTheme.secondary)
            }
        }
        .padding(.horizontal, 18)
    }

    private func artistsGrid(visibleArtists: [ArtistData]) -> some View {
        let columns = [
            GridItem(.flexible(), spacing: 10),
            GridItem(.flexible(), spacing: 10),
            GridItem(.flexible(), spacing: 10)
        ]
        // Compute summaries once for the whole grid render, not per-tile.
        let summaries = artistSummaries
        return LazyVGrid(columns: columns, spacing: 14) {
            ForEach(visibleArtists, id: \.providerID) { artist in
                // Each cell lives in its own struct so SwiftUI gives it a
                // stable identity. Inlining the tile + Button + contextMenu
                // in a ForEach inside LazyVGrid leaks identity across cells —
                // long-press always lifts the first artist, and tap-target
                // hit testing gets confused. Extracting to ArtistGridCell
                // fixes both at once.
                ArtistGridCell(
                    onSelect: { gridSelectedArtist = artist },
                    tile: { artistGridTile(artist, summary: summaries[artist.providerID]) },
                    menu: { artistContextMenu(artist) },
                    preview: { artistContextMenuPreview(artist) }
                )
            }
        }
    }

    /// Lightweight long-press snapshot — artwork + name, nothing else. The
    /// default snapshot would lift the entire list row including ring overlays
    /// and metadata badges, which sometimes stutters on first present.
    private func artistContextMenuPreview(_ artist: ArtistData) -> some View {
        VStack(spacing: 14) {
            CachedAsyncImage(url: artist.artworkURL) {
                Circle().fill(AppTheme.elevatedSurface)
                    .overlay {
                        Image(systemName: "person.fill")
                            .font(.system(size: 36, weight: .light))
                            .foregroundStyle(AppTheme.secondary)
                    }
            }
            .frame(width: 180, height: 180)
            .clipShape(Circle())

            Text(artist.name)
                .font(.headline)
                .foregroundStyle(AppTheme.primaryText)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .padding(20)
        .background(AppTheme.surface)
    }

    /// Long-press menu for artist tiles and rows. Mirrors the MusicHarbor
    /// pattern: notify toggle, open in Apple Music, share, remove. Most
    /// actions are also reachable elsewhere — context menu is the quick path.
    @ViewBuilder
    private func artistContextMenu(_ artist: ArtistData) -> some View {
        Button {
            artist.isTracked.toggle()
            try? modelContext.save()
        } label: {
            Label(artist.isTracked ? "Stop notifications" : "Notify for new releases",
                  systemImage: artist.isTracked ? "bell.slash" : "bell")
        }
        if let catalogID = artist.catalogArtistID,
           let url = URL(string: "https://music.apple.com/artist/\(catalogID)") {
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
            deleteArtist(artist)
        } label: {
            Label("Remove from library", systemImage: "trash")
        }
    }

    private func artistGridTile(_ artist: ArtistData, summary: ArtistReleaseSummary?) -> some View {
        let hasUnseen = summary?.hasUnseen ?? false
        return VStack(spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                CachedAsyncImage(url: artist.artworkURL) {
                    Circle()
                        .fill(AppTheme.elevatedSurface)
                        .overlay(
                            Image(systemName: "person.fill")
                                .foregroundStyle(AppTheme.secondary)
                        )
                }
                .frame(width: 88, height: 88)
                .clipShape(Circle())
                .overlay(
                    // Ring lights up in the accent color when this artist has
                    // any unseen new release; otherwise stays invisible.
                    Circle().stroke(hasUnseen ? AppTheme.accent : Color.clear, lineWidth: 2.5)
                )

                if hasUnseen {
                    Circle()
                        .fill(AppTheme.accent)
                        .frame(width: 22, height: 22)
                        .overlay(
                            Image(systemName: "sparkles")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(AppTheme.primaryText)
                        )
                        .overlay(Circle().stroke(AppTheme.background, lineWidth: 2))
                        .offset(x: 2, y: 2)
                }
            }
            Text(artist.name)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.primaryText)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
            artistSubtitle(summary: summary)
        }
        .frame(maxWidth: .infinity)
    }

    /// One-line status under the artist name. Priority: unseen new release →
    /// upcoming release → relative time of the most recent past release.
    @ViewBuilder
    private func artistSubtitle(summary: ArtistReleaseSummary?) -> some View {
        if summary?.hasUnseen == true {
            Text("new")
                .font(.caption2.weight(.bold))
                .foregroundStyle(AppTheme.accent)
        } else if summary?.hasUpcoming == true {
            Text("upcoming")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(AppTheme.accent.opacity(0.85))
        } else if let recent = summary?.mostRecent {
            Text(relativeAge(for: recent.releaseDate ?? recent.firstSeenAt))
                .font(.caption2)
                .foregroundStyle(AppTheme.secondary)
                .lineLimit(1)
        } else {
            // Reserve the line height so tiles in the grid all align even when
            // this artist has no releases yet.
            Text(" ")
                .font(.caption2)
        }
    }

    private func relativeAge(for date: Date) -> String {
        let now = Date()
        let comps = Calendar.current.dateComponents([.year, .month, .day], from: date, to: now)
        if let y = comps.year, y >= 1 { return "\(y)y ago" }
        if let m = comps.month, m >= 1 { return "\(m) mo ago" }
        if let d = comps.day, d >= 7 { return "\(d / 7)w ago" }
        if let d = comps.day, d >= 1 { return "\(d)d ago" }
        return "today"
    }

    /// Contextual bulk action bar — only shows when a genre is active. Lets the
    /// user track or untrack every artist in the visible genre with one tap.
    @ViewBuilder
    private var genreBulkActionBar: some View {
        if let genre = selectedGenre {
            let inGenre = artists.filter { $0.genres?.contains(genre) ?? false }
            let untrackedCount = inGenre.filter { !$0.isTracked }.count
            let trackedCount = inGenre.filter(\.isTracked).count

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(genre)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.primaryText)
                    Text("\(inGenre.count) artists · \(trackedCount) tracked")
                        .font(.caption2)
                        .foregroundStyle(AppTheme.secondary)
                }

                Spacer()

                if untrackedCount > 0 {
                    Button {
                        setTracked(true, for: inGenre)
                    } label: {
                        Label("Track \(untrackedCount)", systemImage: "bell.fill")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 12)
                            .frame(height: 32)
                            .background(Capsule().fill(AppTheme.accent))
                            .foregroundStyle(AppTheme.primaryText)
                    }
                    .buttonStyle(.plain)
                }
                if trackedCount > 0 {
                    Button {
                        setTracked(false, for: inGenre)
                    } label: {
                        Image(systemName: "bell.slash")
                            .font(.subheadline.weight(.semibold))
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(AppTheme.surface))
                            .foregroundStyle(AppTheme.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Untrack all \(genre)")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(AppTheme.surface.opacity(0.5)))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(AppTheme.accent.opacity(0.3), lineWidth: 1)
            )
            .padding(.horizontal, 18)
        }
    }

    private func setTracked(_ isTracked: Bool, for artists: [ArtistData]) {
        for artist in artists {
            artist.isTracked = isTracked
        }
        try? modelContext.save()
    }

    @ViewBuilder
    private var discoverySection: some View {
        if !lastFMAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, trackedCount > 0 {
            VStack(alignment: .leading, spacing: 10) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { showingDiscovery.toggle() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AppTheme.accent)
                        Text("Discover")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AppTheme.primaryText)
                        if isLoadingDiscovery {
                            ProgressView().tint(AppTheme.accent).scaleEffect(0.7)
                        }
                        Spacer()
                        Image(systemName: showingDiscovery ? "chevron.up" : "chevron.down")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(AppTheme.secondary)
                    }
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 18)

                if showingDiscovery {
                    if discoverySuggestions.isEmpty {
                        Text(isLoadingDiscovery ? "Finding similar artists…" : "Refresh after Last.fm has loaded a few tracked artists.")
                            .font(.footnote)
                            .foregroundStyle(AppTheme.secondary)
                            .padding(.horizontal, 20)
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(discoverySuggestions) { suggestion in
                                    discoveryCard(suggestion: suggestion)
                                }
                            }
                            .padding(.horizontal, 18)
                        }
                        .scrollClipDisabled()
                    }
                }
            }
        }
    }

    private func discoveryCard(suggestion: DiscoverySuggestion) -> some View {
        Button {
            Task { await trackSuggestedArtist(named: suggestion.name) }
        } label: {
            VStack(spacing: 8) {
                ZStack {
                    CachedAsyncImage(url: suggestion.artworkURL) {
                        Circle()
                            .fill(AppTheme.elevatedSurface)
                            .overlay {
                                Text(initials(for: suggestion.name))
                                    .font(.subheadline.weight(.bold))
                                    .foregroundStyle(AppTheme.secondary)
                            }
                    }
                    .frame(width: 64, height: 64)
                    .clipShape(Circle())

                    Circle()
                        .fill(AppTheme.accent)
                        .frame(width: 22, height: 22)
                        .overlay {
                            Image(systemName: "plus")
                                .font(.caption2.weight(.heavy))
                                .foregroundStyle(AppTheme.primaryText)
                        }
                        .overlay(Circle().stroke(AppTheme.background, lineWidth: 2))
                        .offset(x: 22, y: 22)
                }
                .frame(width: 72, height: 72)

                Text(suggestion.name)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.primaryText)
                    .lineLimit(1)
                    .frame(width: 78)
            }
        }
        .buttonStyle(.plain)
    }

    private func initials(for name: String) -> String {
        let parts = name.split(separator: " ").prefix(2)
        let initials = parts.compactMap { $0.first }.map(String.init).joined()
        return initials.isEmpty ? String(name.prefix(2)).uppercased() : initials.uppercased()
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.2")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(AppTheme.secondary)
            Text(artists.isEmpty ? "No artists yet" : "Nothing matches")
                .font(.headline)
                .foregroundStyle(AppTheme.primaryText)
            Text(artists.isEmpty ? "Import from a music service or search to add artists." : "Try a different filter or search.")
                .font(.footnote)
                .foregroundStyle(AppTheme.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
        .padding(.horizontal, 24)
    }

    private func artistRow(_ artist: ArtistData) -> some View {
        HStack(spacing: 12) {
            CachedAsyncImage(url: artist.artworkURL) {
                Circle().fill(AppTheme.elevatedSurface)
                    .overlay(
                        Image(systemName: "person.fill")
                            .foregroundStyle(AppTheme.secondary)
                    )
            }
            .frame(width: 44, height: 44)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(artist.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.primaryText)
                    .lineLimit(1)
                // Show last-checked relative time instead of provider name — more
                // useful info, and provider is implicit when the library is mono-provider.
                if let lastCheckedAt = artist.lastCheckedAt {
                    Text("Checked \(lastCheckedAt.formatted(.relative(presentation: .named)))")
                        .font(.caption2)
                        .foregroundStyle(AppTheme.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Button {
                artist.isTracked.toggle()
                try? modelContext.save()
            } label: {
                Image(systemName: artist.isTracked ? "bell.fill" : "bell")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(artist.isTracked ? .white : AppTheme.secondary)
                    .frame(width: 36, height: 36)
                    .background(
                        Circle()
                            .fill(AppTheme.elevatedSurface)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(artist.isTracked ? "Stop tracking \(artist.name)" : "Track \(artist.name)")
        }
        .padding(10)
        .frame(height: 64)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(AppTheme.surface)
        )
    }

    private var importSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeader(title: "Service")
                        Picker("Service", selection: $selectedMusicProvider) {
                            Text(MusicProvider.appleMusic.rawValue).tag(MusicProvider.appleMusic.rawValue)
                            Text(MusicProvider.spotify.rawValue).tag(MusicProvider.spotify.rawValue)
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: selectedMusicProvider) { _, newValue in
                            UserDefaults(suiteName: AppSettings.appGroupIdentifier)?
                                .set(newValue, forKey: AppSettings.selectedMusicProvider)
                        }

                        if MusicProvider.fromStoredName(selectedMusicProvider) == .spotify {
                            Text(SpotifyService().isConnected ? "Imports followed Spotify artists." : "Connect Spotify to import followed artists.")
                                .font(.footnote)
                                .foregroundStyle(AppTheme.secondary)

                            if !SpotifyService().isConnected {
                                Button {
                                    Task { await connectSpotify() }
                                } label: {
                                    Label("Connect Spotify", systemImage: "link")
                                }
                                .buttonStyle(PrimaryButtonStyle())
                                .disabled(isImporting)
                            }

                            Button {
                                Task {
                                    await importSpotifyArtists()
                                    if importMessage?.hasPrefix("Imported") == true {
                                        showingImportSheet = false
                                    }
                                }
                            } label: {
                                Label(isImporting ? "Importing…" : "Import followed Spotify artists", systemImage: "square.and.arrow.down")
                            }
                            .buttonStyle(PrimaryButtonStyle())
                            .disabled(isImporting || !SpotifyService().isConnected)
                        } else {
                        SectionHeader(title: "Import mode")
                        Picker("Import Mode", selection: $importMode) {
                            ForEach(ArtistImportMode.allCases) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        Text(importMode.description)
                            .font(.footnote)
                            .foregroundStyle(AppTheme.secondary)

                            Button {
                                Task {
                                    await importAppleMusicArtists()
                                    if importMessage?.hasPrefix("Imported") == true {
                                        showingImportSheet = false
                                    }
                                }
                            } label: {
                                Label(isImporting ? "Importing…" : "Import from Apple Music", systemImage: "square.and.arrow.down")
                            }
                            .buttonStyle(PrimaryButtonStyle())
                            .disabled(isImporting)
                        }
                    }

                    Divider().background(AppTheme.hairline)

                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeader(title: "Bulk actions")
                        Button {
                            setArtists(artists, tracked: true)
                        } label: {
                            Label("Track all artists", systemImage: "bell.badge")
                        }
                        .buttonStyle(GhostButtonStyle())
                        .disabled(artists.isEmpty)

                        Button {
                            setArtists(artists, tracked: false)
                        } label: {
                            Label("Untrack all artists", systemImage: "bell.slash")
                        }
                        .buttonStyle(GhostButtonStyle())
                        .disabled(trackedCount == 0)
                    }

                    if let importMessage {
                        Text(importMessage)
                            .font(.footnote)
                            .foregroundStyle(AppTheme.secondary)
                    }
                }
                .padding(20)
            }
            .navigationTitle("Import Artists")
            .navigationBarTitleDisplayMode(.inline)
            .appScreenBackground()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showingImportSheet = false }
                }
            }
        }
    }

    private var searchSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AppTheme.secondary)
                        TextField("Search artists and labels", text: $artistSearchTerm)
                            .textInputAutocapitalization(.words)
                            .autocorrectionDisabled()
                            .foregroundStyle(AppTheme.primaryText)
                            .focused($searchFieldFocused)
                        if isSearching {
                            ProgressView().scaleEffect(0.8)
                        } else if !artistSearchTerm.isEmpty {
                            Button {
                                artistSearchTerm = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(AppTheme.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 44)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(AppTheme.surface))

                    if artistSearchResults.isEmpty && labelSearchResults.isEmpty,
                       !artistSearchTerm.isEmpty, !isSearching {
                        Text("No matches")
                            .font(.footnote)
                            .foregroundStyle(AppTheme.secondary)
                    }

                    // When the field is empty, fill the empty area below the
                    // search bar with the Discover carousel so the sheet
                    // doesn't read as a blank page. Hidden the moment the
                    // user starts typing so it doesn't compete with results.
                    if artistSearchTerm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        searchSheetDiscoverySection
                    }

                    // Labels first — there are usually fewer and they're easier to find.
                    ForEach(labelSearchResults) { label in
                        labelSearchRow(label)
                    }

                    ForEach(artistSearchResults) { artist in
                        artistSearchRow(artist)
                    }

                    if let importMessage {
                        Text(importMessage)
                            .font(.footnote)
                            .foregroundStyle(AppTheme.secondary)
                    }
                }
                .padding(20)
            }
            .navigationTitle("Add")
            .navigationBarTitleDisplayMode(.inline)
            .appScreenBackground()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showingSearchSheet = false }
                }
            }
            .onChange(of: artistSearchTerm) { _, newValue in
                // Cancel the previous search task so a stream of keystrokes
                // doesn't accumulate N in-flight network calls — previously
                // every character spawned a fresh Task that all woke up
                // after their respective debounces and raced.
                searchTask?.cancel()
                searchTask = Task { await debouncedCombinedSearch(term: newValue) }
            }
            .task {
                // Auto-focus on first present. Without the brief delay the
                // sheet's slide-in animation can outrun the keyboard, leaving
                // it half-presented behind the sheet.
                try? await Task.sleep(nanoseconds: 250_000_000)
                searchFieldFocused = true
            }
            .task {
                // Lazy-load Discover suggestions so the sheet has content
                // below the search bar from the moment it opens.
                if discoverySuggestions.isEmpty && !isLoadingDiscovery {
                    await loadDiscoverySuggestions()
                }
            }
        }
    }

    /// Discover carousel surfaced inside the Add sheet when the user hasn't
    /// typed anything yet. Mirrors the carousel on the main Artists tab but
    /// renders the cards in a vertical grid so they fill the empty space
    /// below the search bar instead of forcing horizontal scrolling.
    @ViewBuilder
    private var searchSheetDiscoverySection: some View {
        if !discoverySuggestions.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.accent)
                    Text("Discover")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(AppTheme.primaryText)
                    Spacer()
                    Text("Based on artists you track")
                        .font(.caption2)
                        .foregroundStyle(AppTheme.secondary)
                }
                let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(discoverySuggestions) { suggestion in
                        discoveryCard(suggestion: suggestion)
                    }
                }
            }
            .padding(.top, 4)
        } else if isLoadingDiscovery {
            HStack(spacing: 8) {
                ProgressView().tint(AppTheme.accent).scaleEffect(0.8)
                Text("Finding similar artists…")
                    .font(.footnote)
                    .foregroundStyle(AppTheme.secondary)
            }
            .padding(.top, 4)
        }
    }

    private func labelSearchRow(_ label: LabelSearchResult) -> some View {
        HStack(spacing: 12) {
            CachedAsyncImage(url: label.artworkURL) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(AppTheme.elevatedSurface)
                    .overlay(Image(systemName: "music.note.house").foregroundStyle(AppTheme.secondary))
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(label.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.primaryText)
                HStack(spacing: 4) {
                    Image(systemName: "music.note.house.fill")
                        .font(.caption2)
                    Text("Label")
                        .font(.caption2)
                }
                .foregroundStyle(AppTheme.accent)
            }

            Spacer()

            searchAddButton(
                isImported: artists.contains { $0.providerID == label.id },
                isJustAdded: justImportedSearchIDs.contains(label.id),
                accessibilityLabel: "Follow \(label.name)"
            ) {
                importSearchedLabel(label)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(AppTheme.surface))
    }

    private func artistSearchRow(_ artist: ProviderArtistSearchResult) -> some View {
        HStack(spacing: 12) {
            CachedAsyncImage(url: artist.artworkURL) {
                Circle().fill(AppTheme.elevatedSurface)
            }
            .frame(width: 44, height: 44)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(artist.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.primaryText)
                Text("Artist · \(artist.provider.rawValue)")
                    .font(.caption2)
                    .foregroundStyle(AppTheme.secondary)
            }

            Spacer()

            searchAddButton(
                isImported: artists.contains { $0.providerID == artist.id },
                isJustAdded: justImportedSearchIDs.contains(artist.id),
                accessibilityLabel: "Import \(artist.name)"
            ) {
                importSearchedArtist(artist)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(AppTheme.surface))
    }

    /// Shared +/✓ control for the search sheet's artist and label rows. Shows
    /// a green check for anyone the user has already imported (so they can scan
    /// results at a glance) and briefly flashes the check on a fresh tap before
    /// settling into the "already tracked" state.
    @ViewBuilder
    private func searchAddButton(
        isImported: Bool,
        isJustAdded: Bool,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        let showCheck = isImported || isJustAdded
        Button(action: {
            guard !isImported else { return }
            action()
        }) {
            // `.contentTransition(.symbolEffect(.replace))` lived here briefly
            // and caused a runtime crash the first time the parent re-rendered
            // during search typing on at least one device — the symbol-replace
            // transition appears to be unhappy with this particular Button +
            // disabled + animated-scale combination. A plain crossfade via the
            // surrounding withAnimation in `flashJustAdded` is sufficient.
            Image(systemName: showCheck ? "checkmark" : "plus")
                .font(.subheadline.weight(.bold))
                .frame(width: 32, height: 32)
                .background(Circle().fill(showCheck ? AppTheme.accent : AppTheme.accentSoft))
                .foregroundStyle(showCheck ? .white : AppTheme.accent)
                .scaleEffect(isJustAdded ? 1.08 : 1.0)
                .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isJustAdded)
        }
        .buttonStyle(.plain)
        .disabled(isImported)
        .accessibilityLabel(isImported ? "Already following" : accessibilityLabel)
    }

    /// Debounced combined search. The owning `searchTask` State cancels the
    /// previous task on each new keystroke, so this throws-on-cancel `sleep`
    /// is the bail-out for stale typing; only the final keystroke survives
    /// the wait to fire network calls.
    @MainActor
    private func debouncedCombinedSearch(term: String) async {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            artistSearchResults = []
            labelSearchResults = []
            return
        }
        // 200ms feels responsive without spamming the catalog endpoint.
        // Throwing variant so cancellation by the next keystroke aborts here
        // instead of falling through to a network call.
        do { try await Task.sleep(nanoseconds: 200_000_000) } catch { return }
        if Task.isCancelled { return }

        isSearching = true
        defer { isSearching = false }

        async let artists = (try? await searchArtistsForCombined(trimmed)) ?? []
        async let labels = (try? await AppleMusicLibraryImportService().searchCatalogLabels(term: trimmed)) ?? []
        let (a, l) = await (artists, labels)
        if Task.isCancelled { return }

        artistSearchResults = a
        labelSearchResults = l.map { LabelSearchResult(id: $0.id.rawValue, name: $0.name, artworkURL: $0.artwork?.url(width: 200, height: 200)) }
    }

    /// Pure artist search returning the raw results — used by the combined flow
    /// without touching the existing isSearching / importMessage state.
    @MainActor
    private func searchArtistsForCombined(_ term: String) async throws -> [ProviderArtistSearchResult] {
        if MusicProvider.fromStoredName(selectedMusicProvider) == .appleMusic {
            let results = try await AppleMusicLibraryImportService().searchCatalogArtists(term: term)
            return results.map {
                ProviderArtistSearchResult(
                    id: MusicProvider.appleMusic.scopedID($0.id.rawValue),
                    provider: .appleMusic,
                    name: $0.name,
                    artworkURL: $0.artwork?.url(width: 200, height: 200)
                )
            }
        } else {
            return try await SpotifyService().searchArtists(term: term)
        }
    }

    private func deleteArtist(_ artist: ArtistData) {
        // Also remove any releases tied to this artist so they don't linger as orphans.
        let providerID = artist.providerID
        let descriptor = FetchDescriptor<ReleaseData>(
            predicate: #Predicate { $0.artistProviderID == providerID }
        )
        if let related = try? modelContext.fetch(descriptor) {
            related.forEach(modelContext.delete)
        }
        modelContext.delete(artist)
        try? modelContext.save()
    }

    @MainActor
    private func importAppleMusicArtists() async {
        isImporting = true
        importMessage = nil

        do {
            let importedCount = try await AppleMusicLibraryImportService().importArtists(mode: importMode, into: modelContext)
            importMessage = "Imported \(importedCount) artists. Tap the bell for artists you want to track."
        } catch {
            importMessage = "Could not import artists: \(error.localizedDescription)"
        }

        isImporting = false
    }

    @MainActor
    private func importSpotifyArtists() async {
        isImporting = true
        importMessage = nil

        do {
            let importedCount = try await SpotifyService().importFollowedArtists(into: modelContext)
            importMessage = "Imported \(importedCount) artists. Tap the bell for artists you want to track."
        } catch {
            importMessage = "Could not import Spotify artists: \(error.localizedDescription)"
        }

        isImporting = false
    }

    @MainActor
    private func connectSpotify() async {
        isImporting = true
        importMessage = nil

        do {
            try await SpotifyService().authenticate()
            selectedMusicProvider = MusicProvider.spotify.rawValue
            UserDefaults(suiteName: AppSettings.appGroupIdentifier)?
                .set(MusicProvider.spotify.rawValue, forKey: AppSettings.selectedMusicProvider)
            importMessage = "Spotify connected. You can now import followed artists."
        } catch {
            importMessage = "Could not connect Spotify: \(error.localizedDescription)"
        }

        isImporting = false
    }

    private func setArtists(_ artistsToUpdate: [ArtistData], tracked isTracked: Bool) {
        artistsToUpdate.forEach { artist in
            artist.isTracked = isTracked
        }
        try? modelContext.save()
        importMessage = isTracked ? "Tracking \(artistsToUpdate.count) artists." : "Stopped tracking \(artistsToUpdate.count) artists."
    }

    
    /// Route the search button based on the segmented mode.
    @MainActor
    private func runSearch() async {
        switch searchMode {
        case .artist: await searchArtists()
        case .label: await searchLabels()
        }
    }

    @MainActor
    private func searchLabels() async {
        labelSearchResults = []
        isSearching = true
        defer { isSearching = false }
        do {
            let labels = try await AppleMusicLibraryImportService().searchCatalogLabels(term: artistSearchTerm)
            labelSearchResults = labels.map { label in
                LabelSearchResult(
                    id: label.id.rawValue,
                    name: label.name,
                    artworkURL: label.artwork?.url(width: 200, height: 200)
                )
            }
            importMessage = labelSearchResults.isEmpty ? "No labels found." : "Found \(labelSearchResults.count) labels."
        } catch {
            importMessage = "Label search failed: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func importSearchedLabel(_ label: LabelSearchResult) {
        Task {
            do {
                let labels = try await AppleMusicLibraryImportService().searchCatalogLabels(term: label.name)
                guard let match = labels.first(where: { $0.id.rawValue == label.id }) ?? labels.first else {
                    importMessage = "Couldn't resolve label."
                    return
                }
                try AppleMusicLibraryImportService().importLabel(match, into: modelContext)
                importMessage = "Now following \(label.name)."
                flashJustAdded(label.id)
            } catch {
                importMessage = "Couldn't follow \(label.name): \(error.localizedDescription)"
            }
        }
    }

    private func searchArtists() async {
        isSearching = true
        importMessage = nil

        do {
            switch MusicProvider.fromStoredName(selectedMusicProvider) {
            case .appleMusic:
                let results = try await AppleMusicLibraryImportService().searchCatalogArtists(term: artistSearchTerm)
                artistSearchResults = results.map {
                    ProviderArtistSearchResult(
                        id: $0.id.rawValue,
                        provider: .appleMusic,
                        name: $0.name,
                        artworkURL: $0.artwork?.url(width: 120, height: 120)
                    )
                }
            case .spotify:
                artistSearchResults = try await SpotifyService().searchArtists(term: artistSearchTerm)
            }
            importMessage = artistSearchResults.isEmpty ? "No artists found." : "Found \(artistSearchResults.count) artists."
        } catch {
            importMessage = "Could not search artists: \(error.localizedDescription)"
        }

        isSearching = false
    }

    private func importSearchedArtist(_ artist: ProviderArtistSearchResult) {
        do {
            switch artist.provider {
            case .appleMusic:
                try AppleMusicLibraryImportService().importCatalogArtist(artist, into: modelContext)
            case .spotify:
                try SpotifyService().importArtist(artist, into: modelContext)
            }
            importMessage = "Imported and tracking \(artist.name)."
            flashJustAdded(artist.id)
        } catch {
            importMessage = "Could not import \(artist.name): \(error.localizedDescription)"
        }
    }

    /// Briefly mark a search-result row as freshly added so the +/✓ button
    /// animates from plus to check. After ~1.4s the flag clears; from that
    /// point the check stays because the artist/label is now in `artists` and
    /// `isImported` is true on its own.
    private func flashJustAdded(_ id: String) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
            _ = justImportedSearchIDs.insert(id)
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            withAnimation(.easeOut(duration: 0.25)) {
                _ = justImportedSearchIDs.remove(id)
            }
        }
    }

    @MainActor
    private func loadDiscoverySuggestions() async {
        let service = LastFMService(apiKey: lastFMAPIKey)
        let trackedArtists = artists.filter(\.isTracked)
        guard service.isConfigured, !trackedArtists.isEmpty else { return }

        isLoadingDiscovery = true
        defer { isLoadingDiscovery = false }

        var ranked: [String: Int] = [:]
        // Build the exclusion set against every locally-stored artist (tracked or
        // not). Folding normalizes case + diacritics so "A$AP Rocky" and "a$ap rocky"
        // match cleanly.
        let existingNames = Set(artists.map { normalizeForMatch($0.name) })

        for artist in trackedArtists.prefix(8) {
            guard let info = try? await service.fetchArtistInfo(artistName: artist.name) else {
                continue
            }

            for similar in info.similarArtists {
                guard !existingNames.contains(normalizeForMatch(similar)) else { continue }
                ranked[similar, default: 0] += 1
            }
        }

        let rankedNames = ranked
            .sorted { lhs, rhs in
                if lhs.value == rhs.value {
                    return lhs.key.localizedCaseInsensitiveCompare(rhs.key) == .orderedAscending
                }
                return lhs.value > rhs.value
            }
            .prefix(12)
            .map(\.key)

        // Resolve each suggestion's artwork in parallel via Apple Music catalog
        // search, then drop ones whose catalog hit still maps to an existing artist
        // (Last.fm name vs. catalog name mismatch — catches things like "Ye" / "Kanye West").
        let resolved = await withTaskGroup(of: DiscoverySuggestion?.self) { group in
            for name in rankedNames {
                group.addTask {
                    let results = try? await AppleMusicLibraryImportService().searchCatalogArtists(term: name)
                    guard let match = results?.first else {
                        return DiscoverySuggestion(name: name, artworkURL: nil)
                    }
                    return DiscoverySuggestion(
                        name: match.name,
                        artworkURL: match.artwork?.url(width: 200, height: 200)
                    )
                }
            }
            var out: [DiscoverySuggestion] = []
            for await result in group {
                if let result { out.append(result) }
            }
            return out
        }
        discoverySuggestions = resolved.filter { suggestion in
            !existingNames.contains(normalizeForMatch(suggestion.name))
        }
    }

    private func normalizeForMatch(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @MainActor
    private func trackSuggestedArtist(named name: String) async {
        importMessage = nil

        do {
            let results = try await AppleMusicLibraryImportService().searchCatalogArtists(term: name)
            guard let artist = results.first else {
                importMessage = "No Apple Music match for \(name)."
                return
            }

            try AppleMusicLibraryImportService().importCatalogArtist(artist, into: modelContext)
            importMessage = "Imported and tracking \(artist.name)."
            discoverySuggestions.removeAll {
                $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
                    || $0.name.localizedCaseInsensitiveCompare(artist.name) == .orderedSame
            }
        } catch {
            importMessage = "Could not track \(name): \(error.localizedDescription)"
        }
    }
}

#Preview {
    Artists()
        .modelContainer(for: ArtistData.self, inMemory: true)
}

/// Self-contained grid cell. SwiftUI assigns each instance of a `View` struct
/// a stable identity, which fixes a class of LazyVGrid quirks where inline
/// `ForEach` + `Button` + `.contextMenu` would route taps and long-press
/// previews to the first iteration's data regardless of which tile was
/// actually pressed.
fileprivate struct ArtistGridCell<Tile: View, Menu: View, Preview: View>: View {
    let onSelect: () -> Void
    @ViewBuilder var tile: () -> Tile
    @ViewBuilder var menu: () -> Menu
    @ViewBuilder var preview: () -> Preview

    var body: some View {
        Button(action: onSelect) {
            tile()
        }
        .buttonStyle(.plain)
        .contextMenu(menuItems: menu, preview: preview)
    }
}
