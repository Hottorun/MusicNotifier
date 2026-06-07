//
//  ArtistDetailView.swift
//  MusicNotifier
//

import SwiftUI
import SwiftData

struct ArtistDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openURL) private var openURL
    @Bindable var artist: ArtistData
    @Query private var releases: [ReleaseData]
    @Query private var allArtists: [ArtistData]
    @AppStorage(AppSettings.lastFMAPIKey) private var lastFMAPIKey = AppSettings.defaultLastFMAPIKey
    @State private var lastFMInfo: LastFMArtistInfo?
    @State private var lastFMError: String?
    @State private var showingBio = false
    @State private var similarPushTarget: ArtistData?
    @State private var similarArtworkByName: [String: URL] = SimilarArtistArtworkCache.shared.snapshot()

    init(artist: ArtistData) {
        self.artist = artist
        // Push the artist filter into SwiftData rather than fetching the entire
        // release table and filtering in memory — important when the library
        // grows past a few hundred releases.
        let providerID = artist.providerID
        _releases = Query(
            filter: #Predicate<ReleaseData> { $0.artistProviderID == providerID },
            sort: \ReleaseData.releaseDate,
            order: .reverse
        )

        // Seed Last.fm info from the on-disk cache so bio/stats/similar
        // artists are present on the first body render. Same pattern as
        // AlbumView's TrackCache seed.
        let apiKey = UserDefaults.standard.string(forKey: AppSettings.lastFMAPIKey)
            ?? AppSettings.defaultLastFMAPIKey
        let service = LastFMService(apiKey: apiKey)
        if service.isConfigured, let cached = service.cachedArtistInfo(artistName: artist.name) {
            _lastFMInfo = State(initialValue: cached)
        }
    }

    private var releasesByYear: [(String, [ReleaseData])] {
        let grouped = Dictionary(grouping: releases) { release in
            guard let releaseDate = release.releaseDate else { return "Unknown" }
            return String(Calendar.current.component(.year, from: releaseDate))
        }
        return grouped
            .map { ($0.key, $0.value) }
            .sorted { $0.0 > $1.0 }
    }

    private var lastFMConfigured: Bool {
        !lastFMAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                hero
                quickActions
                // Releases come *before* bio/similar so the timeline (the
                // primary reason to land on this page) doesn't sit below a
                // wall of text-heavy artist context.
                if releases.isEmpty {
                    timelineEmptyState
                } else {
                    timeline
                }
                supplementalContext
            }
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        // Empty nav title — the hero card displays the artist name in full.
        // The back chevron alone is enough chrome at the top.
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .appScreenBackground()
        .navigationDestination(for: ReleaseData.self) { release in
            AlbumView(release: release)
        }
        .task {
            await loadLastFMInfo()
        }
        .sheet(isPresented: $showingBio) {
            bioSheet
        }
        .onChange(of: artist.isTracked) { _, _ in try? modelContext.save() }
        .navigationDestination(item: $similarPushTarget) { ArtistDetailView(artist: $0) }
        .tracksTabNavigationDepth()
    }

    // MARK: - Hero

    /// Wide poster-style hero: the artist's artwork fills the full card,
    /// a dark gradient brings text contrast at the bottom, and the name +
    /// stats sit on top of the artwork itself. Replaces the previous
    /// detached "circle on empty bg" composition, which read as a placeholder
    /// rather than a hero. Nav title is hidden in `body` so the large name
    /// here is the only one.
    private var hero: some View {
        ZStack(alignment: .bottomLeading) {
            CachedAsyncImage(url: artist.artworkURL) {
                Rectangle().fill(AppTheme.elevatedSurface)
                    .overlay {
                        Image(systemName: "person.fill")
                            .font(.system(size: 48, weight: .light))
                            .foregroundStyle(AppTheme.secondary)
                    }
            }
            .aspectRatio(contentMode: .fill)
            .frame(height: 280)
            .frame(maxWidth: .infinity)
            .clipped()

            // Heavy bottom gradient — keeps the text legible regardless of
            // how light the artwork is. Top ~40% stays nearly transparent so
            // the artwork still reads.
            LinearGradient(
                colors: [
                    .black.opacity(0),
                    .black.opacity(0.35),
                    .black.opacity(0.85)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 8) {
                Text(artist.name)
                    .font(.system(size: 30, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .shadow(color: .black.opacity(0.5), radius: 8, y: 2)

                HStack(spacing: 6) {
                    heroMetric("\(releases.count)", "releases")
                    heroDot
                    if lastFMConfigured, let info = lastFMInfo {
                        heroMetric(compact(info.listeners), "listeners")
                        heroDot
                        heroMetric(compact(info.playcount), "plays")
                    } else if let lastCheckedAt = artist.lastCheckedAt {
                        heroMetric(shortDate(lastCheckedAt), "checked")
                    } else {
                        heroMetric(artist.addedAt.formatted(date: .abbreviated, time: .omitted), "since")
                    }
                }
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.85))
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 18)
        }
        .frame(height: 280)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(AppTheme.hairline, lineWidth: 1)
        )
        .padding(.horizontal, 16)
    }

    private func heroMetric(_ value: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(value).foregroundStyle(.white).fontWeight(.bold)
            Text(label).foregroundStyle(.white.opacity(0.75))
        }
    }

    private var heroDot: some View {
        Circle().fill(.white.opacity(0.5)).frame(width: 3, height: 3)
    }

    // MARK: - Quick actions

    private var quickActions: some View {
        HStack(spacing: 10) {
            followTile
            if let catalogID = artist.catalogArtistID,
               let url = URL(string: "https://music.apple.com/artist/\(catalogID)") {
                appleMusicIconButton(url: url)
            }
        }
        .padding(.horizontal, 20)
    }

    /// Bio + similar artists. Renders below the timeline so the page leads
    /// with releases — supplementary context lives at the end.
    @ViewBuilder
    private var supplementalContext: some View {
        VStack(spacing: 14) {
            if lastFMConfigured, let bio = lastFMInfo?.bio, !bio.isEmpty {
                bioPreview(bio)
            }
            if let lastFMInfo, !lastFMInfo.similarArtists.isEmpty {
                similarArtistsRow(lastFMInfo.similarArtists)
            }
        }
        .padding(.horizontal, 20)
    }

    /// Single Follow / Following tile. No per-type customization — either
    /// notifications are on (inherits global preference) or off.
    private var followTile: some View {
        Button {
            artist.isTracked.toggle()
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(AppTheme.elevatedSurface)
                        .frame(width: 36, height: 36)
                    Image(systemName: artist.isTracked ? "checkmark" : "plus")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(artist.isTracked ? .white : AppTheme.secondary)
                }

                Text(artist.isTracked ? "Following" : "Follow")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.primaryText)

                Spacer()
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 60)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(AppTheme.surface))
        }
        .buttonStyle(.plain)
    }

    private func bioPreview(_ bio: String) -> some View {
        Button {
            showingBio = true
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("About")
                        .font(.caption.weight(.semibold))
                        .tracking(0.6)
                        .foregroundStyle(AppTheme.secondary)
                    Spacer()
                    Text("Read more")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.accent)
                }
                Text(bio)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(AppTheme.surface))
        }
        .buttonStyle(.plain)
    }

    /// Square accent-tinted icon button matched in height to the follow tile
    /// so they sit cleanly on one row.
    private func appleMusicIconButton(url: URL) -> some View {
        Link(destination: url) {
            Image(systemName: "arrow.up.right.square")
                .font(.title3.weight(.semibold))
                .foregroundStyle(AppTheme.accent)
                .frame(width: 60, height: 60)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(AppTheme.surface))
        }
        .accessibilityLabel("Open in Apple Music")
    }

    private func similarArtistsRow(_ names: [String]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Similar artists")
                .font(.caption.weight(.semibold))
                .tracking(0.6)
                .foregroundStyle(AppTheme.secondary)
                .padding(.horizontal, 2)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(names.prefix(12), id: \.self) { name in
                        Button {
                            handleSimilarArtistTap(name)
                        } label: {
                            similarArtistCard(name: name)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 2)
            }
            .scrollClipDisabled()
        }
        .padding(.top, 4)
        .task(id: names.joined(separator: ",")) {
            await loadSimilarArtistArtwork(names: Array(names.prefix(12)))
        }
    }

    private func similarArtistCard(name: String) -> some View {
        VStack(spacing: 6) {
            CachedAsyncImage(url: similarArtworkByName[name]) {
                Circle()
                    .fill(AppTheme.elevatedSurface)
                    .overlay {
                        Text(String(name.prefix(1)))
                            .font(.headline.weight(.bold))
                            .foregroundStyle(AppTheme.secondary)
                    }
            }
            .frame(width: 64, height: 64)
            .clipShape(Circle())

            Text(name)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.primaryText)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 80)
        }
    }

    @MainActor
    private func loadSimilarArtistArtwork(names: [String]) async {
        // Skip names we've already resolved this session — keyed by exact name
        // string since Last.fm gives us the catalog form.
        let missing = names.filter { similarArtworkByName[$0] == nil }
        guard !missing.isEmpty else { return }

        let resolved: [(String, URL?)] = await withTaskGroup(of: (String, URL?).self) { group in
            for name in missing {
                group.addTask {
                    let results = try? await AppleMusicLibraryImportService().searchCatalogArtists(term: name)
                    let url = results?.first?.artwork?.url(width: 200, height: 200)
                    return (name, url)
                }
            }
            var out: [(String, URL?)] = []
            for await result in group { out.append(result) }
            return out
        }
        for (name, url) in resolved {
            if let url {
                similarArtworkByName[name] = url
                SimilarArtistArtworkCache.shared.store(url, for: name)
            }
        }
    }

    /// Tap a similar artist: navigate to their detail page if we already track
    /// them locally, otherwise open the artist in Apple Music for browsing.
    private func handleSimilarArtistTap(_ name: String) {
        if let local = allArtists.first(where: { $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) {
            similarPushTarget = local
            return
        }
        guard let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://music.apple.com/search?term=\(encoded)") else { return }
        openURL(url)
    }

    // MARK: - Timeline

    private var timeline: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Releases")
                    .font(.headline)
                    .foregroundStyle(AppTheme.primaryText)
                Spacer()
                Text("\(releases.count) total")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(AppTheme.secondary)
            }
            .padding(.horizontal, 20)

            ForEach(releasesByYear, id: \.0) { year, releases in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text(year)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(AppTheme.accent)
                        Rectangle()
                            .fill(AppTheme.hairline)
                            .frame(height: 1)
                    }
                    .padding(.horizontal, 20)

                    VStack(spacing: 8) {
                        ForEach(releases) { release in
                            NavigationLink(value: release) {
                                releaseRow(release)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 20)
                }
            }
        }
    }

    private var timelineEmptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "calendar.badge.exclamationmark")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(AppTheme.secondary)
            Text("No releases tracked yet")
                .font(.headline)
                .foregroundStyle(AppTheme.primaryText)
            Text("Refresh releases from Home to populate this timeline.")
                .font(.footnote)
                .foregroundStyle(AppTheme.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .padding(.horizontal, 24)
    }

    private func releaseRow(_ release: ReleaseData) -> some View {
        HStack(spacing: 12) {
            CachedAsyncImage(url: release.artworkURL) {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(AppTheme.elevatedSurface)
            }
            .frame(width: 52, height: 52)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(ReleaseTitleFormatter.displayTitle(release.title))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.primaryText)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(release.type)
                    Text("·")
                    Text(formattedDate(release.releaseDate))
                }
                .font(.caption)
                .foregroundStyle(AppTheme.secondary)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption2.weight(.bold))
                .foregroundStyle(AppTheme.secondary)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(AppTheme.surface))
    }

    // MARK: - Bio sheet

    private var bioSheet: some View {
        NavigationStack {
            ScrollView {
                Text(lastFMInfo?.bio ?? "")
                    .font(.body)
                    .foregroundStyle(AppTheme.primaryText)
                    .padding(20)
            }
            .appScreenBackground()
            .navigationTitle(artist.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showingBio = false }
                        .foregroundStyle(AppTheme.navAccent)
                }
            }
        }
    }

    // MARK: - Helpers

    private func formattedDate(_ date: Date?) -> String {
        guard let date else { return "Date unknown" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    private func shortDate(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .omitted)
    }

    private func compact(_ rawValue: String) -> String {
        guard let value = Int(rawValue) else { return rawValue }
        return value.formatted(.number.notation(.compactName))
    }

    @MainActor
    private func loadLastFMInfo() async {
        let service = LastFMService(apiKey: lastFMAPIKey)
        guard service.isConfigured else { return }

        do {
            lastFMInfo = try await service.fetchArtistInfo(artistName: artist.name)
            lastFMError = nil
        } catch {
            lastFMError = "Last.fm unavailable: \(error.localizedDescription)"
        }
    }
}

#Preview {
    NavigationStack {
        ArtistDetailView(
            artist: ArtistData(providerID: "1", name: "Example Artist", isTracked: true)
        )
    }
    .modelContainer(for: [ArtistData.self, ReleaseData.self], inMemory: true)
}
