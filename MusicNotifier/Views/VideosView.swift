//
//  VideosView.swift
//  MusicNotifier
//

import SwiftUI
import SwiftData

struct VideosView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \VideoData.releaseDate, order: .reverse) private var videos: [VideoData]
    @State private var filter: VideoFilter = .all
    @State private var searchText: String = ""

    private enum VideoFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case musicVideos = "Videos"
        case interviews = "Interviews"
        var id: String { rawValue }

        var icon: String {
            switch self {
            case .all: return "square.stack.fill"
            case .musicVideos: return "play.rectangle.fill"
            case .interviews: return "mic.fill"
            }
        }
    }

    private var filteredVideos: [VideoData] {
        let kindFiltered: [VideoData]
        switch filter {
        case .all: kindFiltered = videos
        case .musicVideos: kindFiltered = videos.filter { VideoKind(rawValue: $0.kind) == .musicVideo }
        case .interviews: kindFiltered = videos.filter { VideoKind(rawValue: $0.kind) == .interview }
        }
        guard !searchText.trimmingCharacters(in: .whitespaces).isEmpty else { return kindFiltered }
        let needle = searchText.lowercased()
        return kindFiltered.filter {
            $0.title.lowercased().contains(needle) || $0.artistName.lowercased().contains(needle)
        }
    }

    private var featured: VideoData? { filteredVideos.first { !$0.isSeen } ?? filteredVideos.first }

    private var rest: [VideoData] {
        guard let f = featured else { return [] }
        return filteredVideos.filter { $0.persistentModelID != f.persistentModelID }
    }

    private struct DateSection: Identifiable {
        let id: String
        let title: String
        let items: [VideoData]
    }

    private var sections: [DateSection] {
        let cal = Calendar.current
        let now = Date()
        let weekStart = cal.date(byAdding: .day, value: -7, to: now) ?? now
        let monthStart = cal.date(byAdding: .day, value: -30, to: now) ?? now

        var thisWeek: [VideoData] = []
        var thisMonth: [VideoData] = []
        var earlier: [VideoData] = []
        for v in rest {
            guard let d = v.releaseDate else { earlier.append(v); continue }
            if d >= weekStart { thisWeek.append(v) }
            else if d >= monthStart { thisMonth.append(v) }
            else { earlier.append(v) }
        }
        var out: [DateSection] = []
        if !thisWeek.isEmpty { out.append(.init(id: "w", title: "This Week", items: thisWeek)) }
        if !thisMonth.isEmpty { out.append(.init(id: "m", title: "This Month", items: thisMonth)) }
        if !earlier.isEmpty { out.append(.init(id: "e", title: "Earlier", items: earlier)) }
        return out
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 24, pinnedViews: []) {
                    filterRow
                        .padding(.horizontal, 20)

                    if filteredVideos.isEmpty {
                        emptyState
                    } else {
                        if let featured {
                            FeaturedVideoCard(video: featured)
                                .padding(.horizontal, 20)
                                .onTapGesture { openVideo(featured) }
                                .contextMenu { videoContextMenu(featured) }
                        }
                        ForEach(sections) { section in
                            VStack(alignment: .leading, spacing: 12) {
                                HStack {
                                    Text(section.title)
                                        .font(.system(size: 13, weight: .heavy))
                                        .tracking(1.4)
                                        .foregroundStyle(AppTheme.secondary)
                                    Spacer()
                                    Text("\(section.items.count)")
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(AppTheme.secondary.opacity(0.6))
                                }
                                .padding(.horizontal, 20)
                                LazyVStack(spacing: 12) {
                                    ForEach(section.items) { video in
                                        VideoPosterRow(video: video)
                                            .padding(.horizontal, 20)
                                            .onTapGesture { openVideo(video) }
                                            .contextMenu { videoContextMenu(video) }
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.top, 4)
                .padding(.bottom, 32)
            }
            .navigationTitle("Videos")
            .navigationBarTitleDisplayMode(.large)
            .appScreenBackground()
            .searchable(text: $searchText, prompt: "Search videos & interviews")
        }
        .tint(AppTheme.accent)
    }

    private var filterRow: some View {
        HStack(spacing: 8) {
            ForEach(VideoFilter.allCases) { option in
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

    private var emptyState: some View {
        VStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(AppTheme.elevatedSurface)
                    .frame(width: 96, height: 96)
                Image(systemName: "play.rectangle.on.rectangle.fill")
                    .font(.system(size: 40, weight: .regular))
                    .foregroundStyle(AppTheme.accent)
            }
            Text("Nothing to watch yet")
                .font(.title3.weight(.bold))
                .foregroundStyle(AppTheme.primaryText)
            Text("New music videos and interviews from your tracked artists land here automatically.")
                .font(.footnote)
                .foregroundStyle(AppTheme.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    @ViewBuilder
    private func videoContextMenu(_ video: VideoData) -> some View {
        if let url = video.videoURL {
            Button {
                UIApplication.shared.open(url)
            } label: {
                Label("Open in Apple Music", systemImage: "play.rectangle")
            }
            ShareLink(item: url) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
        }
        Divider()
        Button {
            video.isSeen.toggle()
            try? modelContext.save()
        } label: {
            Label(video.isSeen ? "Mark unseen" : "Mark seen",
                  systemImage: video.isSeen ? "circle" : "checkmark.circle")
        }
    }

    private func openVideo(_ video: VideoData) {
        if !video.isSeen {
            video.isSeen = true
            try? modelContext.save()
        }
        if let url = video.videoURL {
            UIApplication.shared.open(url)
        }
    }
}

// MARK: - Featured (hero) card

/// Surfaces a third visual category (LIVE) on top of the stored `VideoKind`
/// by inspecting the title — Apple Music doesn't flag live performances
/// separately, but they read very differently from a studio music video.
private enum VideoDisplayKind {
    case musicVideo, interview, live

    static func resolve(_ video: VideoData) -> VideoDisplayKind {
        let stored = VideoKind(rawValue: video.kind) ?? .musicVideo
        if stored == .interview { return .interview }
        if Self.titleSuggestsLive(video.title) { return .live }
        return .musicVideo
    }

    private static func titleSuggestsLive(_ title: String) -> Bool {
        let lower = title.lowercased()
        let patterns = ["(live", "[live", " live ", " live at ", " live from ",
                        " live in ", " live on ", " live session", "live performance",
                        " - live", "– live", "— live", "live @ ", " livestream"]
        if patterns.contains(where: { lower.contains($0) }) { return true }
        // Word-boundary fallback so "alive" / "olive" don't match.
        let tokens = lower.split { !$0.isLetter }
        return tokens.contains("live")
    }

    var label: String {
        switch self {
        case .musicVideo: return "VIDEO"
        case .interview: return "INTERVIEW"
        case .live: return "LIVE"
        }
    }

    var icon: String {
        switch self {
        case .musicVideo: return "play.fill"
        case .interview: return "mic.fill"
        case .live: return "dot.radiowaves.left.and.right"
        }
    }
}

private struct FeaturedVideoCard: View {
    let video: VideoData

    private var displayKind: VideoDisplayKind { .resolve(video) }

    private var durationLabel: String? {
        guard let ms = video.durationMs, ms > 0 else { return nil }
        let total = ms / 1000
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            CachedAsyncImage(url: video.artworkURL) {
                Rectangle().fill(AppTheme.elevatedSurface)
            }
            .aspectRatio(16/9, contentMode: .fill)
            .frame(maxWidth: .infinity)
            .clipped()

            LinearGradient(
                colors: [.black.opacity(0.0), .black.opacity(0.45), .black.opacity(0.95)],
                startPoint: .top,
                endPoint: .bottom
            )

            // Top row: kind badge + duration
            VStack {
                HStack(spacing: 8) {
                    HStack(spacing: 5) {
                        Image(systemName: displayKind.icon)
                            .font(.caption2.weight(.heavy))
                        Text(displayKind.label)
                            .font(.caption2.weight(.heavy))
                            .tracking(0.9)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(AppTheme.accent))
                    .foregroundStyle(AppTheme.primaryText)

                    Spacer()

                    if let durationLabel {
                        Text(durationLabel)
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(.black.opacity(0.65)))
                            .foregroundStyle(AppTheme.primaryText)
                    }
                }
                Spacer()
            }
            .padding(14)

            // Bottom info
            VStack(alignment: .leading, spacing: 8) {
                Text(video.artistName.uppercased())
                    .font(.system(size: 11, weight: .heavy))
                    .tracking(1.3)
                    .foregroundStyle(AppTheme.accent)
                    .lineLimit(1)

                Text(video.title)
                    .font(.system(size: 24, weight: .heavy, design: .rounded))
                    .foregroundStyle(AppTheme.primaryText)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)

                if let date = video.releaseDate {
                    Text(date, style: .date)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(video.isSeen ? AppTheme.hairline : AppTheme.accent.opacity(0.55),
                        lineWidth: video.isSeen ? 0.5 : 1.5)
        )
        .shadow(color: .black.opacity(0.4), radius: 16, y: 8)
    }
}

// MARK: - Compact poster row

private struct VideoPosterRow: View {
    let video: VideoData

    private var displayKind: VideoDisplayKind { .resolve(video) }

    private var badgeFill: Color {
        switch displayKind {
        case .interview, .live: return AppTheme.accent
        case .musicVideo: return .black.opacity(0.65)
        }
    }

    private var durationLabel: String? {
        guard let ms = video.durationMs, ms > 0 else { return nil }
        let total = ms / 1000
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            CachedAsyncImage(url: video.artworkURL) {
                Rectangle().fill(AppTheme.elevatedSurface)
            }
            .aspectRatio(16/9, contentMode: .fill)
            .frame(maxWidth: .infinity)
            .clipped()

            LinearGradient(
                colors: [.black.opacity(0.0), .black.opacity(0.3), .black.opacity(0.92)],
                startPoint: .top,
                endPoint: .bottom
            )

            // Top badges
            VStack {
                HStack(spacing: 6) {
                    HStack(spacing: 4) {
                        Image(systemName: displayKind.icon)
                            .font(.system(size: 9, weight: .heavy))
                        Text(displayKind.label)
                            .font(.system(size: 9, weight: .heavy))
                            .tracking(0.8)
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(badgeFill))
                    .foregroundStyle(AppTheme.primaryText)

                    Spacer()
                    if let durationLabel {
                        Text(durationLabel)
                            .font(.system(size: 11, weight: .bold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(.black.opacity(0.7)))
                            .foregroundStyle(AppTheme.primaryText)
                    }
                }
                Spacer()
            }
            .padding(10)

            // Bottom info
            HStack(alignment: .bottom, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(video.artistName.uppercased())
                        .font(.system(size: 10, weight: .heavy))
                        .tracking(1.0)
                        .foregroundStyle(AppTheme.accent)
                        .lineLimit(1)
                    Text(video.title)
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(AppTheme.primaryText)
                        .lineLimit(2)
                    HStack(spacing: 6) {
                        if let source = video.sourceName, source != video.artistName {
                            Text(source).lineLimit(1)
                        }
                        if video.sourceName != nil && video.sourceName != video.artistName,
                           video.releaseDate != nil {
                            Text("·")
                        }
                        if let date = video.releaseDate {
                            Text(date, style: .date)
                        }
                    }
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.white.opacity(0.65))
                }
                Spacer(minLength: 0)
                if !video.isSeen {
                    Circle()
                        .fill(AppTheme.accent)
                        .frame(width: 9, height: 9)
                        .shadow(color: AppTheme.accent.opacity(0.8), radius: 4)
                        .padding(.bottom, 4)
                }
            }
            .padding(12)
        }
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(video.isSeen ? AppTheme.hairline : AppTheme.accent.opacity(0.45),
                        lineWidth: video.isSeen ? 0.5 : 1)
        )
    }
}
