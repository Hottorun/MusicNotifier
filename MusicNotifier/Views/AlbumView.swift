//
//  AlbumView.swift
//  MusicNotifier
//
//  Created by Dimitris Kern on 28.07.25.
//

import SwiftUI
import SwiftData
import MusicKit

/// One row in the album tracklist.
struct AlbumTrackRow: Identifiable, Hashable {
    init(id: String, discNumber: Int, trackNumber: Int, title: String, artistName: String, duration: Double?) {
        self.id = id
        self.discNumber = discNumber
        self.trackNumber = trackNumber
        self.title = title
        self.artistName = artistName
        self.duration = duration
    }

    init(cached: CachedTrack) {
        self.init(
            id: cached.id,
            discNumber: cached.discNumber,
            trackNumber: cached.trackNumber,
            title: cached.title,
            artistName: cached.artistName,
            duration: cached.duration
        )
    }

    let id: String
    let discNumber: Int
    let trackNumber: Int
    let title: String
    let artistName: String
    let duration: TimeInterval?
}

struct AlbumView: View {
    @Environment(\.modelContext) private var modelContext
    @AppStorage(AppSettings.lastFMAPIKey) private var lastFMAPIKey = AppSettings.defaultLastFMAPIKey
    @Query private var allArtists: [ArtistData]
    @StateObject private var previewPlayer = AlbumPreviewPlayer()
    @State private var lastFMInfo: LastFMAlbumInfo?
    @State private var lastFMError: String?
    @State private var tracks: [AlbumTrackRow] = []
    @State private var popularTrackTitles: Set<String> = []
    @State private var hasMultipleDiscs = false
    @State private var libraryAddState: LibraryAddState = .idle
    @State private var showingPlaylistPicker = false
    @State private var userPlaylists: [Playlist] = []
    @State private var playlistsLoading = false
    @State private var playlistAddingID: String?
    @State private var playlistAddMessage: String?
    @State private var calendarMessage: String?
    @State private var showingCalendarAlert = false
    /// Non-nil while the user is dragging the mini-player progress bar.
    /// Captures the target fraction so the bar tracks the finger live.
    @State private var scrubFraction: Double?
    /// Playback fraction captured the instant the scrub gesture began. Used
    /// for relative scrubbing — touching anywhere on the bar and dragging
    /// moves the play head by the drag distance, not by the touch location.
    @State private var scrubStartFraction: Double?
    @State private var showingArtworkFullscreen = false
    @State private var artistPushTarget: ArtistData?
    @State private var addedSongIDs: Set<String> = []
    @State private var addingSongIDs: Set<String> = []

    private enum LibraryAddState {
        case idle, adding, added, failed(String)

        var isInProgress: Bool { if case .adding = self { return true } else { return false } }
        var isAdded: Bool { if case .added = self { return true } else { return false } }

        var toolbarIcon: String {
            switch self {
            case .idle: "plus"
            case .adding: "ellipsis"
            case .added: "checkmark"
            case .failed: "exclamationmark.triangle"
            }
        }

        var accessibilityLabel: String {
            switch self {
            case .idle: "Add to Library"
            case .adding: "Adding to Library"
            case .added: "Added to Library"
            case .failed: "Add failed, tap to retry"
            }
        }
    }
    private let release: ReleaseData?
    let title: String
    let artistName: String
    let releaseDate: Date?
    let artworkURL: URL?
    let albumURL: URL?

    init(
        title: String = "Album Name",
        artistName: String = "Artist Name",
        releaseDate: Date? = Date(),
        artworkURL: URL? = nil,
        albumURL: URL? = nil
    ) {
        self.release = nil
        self.title = title
        self.artistName = artistName
        self.releaseDate = releaseDate
        self.artworkURL = artworkURL
        self.albumURL = albumURL
    }

    init(release: ReleaseData) {
        self.release = release
        self.title = release.title
        self.artistName = release.artistName
        self.releaseDate = release.releaseDate
        self.artworkURL = release.artworkURL
        self.albumURL = release.albumURL

        // Seed @State with cached tracks synchronously so the first body
        // render already has the list. Eliminates the actor-hop + await
        // latency for cached opens — measured ~100-170ms previously, now ~0ms.
        if let cached = TrackCache.shared.tracks(for: release.providerID) {
            let rows = cached.map(AlbumTrackRow.init(cached:))
            self._tracks = State(initialValue: rows)
            self._hasMultipleDiscs = State(initialValue: Set(rows.map(\.discNumber)).count > 1)
        }
        if let cachedPopular = TrackPopularityCache.shared.popularTitles(for: release.providerID) {
            self._popularTrackTitles = State(initialValue: cachedPopular)
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                centeredHero
                centeredStats
                centeredActions
                tagsRow
                if !tracks.isEmpty {
                    tracklistSection
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 20)
        }
        .background(AppTheme.background.ignoresSafeArea())
        .tint(AppTheme.accent)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            release?.isSeen = true
            try? modelContext.save()
        }
        .onDisappear {
            previewPlayer.stop()
        }
        .safeAreaInset(edge: .bottom) {
            if previewPlayer.isActive {
                miniPlayerBar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: previewPlayer.isActive)
        .navigationDestination(item: $artistPushTarget) { ArtistDetailView(artist: $0) }
        .toolbar {
            if releaseProvider == .appleMusic, let providerID = release?.providerID {
                // Standalone calendar button — only for upcoming releases.
                if let release, release.releaseDate.map({ $0 >= Calendar.current.startOfDay(for: Date()) }) == true {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            Task { await addReleaseToCalendar(release) }
                        } label: {
                            Image(systemName: "calendar.badge.plus")
                                .foregroundStyle(AppTheme.accent)
                        }
                        .accessibilityLabel("Add to Calendar")
                    }
                }
                // `+` menu for library / playlist adds.
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            Task { await addAlbumToLibrary(providerID: providerID) }
                        } label: {
                            Label("Add to Library", systemImage: "plus.square.on.square")
                        }
                        .disabled(libraryAddState.isInProgress || libraryAddState.isAdded)

                        Button {
                            Task { await openPlaylistPicker() }
                        } label: {
                            Label("Add to Playlist…", systemImage: "music.note.list")
                        }
                    } label: {
                        Image(systemName: libraryAddState.toolbarIcon)
                            .foregroundStyle(AppTheme.accent)
                            .symbolEffect(.bounce, value: libraryAddState.isAdded)
                    }
                    .accessibilityLabel("Add album")
                }
            }
        }
        .sheet(isPresented: $showingPlaylistPicker) {
            playlistPickerSheet
        }
        .fullScreenCover(isPresented: $showingArtworkFullscreen) {
            artworkFullscreen
        }
        .alert("Calendar", isPresented: $showingCalendarAlert, presenting: calendarMessage) { _ in
            Button("OK", role: .cancel) {}
        } message: { msg in
            Text(msg)
        }
        .task {
            // Last.fm is independent — fan it out so it doesn't block tracks.
            // Library membership and popularity both read `tracks`, so they
            // have to wait for loadTracks() to finish before running (still
            // parallel to each other and to the Last.fm fetch).
            async let lastfm: Void = loadLastFMInfo()
            await loadTracks()
            async let library: Void = loadLibraryMembership()
            async let popularity: Void = loadTrackPopularity()
            _ = await (lastfm, library, popularity)
        }
        .tracksTabNavigationDepth()
    }

    // MARK: - Hero (centered)

    /// Big centered artwork + metadata stack — the new opinionated layout.
    private var centeredHero: some View {
        VStack(spacing: 14) {
            Button {
                showingArtworkFullscreen = true
            } label: {
                CachedAsyncImage(url: artworkURL) {
                    artworkPlaceholder
                }
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: 280)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .buttonStyle(.plain)
            .shadow(color: .black.opacity(0.45), radius: 22, y: 10)

            VStack(spacing: 6) {
                Text(ReleaseTitleFormatter.displayTitle(title))
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(AppTheme.primaryText)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)

                Button {
                    navigateToArtist()
                } label: {
                    HStack(spacing: 4) {
                        Text(artistName)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AppTheme.primaryText)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(AppTheme.secondary)
                    }
                }
                .buttonStyle(.plain)

                HStack(spacing: 6) {
                    Text(formattedReleaseDate)
                        .font(.footnote)
                        .foregroundStyle(AppTheme.secondary)
                    if let kind = release?.kind {
                        ReleaseTypeBadge(kind: kind)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// Listener + play count, centered under the hero. Renders nothing until
    /// Last.fm responds — the previous "Loading Last.fm" spinner caused a
    /// jarring layout shift on every album open.
    @ViewBuilder
    private var centeredStats: some View {
        if let lastFMInfo {
            HStack(spacing: 28) {
                if let listeners = lastFMInfo.listeners {
                    inlineStat(value: formattedCount(listeners), label: "listeners", icon: "headphones")
                }
                if let playcount = lastFMInfo.playcount {
                    inlineStat(value: formattedCount(playcount), label: "plays", icon: "chart.bar")
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// Play + "Open in Apple Music" as equal-width pill buttons, side by side.
    @ViewBuilder
    private var centeredActions: some View {
        HStack(spacing: 10) {
            if releaseProvider == .appleMusic, release?.providerID != nil {
                Button {
                    Task { await playAllTracks() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "play.fill")
                        Text("Play")
                    }
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(AppTheme.primaryText)
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .background(Capsule().fill(AppTheme.accent))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Play album")
            }

            if let albumURL {
                Link(destination: albumURL) {
                    HStack(spacing: 8) {
                        Image(systemName: releaseProvider == .spotify ? "arrow.up.right.square" : "music.note")
                        Text("Open in \(releaseProvider.rawValue)")
                            .lineLimit(1)
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.primaryText)
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .background(Capsule().fill(AppTheme.surface))
                }
            }
        }
    }

    // MARK: - Tracklist

    private var tracklistSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Section title only — the big play button at the top of the page
            // owns the play action now.
            Text("Tracks")
                .font(.headline)
                .foregroundStyle(AppTheme.primaryText)

            let grouped = Dictionary(grouping: tracks, by: \.discNumber)
                .sorted { $0.key < $1.key }

            ForEach(grouped, id: \.key) { discNumber, discTracks in
                VStack(spacing: 0) {
                    if hasMultipleDiscs {
                        HStack {
                            Image(systemName: "opticaldisc")
                                .font(.caption)
                            Text("Disc \(discNumber)")
                                .font(.caption.weight(.semibold))
                                .tracking(0.8)
                        }
                        .foregroundStyle(AppTheme.secondary)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    ForEach(discTracks.sorted(by: { $0.trackNumber < $1.trackNumber })) { track in
                        Button {
                            Task { await playTrack(track) }
                        } label: {
                            trackRow(track)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(release?.providerID == nil)

                        if track.id != discTracks.last?.id {
                            Rectangle()
                                .fill(AppTheme.hairline)
                                .frame(height: 0.5)
                                .padding(.leading, 48)
                        }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(AppTheme.surface))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
    }

    private func trackRow(_ track: AlbumTrackRow) -> some View {
        let isPlaying = previewPlayer.currentTrackTitle == track.title && previewPlayer.isPlaying
        let isPopular = popularTrackTitles.contains(track.title.lowercased())
        return HStack(spacing: 8) {
            // Popularity dot — leftmost. Same reserved width whether visible or not
            // so all track numbers below stay aligned.
            Circle()
                .fill(isPopular ? AppTheme.accent : Color.clear)
                .frame(width: 6, height: 6)

            Group {
                if isPlaying {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(AppTheme.accent)
                } else {
                    Text("\(track.trackNumber)")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(AppTheme.secondary)
                }
            }
            .frame(width: 22, alignment: .center)
            .monospacedDigit()
            .padding(.trailing, 4)

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isPlaying ? AppTheme.accent : AppTheme.primaryText)
                    .lineLimit(1)
                if !track.artistName.isEmpty, track.artistName.compare(artistName, options: .caseInsensitive) != .orderedSame {
                    Text(track.artistName)
                        .font(.caption2)
                        .foregroundStyle(AppTheme.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if let duration = track.duration {
                Text(formatDuration(duration))
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(AppTheme.secondary)
                    .monospacedDigit()
            }

            if releaseProvider == .appleMusic {
                addSongButton(for: track)
            }
        }
    }

    /// Compact inline button beside each track: + → ↺ (adding) → hidden once
    /// the song is in the user's Apple Music library.
    @ViewBuilder
    private func addSongButton(for track: AlbumTrackRow) -> some View {
        let isAdded = addedSongIDs.contains(track.id)
        let isAdding = addingSongIDs.contains(track.id)
        if isAdded {
            // Reserve the same width so track durations stay column-aligned.
            Color.clear.frame(width: 28, height: 28)
        } else {
            Button {
                Task { await addSongToLibraryInline(track) }
            } label: {
                Group {
                    if isAdding {
                        ProgressView().tint(AppTheme.secondary).scaleEffect(0.7)
                    } else {
                        Image(systemName: "plus")
                            .foregroundStyle(AppTheme.secondary)
                    }
                }
                .font(.footnote.weight(.bold))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isAdding)
            .accessibilityLabel("Add \(track.title) to Library")
        }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// Match the release's artist to a stored ArtistData and push their detail page.
    /// Falls back to a case/diacritic-insensitive name match when the providerID
    /// isn't on a tracked artist (e.g. compilation tracks crediting featured artists).
    private func navigateToArtist() {
        if let providerID = release?.artistProviderID,
           let match = allArtists.first(where: { $0.providerID == providerID }) {
            artistPushTarget = match
            return
        }
        if let nameMatch = allArtists.first(where: {
            $0.name.compare(artistName, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }) {
            artistPushTarget = nameMatch
        }
    }

    @MainActor
    private func playTrack(_ track: AlbumTrackRow) async {
        guard let providerID = release?.providerID, !providerID.isEmpty,
              !track.id.isEmpty else { return }
        await previewPlayer.play(albumProviderID: providerID, startingAtTrackID: track.id)
    }

    @MainActor
    private func playAllTracks() async {
        guard let providerID = release?.providerID, !providerID.isEmpty else { return }
        await previewPlayer.play(albumProviderID: providerID)
    }

    @MainActor
    private func addSongToLibraryInline(_ track: AlbumTrackRow) async {
        guard !addedSongIDs.contains(track.id), !addingSongIDs.contains(track.id) else { return }
        addingSongIDs.insert(track.id)
        defer { addingSongIDs.remove(track.id) }
        do {
            try await previewPlayer.addSongToLibrary(songID: track.id)
            addedSongIDs.insert(track.id)
        } catch {
            // On failure, leave the button in its idle state so the user can retry.
        }
    }

    @MainActor
    private func loadTracks() async {
        // Tracks are only fetchable via MusicKit (Apple Music). Spotify releases skip this.
        guard releaseProvider == .appleMusic, let providerID = release?.providerID else { return }

        // Hot path: tracks were seeded in init from the cache, so just queue
        // a background refresh and return.
        if !tracks.isEmpty {
            Task.detached(priority: .utility) {
                await TrackPrefetcher.prefetch(providerID: providerID)
            }
            return
        }

        // No seed: maybe the cache was populated after init (e.g. another
        // album just finished fetching and wrote the file). Sync-check.
        if let cached = TrackCache.shared.tracks(for: providerID) {
            let rows = cached.map(AlbumTrackRow.init(cached:))
            tracks = rows
            hasMultipleDiscs = Set(rows.map(\.discNumber)).count > 1
            Task.detached(priority: .utility) {
                await TrackPrefetcher.prefetch(providerID: providerID)
            }
            return
        }

        do {
            // Preloading `.tracks` on the request collapses the lookup into one
            // MusicKit round-trip instead of fetch-album then fetch-tracks.
            var request = MusicCatalogResourceRequest<Album>(matching: \.id, equalTo: MusicItemID(providerID))
            request.properties = [.tracks]
            let response = try await request.response()
            guard let album = response.items.first else { return }
            let rows: [AlbumTrackRow] = (album.tracks.map(Array.init) ?? []).map { track in
                AlbumTrackRow(
                    id: track.id.rawValue,
                    discNumber: track.discNumber ?? 1,
                    trackNumber: track.trackNumber ?? 0,
                    title: track.title,
                    artistName: track.artistName,
                    duration: track.duration
                )
            }
            tracks = rows
            hasMultipleDiscs = Set(rows.map(\.discNumber)).count > 1
            TrackCache.shared.store(rows.map(CachedTrack.init(row:)), for: providerID)
        } catch {
            // Non-fatal — tracklist just won't render.
        }
    }

    // Background-refresh delegates to TrackPrefetcher so HomeView's
    // top-of-feed prefetch and AlbumView's refresh share one implementation.

    /// Pre-populate `addedSongIDs` for tracks the user already has in their
    /// Apple Music library. Uses the shared session-scoped index so only the
    /// first album opened pays the full library-fetch cost; subsequent opens
    /// resolve in microseconds.
    @MainActor
    private func loadLibraryMembership() async {
        guard releaseProvider == .appleMusic, !tracks.isEmpty else { return }
        #if os(iOS) || os(visionOS) || targetEnvironment(macCatalyst)
        let index = await LibraryMembershipIndex.shared.get()
        var found: Set<String> = []
        for track in tracks {
            let effectiveArtist = (track.artistName.isEmpty ? artistName : track.artistName).lowercased()
            if index[effectiveArtist]?.contains(track.title.lowercased()) == true {
                found.insert(track.id)
            }
        }
        addedSongIDs = found
        #endif
    }

    @MainActor
    private func loadTrackPopularity() async {
        guard !tracks.isEmpty else { return }
        let service = LastFMService(apiKey: lastFMAPIKey)
        guard service.isConfigured else { return }

        // Fetch playcount per track in parallel, cached. Then mark the top 25% as popular.
        let infos: [(title: String, playcount: Int)] = await withTaskGroup(of: (String, Int).self) { group in
            for track in tracks {
                let trackTitle = track.title
                let artist = artistName
                group.addTask {
                    let info = try? await service.fetchTrackInfo(artistName: artist, trackTitle: trackTitle)
                    return (trackTitle, info?.playcount ?? 0)
                }
            }
            var out: [(String, Int)] = []
            for await result in group { out.append(result) }
            return out
        }

        // Pick the top quartile (rounded up), but at least the single highest if there's data.
        let ranked = infos.filter { $0.playcount > 0 }.sorted { $0.playcount > $1.playcount }
        guard !ranked.isEmpty else { return }
        let topCount = max(1, Int(Double(ranked.count) * 0.25))
        let titles = Set(ranked.prefix(topCount).map { $0.title.lowercased() })
        popularTrackTitles = titles
        if let providerID = release?.providerID {
            TrackPopularityCache.shared.store(titles, for: providerID)
        }
    }

    @MainActor
    private func addReleaseToCalendar(_ release: ReleaseData) async {
        do {
            _ = try await CalendarService().addRelease(release)
            calendarMessage = "Added \(release.title) to your calendar."
        } catch {
            calendarMessage = error.localizedDescription
        }
        showingCalendarAlert = true
    }

    @MainActor
    private func openPlaylistPicker() async {
        showingPlaylistPicker = true
        // Take whatever the shared cache already has so the sheet paints
        // instantly on subsequent opens. The async get() either returns
        // immediately (cached) or kicks off the one shared MusicKit fetch.
        let cached = UserPlaylistsCache.shared.playlists
        if !cached.isEmpty {
            userPlaylists = cached
            return
        }
        playlistsLoading = true
        defer { playlistsLoading = false }
        userPlaylists = await UserPlaylistsCache.shared.get()
        if userPlaylists.isEmpty {
            playlistAddMessage = "Couldn't load playlists."
        }
    }

    @MainActor
    private func addAlbumToPlaylist(_ playlist: Playlist, providerID: String) async {
        playlistAddingID = playlist.id.rawValue
        defer { playlistAddingID = nil }
        do {
            let albumRequest = MusicCatalogResourceRequest<Album>(matching: \.id, equalTo: MusicItemID(providerID))
            guard let album = try await albumRequest.response().items.first else {
                playlistAddMessage = "Couldn't resolve album."
                return
            }
            #if os(iOS) || os(visionOS) || targetEnvironment(macCatalyst)
            try await MusicLibrary.shared.add(album, to: playlist)
            #endif
            playlistAddMessage = "Added to \(playlist.name)."
            // Auto-close after a beat so it feels like a confirm.
            try? await Task.sleep(nanoseconds: 700_000_000)
            showingPlaylistPicker = false
            playlistAddMessage = nil
        } catch {
            playlistAddMessage = "Add failed: \(error.localizedDescription)"
        }
    }

    /// Fullscreen artwork viewer with pinch-to-zoom + drag-to-dismiss. Tap
    /// anywhere outside the image or hit the close button to dismiss.
    private var artworkFullscreen: some View {
        FullscreenArtworkView(url: artworkURL, title: title, artistName: artistName) {
            showingArtworkFullscreen = false
        }
    }

    private var playlistPickerSheet: some View {
        NavigationStack {
            List {
                if playlistsLoading && userPlaylists.isEmpty {
                    HStack { Spacer(); ProgressView(); Spacer() }
                        .listRowBackground(Color.clear)
                } else if userPlaylists.isEmpty {
                    Text("No playlists in your Apple Music library yet.")
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.secondary)
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(userPlaylists, id: \.id) { playlist in
                        Button {
                            guard let providerID = release?.providerID else { return }
                            Task { await addAlbumToPlaylist(playlist, providerID: providerID) }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "music.note.list")
                                    .font(.subheadline)
                                    .foregroundStyle(AppTheme.accent)
                                    .frame(width: 28)
                                Text(playlist.name)
                                    .foregroundStyle(AppTheme.primaryText)
                                Spacer()
                                if playlistAddingID == playlist.id.rawValue {
                                    ProgressView().scaleEffect(0.75)
                                } else {
                                    Image(systemName: "plus")
                                        .foregroundStyle(AppTheme.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(AppTheme.surface)
                    }
                }

                if let playlistAddMessage {
                    Text(playlistAddMessage)
                        .font(.footnote)
                        .foregroundStyle(AppTheme.secondary)
                        .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .navigationTitle("Add to Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .appScreenBackground()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showingPlaylistPicker = false }
                        .foregroundStyle(AppTheme.accent)
                }
            }
        }
    }

    @MainActor
    private func addAlbumToLibrary(providerID: String) async {
        libraryAddState = .adding
        do {
            try await previewPlayer.addToLibrary(albumProviderID: providerID)
            libraryAddState = .added
        } catch {
            libraryAddState = .failed(error.localizedDescription)
        }
    }

    /// Floating mini-player card pinned to the bottom safe area, modeled on the
    /// Spotify "Now playing" pill. Detached from the screen edges with horizontal
    /// margins and a drop shadow so it visibly hovers above the content.
    @ViewBuilder
    private var miniPlayerBar: some View {
        VStack(spacing: 0) {
            miniPlayerRow
            miniPlayerProgress
        }
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(AppTheme.elevatedSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(AppTheme.hairline, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.5), radius: 14, x: 0, y: 6)
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }

    private var miniPlayerRow: some View {
        HStack(spacing: 10) {
            CachedAsyncImage(url: artworkURL) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(AppTheme.elevatedSurface)
            }
            .frame(width: 36, height: 36)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 0) {
                Text(previewPlayer.currentTrackTitle ?? "Loading…")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(AppTheme.primaryText)
                    .lineLimit(1)
                Text(artistName)
                    .font(.caption2)
                    .foregroundStyle(AppTheme.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button {
                Task {
                    switch previewPlayer.state {
                    case .playing: previewPlayer.pause()
                    case .paused: await previewPlayer.resume()
                    default: break
                    }
                }
            } label: {
                Image(systemName: previewPlayer.isPlaying ? "pause.fill" : "play.fill")
                    .font(.body.weight(.bold))
                    .foregroundStyle(AppTheme.primaryText)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)

            Button {
                Task { await previewPlayer.skipNext() }
            } label: {
                Image(systemName: "forward.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.primaryText)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)

            Button {
                previewPlayer.stop()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(AppTheme.secondary)
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop preview")
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    /// Thin progress strip at the bottom of the mini-player. Re-renders ~5x/sec
    /// via TimelineView. Drag horizontally to scrub the play head — the bar
    /// also slightly thickens during the drag for easier targeting.
    private var miniPlayerProgress: some View {
        TimelineView(.periodic(from: .now, by: 0.2)) { _ in
            GeometryReader { geo in
                let liveFraction = currentPlaybackFraction
                // While the user is actively scrubbing, render the displayed
                // fraction from the gesture state so the bar tracks the finger
                // 1:1 instead of lagging behind player.playbackTime.
                let displayFraction = scrubFraction ?? liveFraction
                let isScrubbing = scrubFraction != nil

                VStack {
                    Spacer(minLength: 0)
                    ZStack(alignment: .leading) {
                        Capsule().fill(AppTheme.hairline)
                        Capsule()
                            .fill(AppTheme.accent)
                            .frame(width: max(0, geo.size.width * displayFraction))
                    }
                    .frame(height: isScrubbing ? 6 : 3)
                    .animation(.easeInOut(duration: 0.15), value: isScrubbing)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle().inset(by: -8))
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            // First event of this drag: capture the live fraction
                            // as the starting anchor.
                            if scrubStartFraction == nil {
                                scrubStartFraction = currentPlaybackFraction
                            }
                            let start = scrubStartFraction ?? 0
                            let delta = Double(value.translation.width / max(1, geo.size.width))
                            scrubFraction = min(1, max(0, start + delta))
                        }
                        .onEnded { _ in
                            commitScrub()
                            scrubStartFraction = nil
                        }
                )
            }
            .frame(height: 20) // generous gesture target; bar visually centered via VStack
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
        }
    }

    @MainActor
    private func commitScrub() {
        defer { scrubFraction = nil }
        guard let fraction = scrubFraction else { return }
        let trackMatch = tracks.first { $0.title == previewPlayer.currentTrackTitle }
        let duration = trackMatch?.duration ?? previewPlayer.currentTrackDuration ?? 0
        guard duration > 0 else { return }
        previewPlayer.seek(to: fraction * duration)
    }

    private var currentPlaybackFraction: Double {
        let position = previewPlayer.currentPlaybackTime
        // Prefer the duration we already loaded from the catalog for the currently
        // playing track — the MusicKit-level extraction often returns nil.
        let trackMatch = tracks.first { $0.title == previewPlayer.currentTrackTitle }
        let duration = trackMatch?.duration ?? previewPlayer.currentTrackDuration ?? 0
        guard duration > 0 else { return 0 }
        return min(1, max(0, position / duration))
    }

    private var releaseProvider: MusicProvider {
        MusicProvider.fromStoredName(release?.provider ?? MusicProvider.appleMusic.rawValue)
    }

    private func inlineStat(value: String, label: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(AppTheme.secondary)
                Text(value)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(AppTheme.primaryText)
            }
            Text(label)
                .font(.caption2)
                .foregroundStyle(AppTheme.secondary)
        }
    }

    @ViewBuilder
    private var tagsRow: some View {
        if let lastFMInfo, !lastFMInfo.tags.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(lastFMInfo.tags.prefix(6), id: \.self) { tag in
                        Text(tag.lowercased())
                            .font(.caption.weight(.medium))
                            .foregroundStyle(AppTheme.secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(AppTheme.surface))
                    }
                }
            }
            .scrollClipDisabled()
        }
    }

    private var artworkPlaceholder: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(AppTheme.elevatedSurface)
            .overlay {
                Image(systemName: "opticaldisc")
                    .font(.system(size: 48, weight: .light))
                    .foregroundStyle(AppTheme.secondary)
            }
    }

    private var formattedReleaseDate: String {
        guard let releaseDate else {
            return "Date unknown"
        }

        return releaseDate.formatted(date: .abbreviated, time: .omitted)
    }

    private func formattedCount(_ rawValue: String) -> String {
        guard let value = Int(rawValue) else { return rawValue }
        return value.formatted(.number.notation(.compactName))
    }

    @MainActor
    private func loadLastFMInfo() async {
        let service = LastFMService(apiKey: lastFMAPIKey)
        guard service.isConfigured else { return }

        do {
            lastFMInfo = try await service.fetchAlbumInfo(artistName: artistName, albumTitle: title)
            lastFMError = nil
        } catch {
            lastFMError = "Last.fm unavailable: \(error.localizedDescription)"
        }
    }
}

#Preview {
    NavigationStack {
        AlbumView()
    }
    .preferredColorScheme(.dark)
}

/// Fullscreen modal for the album artwork. Supports pinch-to-zoom (clamped 1...4×)
/// and a downward-drag to dismiss; otherwise dismissed via the close button.
private struct FullscreenArtworkView: View {
    let url: URL?
    let title: String
    let artistName: String
    let onClose: () -> Void

    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var dragOffset: CGSize = .zero

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            CachedAsyncImage(url: url) {
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.gray.opacity(0.2))
            }
            .aspectRatio(1, contentMode: .fit)
            .scaleEffect(scale)
            .offset(dragOffset)
            .gesture(
                MagnificationGesture()
                    .onChanged { value in
                        scale = min(4, max(1, lastScale * value))
                    }
                    .onEnded { _ in
                        lastScale = scale
                        if scale < 1.05 {
                            withAnimation(.spring(response: 0.3)) { scale = 1; lastScale = 1 }
                        }
                    }
            )
            .simultaneousGesture(
                DragGesture()
                    .onChanged { value in
                        // Only allow drag-to-dismiss when not zoomed in.
                        if scale <= 1.01 {
                            dragOffset = CGSize(width: 0, height: max(0, value.translation.height))
                        }
                    }
                    .onEnded { value in
                        if scale <= 1.01 && value.translation.height > 120 {
                            onClose()
                        } else {
                            withAnimation(.spring(response: 0.3)) { dragOffset = .zero }
                        }
                    }
            )
            .padding(.horizontal, 24)

            VStack {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(artistName)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.7))
                        Text(title)
                            .font(.headline)
                            .foregroundStyle(AppTheme.primaryText)
                            .lineLimit(1)
                    }
                    Spacer()
                    Button {
                        onClose()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.headline.weight(.bold))
                            .foregroundStyle(AppTheme.primaryText)
                            .frame(width: 38, height: 38)
                            .background(Circle().fill(Color.white.opacity(0.18)))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                Spacer()
            }
        }
        .statusBarHidden(true)
    }
}
