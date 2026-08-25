//
//  AlbumPreviewPlayer.swift
//  MusicNotifier
//

import Foundation
import MusicKit
import Combine

/// Wraps `ApplicationMusicPlayer` for in-app album preview playback.
/// Tries to play the catalog album by its provider ID. The system plays full tracks
/// for Apple Music subscribers and 30s previews for others.
@MainActor
final class AlbumPreviewPlayer: ObservableObject {
    enum State {
        case idle
        case loading
        case playing
        case paused
        case error(String)
    }

    @Published private(set) var state: State = .idle

    /// Human-readable failure from the last playback attempt, or `nil`.
    /// `play(...)` has always set `state = .error(...)` on failure, but no
    /// view ever rendered that case — so a Play tap that MusicKit rejected
    /// (no Apple Music subscription, region-locked album, playback
    /// unavailable) looked like a dead button. Views observe this to show it.
    var errorMessage: String? {
        if case .error(let message) = state { return message }
        return nil
    }

    /// Clears a surfaced error back to idle once the user has dismissed it,
    /// so the next Play attempt starts from a clean state.
    func clearError() {
        if case .error = state { state = .idle }
    }

    @Published private(set) var currentTrackTitle: String?
    /// Provider ID of the album currently in the queue. Drives the global
    /// mini-player's tap-to-jump-back deep link — without this, the bar
    /// would have no way to know which AlbumView to push the user into.
    @Published private(set) var currentAlbumProviderID: String?
    /// Album-level metadata cached on the player so the global mini-player
    /// can render without reading any AlbumView state — without these, the
    /// bar would have no artwork / artist name to show once the user
    /// navigates away from the source album.
    @Published private(set) var currentArtistName: String?
    @Published private(set) var currentArtworkURL: URL?

    private let player = ApplicationMusicPlayer.shared
    private var stateObserver: AnyCancellable?
    /// Set during stop() so post-stop transient observer events don't bring the
    /// mini-player back to life right after the user dismissed it.
    private var suppressObserver = false
    /// Snapshot of the Music app's playback state captured the moment we start a
    /// preview. SystemMusicPlayer keeps its own queue, so on stop we only need
    /// to know whether to resume it — the surrounding tracks come back for free.
    private var systemPlayerWasPlaying = false

    /// Polls the current queue entry's title every 0.5s while playing. The
    /// player's state observer fires on play/pause/stop but NOT when the queue
    /// advances to the next track within an active session — without this, the
    /// mini-player + Tracks list stay stuck showing the title the user originally
    /// tapped.
    private var titlePoller: Timer?

    init() {
        // Observe the player's state to keep UI in sync. The title-poll timer
        // is created on-demand in startTitlePolling() so that an AlbumView
        // mounted by the user merely browsing an album doesn't fire a Timer
        // tick every 500ms forever — only while playback is actually active.
        let playerState = ApplicationMusicPlayer.shared.state
        stateObserver = playerState.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.syncPlaybackState()
            }
    }

    private func startTitlePolling() {
        guard titlePoller == nil else { return }
        titlePoller = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let latest = self.player.queue.currentEntry?.title
                if latest != nil && latest != self.currentTrackTitle {
                    self.currentTrackTitle = latest
                }
            }
        }
    }

    private func stopTitlePolling() {
        titlePoller?.invalidate()
        titlePoller = nil
    }

    func play(albumProviderID: String) async {
        guard !albumProviderID.isEmpty else {
            state = .error("Missing album ID.")
            return
        }
        captureSystemPlayerState()
        state = .loading
        do {
            let request = MusicCatalogResourceRequest<Album>(
                matching: \.id,
                equalTo: MusicItemID(albumProviderID)
            )
            let response = try await request.response()
            guard let album = response.items.first else {
                state = .error("Album not found.")
                return
            }
            // Hydrate the duration cache before queuing playback so the
            // global mini-player has duration data immediately for the
            // first track that starts playing.
            let detailed = (try? await album.with([.tracks])) ?? album
            cacheTrackDurations(detailed.tracks ?? MusicItemCollection<Track>())
            player.queue = ApplicationMusicPlayer.Queue(for: [album])
            try await player.play()
            state = .playing
            currentTrackTitle = player.queue.currentEntry?.title
            currentAlbumProviderID = albumProviderID
            currentArtistName = album.artistName
            currentArtworkURL = album.artwork?.url(width: 200, height: 200)
        } catch {
            state = .error(await Self.playbackFailureMessage(error))
        }
    }

    /// Build the title→duration lookup the mini-player falls back on when
    /// MusicKit's queue entry item refuses to cast to a typed model.
    private func cacheTrackDurations(_ tracks: MusicItemCollection<Track>) {
        var map: [String: TimeInterval] = [:]
        for track in tracks {
            if let duration = track.duration {
                map[track.title] = duration
            }
        }
        cachedTrackDurations = map
    }

    /// Start playback at a specific track within the album.
    func play(albumProviderID: String, startingAtTrackID trackID: String) async {
        guard !albumProviderID.isEmpty, !trackID.isEmpty else {
            state = .error("Missing track ID.")
            return
        }
        captureSystemPlayerState()
        state = .loading
        do {
            let request = MusicCatalogResourceRequest<Album>(
                matching: \.id,
                equalTo: MusicItemID(albumProviderID)
            )
            let response = try await request.response()
            guard let album = response.items.first else {
                state = .error("Album not found.")
                return
            }
            let detailed = try await album.with([.tracks])
            let tracks = detailed.tracks ?? MusicItemCollection<Track>()
            cacheTrackDurations(tracks)
            guard let startTrack = tracks.first(where: { $0.id.rawValue == trackID }) else {
                player.queue = ApplicationMusicPlayer.Queue(for: [album])
                try await player.play()
                state = .playing
                currentTrackTitle = player.queue.currentEntry?.title
                currentAlbumProviderID = albumProviderID
                currentArtistName = album.artistName
                currentArtworkURL = album.artwork?.url(width: 200, height: 200)
                return
            }
            player.queue = ApplicationMusicPlayer.Queue(for: tracks, startingAt: startTrack)
            try await player.play()
            state = .playing
            currentTrackTitle = player.queue.currentEntry?.title
            currentAlbumProviderID = albumProviderID
            currentArtistName = album.artistName
            currentArtworkURL = album.artwork?.url(width: 200, height: 200)
        } catch {
            state = .error(await Self.playbackFailureMessage(error))
        }
    }

    /// Add the catalog album to the user's Apple Music library.
    func addToLibrary(albumProviderID: String) async throws {
        guard !albumProviderID.isEmpty else { return }
        let request = MusicCatalogResourceRequest<Album>(
            matching: \.id,
            equalTo: MusicItemID(albumProviderID)
        )
        let response = try await request.response()
        guard let album = response.items.first else { return }
        #if os(iOS) || os(visionOS) || targetEnvironment(macCatalyst)
        try await MusicLibrary.shared.add(album)
        #endif
    }

    /// Add an individual catalog song to the library via its track ID.
    func addSongToLibrary(songID: String) async throws {
        guard !songID.isEmpty else { return }
        let request = MusicCatalogResourceRequest<Song>(
            matching: \.id,
            equalTo: MusicItemID(songID)
        )
        let response = try await request.response()
        guard let song = response.items.first else { return }
        #if os(iOS) || os(visionOS) || targetEnvironment(macCatalyst)
        try await MusicLibrary.shared.add(song)
        #endif
    }

    /// Turn a MusicKit playback failure into copy a user can act on.
    /// `error.localizedDescription` for these is developer-facing noise —
    /// "The operation couldn't be completed. (MPMusicPlayerControllerErrorDomain
    /// error 6.)" — which is what the Play button surfaced before.
    ///
    /// By far the most common real cause is simply not having an Apple Music
    /// subscription, so that is checked explicitly rather than lumped into a
    /// generic failure.
    private static func playbackFailureMessage(_ error: Error) async -> String {
        if let subscription = try? await MusicSubscription.current,
           !subscription.canPlayCatalogContent {
            return "Playing full tracks requires an Apple Music subscription. You can still open this release in Apple Music."
        }
        return "This release can't be played right now — it may not be available in your region, or Apple Music is temporarily unreachable."
    }

    func pause() {
        player.pause()
        state = .paused
    }

    func resume() async {
        do {
            try await player.play()
            state = .playing
        } catch {
            state = .error(await Self.playbackFailureMessage(error))
        }
    }

    func skipNext() async {
        try? await player.skipToNextEntry()
    }

    func skipPrevious() async {
        try? await player.skipToPreviousEntry()
    }

    func stop() {
        // Set the user-facing state FIRST and flag the observer to ignore the
        // transient updates that `player.stop()` will fire (the queue still
        // exists, so the observer will see brief .loading-like transitions
        // and pull our state back to non-idle if we don't suppress it).
        suppressObserver = true
        state = .idle
        currentTrackTitle = nil
        currentAlbumProviderID = nil
        currentArtistName = nil
        currentArtworkURL = nil
        cachedTrackDurations = [:]
        stopTitlePolling()
        player.stop()
        restoreSystemPlayerIfNeeded()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.suppressObserver = false
        }
    }

    /// Remember whether the Music app's player was playing so we can resume it
    /// in stop(). Sticky — once captured as `true` it stays until the restore
    /// fires, so switching tracks mid-session doesn't accidentally erase the
    /// intent (by the second call, SystemMusicPlayer is already paused by us).
    private func captureSystemPlayerState() {
        #if os(iOS) || targetEnvironment(macCatalyst)
        guard !systemPlayerWasPlaying else { return }
        let sys = SystemMusicPlayer.shared
        systemPlayerWasPlaying = sys.state.playbackStatus == .playing
        #endif
    }

    private func restoreSystemPlayerIfNeeded() {
        #if os(iOS) || targetEnvironment(macCatalyst)
        guard systemPlayerWasPlaying else { return }
        systemPlayerWasPlaying = false
        Task { @MainActor in
            // SystemMusicPlayer.shared keeps its existing queue across the
            // interruption; just calling .play() resumes from where it paused.
            try? await SystemMusicPlayer.shared.play()
        }
        #endif
    }

    private func syncPlaybackState() {
        guard !suppressObserver else { return }
        switch player.state.playbackStatus {
        case .playing:
            state = .playing
            currentTrackTitle = player.queue.currentEntry?.title
            startTitlePolling()
        case .paused:
            state = .paused
            // Keep polling while paused — the user may resume; queue may advance.
            startTitlePolling()
        case .stopped, .interrupted:
            // Album finished naturally OR system interrupted us — restore the
            // Music app's player here too, not only on the user pressing X.
            restoreSystemPlayerIfNeeded()
            state = .idle
            stopTitlePolling()
        default:
            break
        }
    }

    var isActive: Bool {
        // .loading is intentionally excluded — when stop() is called the player
        // can briefly transition through loading-like states; including it kept
        // the mini-player visible with a stuck "Loading…" label after dismiss.
        switch state {
        case .playing, .paused: return true
        default: return false
        }
    }

    var isPlaying: Bool {
        if case .playing = state { return true }
        return false
    }

    /// Current playback position in seconds. Polled by the mini-player's TimelineView.
    var currentPlaybackTime: TimeInterval { player.playbackTime }

    /// Move the play head to a specific time. Used by the mini-player's scrub
    /// gesture. No-ops when the new time is non-finite (NaN guard).
    func seek(to time: TimeInterval) {
        guard time.isFinite else { return }
        player.playbackTime = max(0, time)
    }

    /// Cache: track title → duration. Built when an album is queued for
    /// playback so the global mini-player has a duration to render the
    /// progress strip against even when MusicKit's queue entry item
    /// doesn't cast cleanly to a typed `Song` / `MusicVideo` (which it
    /// often doesn't — see the existing AlbumView fallback that read the
    /// duration from its locally-loaded tracks array).
    private var cachedTrackDurations: [String: TimeInterval] = [:]

    /// Duration of the currently playing item if it can be extracted from the queue.
    var currentTrackDuration: TimeInterval? {
        if let song = player.queue.currentEntry?.item as? Song { return song.duration }
        if let video = player.queue.currentEntry?.item as? MusicVideo { return video.duration }
        if let title = player.queue.currentEntry?.title,
           let cached = cachedTrackDurations[title] {
            return cached
        }
        return nil
    }
}
