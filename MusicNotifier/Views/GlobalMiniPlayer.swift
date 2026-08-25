//
//  GlobalMiniPlayer.swift
//  MusicNotifier
//

import SwiftUI
import SwiftData

/// App-wide mini-player rendered at the ContentView root. Reads everything it
/// needs (title / artist / artwork / playback fraction) from the shared
/// `AlbumPreviewPlayer`, so it survives navigation away from AlbumView and
/// keeps showing while playback is active.
///
/// Tap → deep-links the user back into the source album via `DeepLinkRouter`.
/// X button stops playback and removes the bar. Forward skips to the next
/// queue entry.
struct GlobalMiniPlayer: View {
    @EnvironmentObject private var previewPlayer: AlbumPreviewPlayer
    @EnvironmentObject private var deepLinkRouter: DeepLinkRouter
    @Environment(\.modelContext) private var modelContext

    @State private var scrubFraction: Double?
    @State private var scrubStartFraction: Double?

    /// True when this player should self-render its own card background.
    /// The compact form is used inside `tabViewBottomAccessory`, which
    /// supplies the floating-pill material itself — adding a second card
    /// underneath would double the chrome. iPad / Catalyst's split layout
    /// has no tab bar and uses the carded form via a separate wrapper.
    let renderAsCard: Bool

    init(renderAsCard: Bool = false) {
        self.renderAsCard = renderAsCard
    }

    var body: some View {
        // Caller (ContentView's ZStack overlay) gates rendering on
        // `previewPlayer.isActive`, so this view is only ever in the
        // hierarchy when there's playback to surface.
        //
        // Progress strip is overlaid INSIDE the capsule clip so it
        // never extends past the pill's outline. Placing the
        // overlay before the card chrome means the chrome's clip
        // bounds the strip too.
        row
            .overlay(alignment: .bottom) { progressStrip }
            .clipShape(Capsule(style: .continuous))
            .modifier(CardChromeIfNeeded(active: renderAsCard))
    }

    /// Pill-shaped glass card that mimics iOS 26's native floating
    /// `tabViewBottomAccessory` look: capsule clip, `.regularMaterial`
    /// (darker / more opaque than `.ultraThinMaterial`, matching the
    /// system tab-bar pill), hairline rim highlight at the top to
    /// suggest the refractive edge, soft shadow underneath.
    private struct CardChromeIfNeeded: ViewModifier {
        let active: Bool
        func body(content: Content) -> some View {
            if active {
                content
                    // `.bar` is the material UIKit uses for toolbars and
                    // tab bars — the closest match to the system tab pill
                    // sitting just below the mini-player, so the two read
                    // as the same kind of glass.
                    .background(.bar, in: Capsule(style: .continuous))
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(0.18),
                                        Color.white.opacity(0.03),
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                ),
                                lineWidth: 0.5
                            )
                    )
                    .shadow(color: .black.opacity(0.4), radius: 18, x: 0, y: 6)
                    // Horizontal inset matches AlbumView's track list
                    // (and the rest of the app content) so the pill sits
                    // within the same gutter, reading as part of the same
                    // visual column rather than floating edge-to-edge.
                    .padding(.horizontal, 20)
            } else {
                content
            }
        }
    }

    private var row: some View {
        HStack(spacing: 12) {
            // Whole left region (artwork + 2-line text) tappable as one
            // target — mirrors Apple Music's mini-player. Keeps the right
            // edge controls cleanly separated and individually tappable.
            Button {
                openSourceAlbum()
            } label: {
                HStack(spacing: 10) {
                    CachedAsyncImage(url: previewPlayer.currentArtworkURL) {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(AppTheme.elevatedSurface)
                    }
                    .frame(width: 38, height: 38)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                    VStack(alignment: .leading, spacing: 1) {
                        Text(previewPlayer.currentTrackTitle ?? "Loading…")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AppTheme.primaryText)
                            .lineLimit(1)
                        if let artist = previewPlayer.currentArtistName {
                            Text(artist)
                                .font(.caption2)
                                .foregroundStyle(AppTheme.secondary)
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: 0)
                }
                // Push the text region to fill so the whole left area is
                // tappable — without this, the chevron-free row only takes
                // its intrinsic width and the trailing buttons drift left.
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

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
                    .font(.title3.weight(.bold))
                    .foregroundStyle(AppTheme.primaryText)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                previewPlayer.stop()
            } label: {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(AppTheme.secondary)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop preview")
        }
        // Leading padding pushes the artwork inside the capsule's
        // curvature so its left edge isn't clipped by the rounded corner.
        // Trailing has less inset since the X icon already sits within
        // its own 30pt frame and visually pads itself.
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .padding(.vertical, 6)
    }

    /// Thin progress strip overlaid at the bottom of the row. Bounded by
    /// the row's width via `.overlay(alignment: .bottom)`, so no
    /// GeometryReader needed — we use `.frame(maxWidth: .infinity)` on a
    /// container and read the live fraction every 200ms.
    private var progressStrip: some View {
        TimelineView(.periodic(from: .now, by: 0.2)) { _ in
            let liveFraction = currentPlaybackFraction
            let displayFraction = scrubFraction ?? liveFraction
            let isScrubbing = scrubFraction != nil

            GeometryReader { geo in
                // Floor the filled-portion width at ~6pt while playback
                // is active so the bar is immediately visible the moment
                // playback starts. MusicKit's `playbackTime` reports 0
                // for several seconds after `play()` returns — keying
                // off `previewPlayer.isActive` (not the fraction) means
                // the strip shows the floor as soon as the user sees
                // the mini-player appear.
                let targetWidth = geo.size.width * displayFraction
                let filledWidth = max(0, targetWidth)
                ZStack(alignment: .leading) {
                    Capsule().fill(AppTheme.hairline.opacity(0.4))
                    Capsule()
                        .fill(AppTheme.accent)
                        .frame(width: filledWidth)
                }
                .frame(height: isScrubbing ? 7 : 2)
                .animation(.easeInOut(duration: 0.15), value: isScrubbing)
                .contentShape(Rectangle().inset(by: -10))
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
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
            .frame(height: isScrubbing ? 4 : 2)
            // Horizontal inset only — keeps the strip away from the
            // bottom-left curve where `.clipShape(Capsule)` was
            // clipping the leading fill to zero (was the real cause
            // of the ~8s delay before the strip became visible).
            // Bottom stays flush with the capsule edge.
            .padding(.horizontal, 16)
            // No horizontal padding — the outer `.clipShape(Capsule)`
            // rounds the strip's ends to the pill curve, so the line
            // visually integrates with the capsule outline instead of
            // floating inside it.
        }
    }

    @MainActor
    private func commitScrub() {
        defer { scrubFraction = nil }
        guard let fraction = scrubFraction else { return }
        let duration = previewPlayer.currentTrackDuration ?? 0
        guard duration > 0 else { return }
        previewPlayer.seek(to: fraction * duration)
    }

    private var currentPlaybackFraction: Double {
        let position = previewPlayer.currentPlaybackTime
        let duration = previewPlayer.currentTrackDuration ?? 0
        guard duration > 0 else { return 0 }
        return min(1, max(0, position / duration))
    }

    /// Look up the ReleaseData for the album currently playing and ask
    /// DeepLinkRouter to surface its AlbumView sheet — same path the
    /// notification deep-link uses.
    private func openSourceAlbum() {
        guard let providerID = previewPlayer.currentAlbumProviderID else { return }
        let descriptor = FetchDescriptor<ReleaseData>(
            predicate: #Predicate { $0.providerID == providerID }
        )
        if let release = (try? modelContext.fetch(descriptor))?.first {
            deepLinkRouter.selectedRelease = release
        }
    }
}
