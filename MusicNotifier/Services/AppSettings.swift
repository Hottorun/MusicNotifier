//
//  AppSettings.swift
//  MusicNotifier
//

enum AppSettings {
    static let autoRefreshOnLaunch = "autoRefreshOnLaunch"
    static let releaseNotificationHour = "releaseNotificationHour"
    static let releaseNotificationMinute = "releaseNotificationMinute"
    static let notificationsEnabled = "notificationsEnabled"
    static let upcomingReleaseNotificationsEnabled = "upcomingReleaseNotificationsEnabled"
    static let sameDayReleaseSummaryEnabled = "sameDayReleaseSummaryEnabled"
    static let globalNotificationReleasePreference = "globalNotificationReleasePreference"
    static let homeReleaseKindFilter = "homeReleaseKindFilter"
    static let lastRefreshAt = "lastRefreshAt"
    static let lastSuccessfulRefreshAt = "lastSuccessfulRefreshAt"
    static let lastBackgroundRefreshAt = "lastBackgroundRefreshAt"
    static let lastBackgroundRefreshResult = "lastBackgroundRefreshResult"
    static let lastStorefrontCountryCode = "lastStorefrontCountryCode"
    /// MUST match the `com.apple.security.application-groups` entry in both
    /// MusicNotifier.entitlements and MusicNotifierWidgets.entitlements. Mismatch
    /// silently sends writes/reads to nonexistent containers — widget shows no data.
    static let appGroupIdentifier = "group.com.kern.functional"
    static let lastFMAPIKey = "lastFMAPIKey"
    /// Comma-separated list of days-before-release to send a heads-up
    /// notification (e.g. "1,3,7"). Empty string = no pre-alerts.
    static let releasePreAlertDays = "releasePreAlertDays"
    /// Toggle: should new releases be mirrored to a managed Apple Music playlist
    /// in the user's library so CarPlay / HomePod / Watch / Music app can play it.
    static let syncToApplePlaylist = "syncToApplePlaylist"
    /// Catalog/library ID of the playlist created by this app. Empty until we've
    /// created it for the first time.
    static let appleMusicPlaylistID = "appleMusicPlaylistID"
    /// Default Last.fm API key shipped with the app. Used when the user hasn't
    /// supplied a custom key via Settings.
    static let defaultLastFMAPIKey = "94b0553fa357145776d10fbce4ece361"
    static let selectedMusicProvider = "selectedMusicProvider"
    /// Visual appearance override. Stored as "system" / "light" / "dark".
    /// Empty/missing = system.
    static let appearance = "appearance"
    static let spotifyClientID = "spotifyClientID"
    static let spotifyRedirectURI = "spotifyRedirectURI"
    static let defaultSpotifyClientID = "f0dd7984f000484a956ca7e7771af76a"
    static let defaultSpotifyRedirectURI = "musicnotifier://spotify-auth"
    static let spotifyAccessToken = "spotifyAccessToken"
    static let spotifyRefreshToken = "spotifyRefreshToken"
    static let spotifyTokenExpiresAt = "spotifyTokenExpiresAt"

    /// Global per-kind visibility. When `false`, releases of that kind are
    /// hidden from every list in the app (Feed, Upcoming, calendar, etc.).
    /// Stored as individual AppStorage bools so SwiftUI re-renders on toggle.
    static let showAlbums = "showAlbums"
    static let showSingles = "showSingles"
    static let showEPs = "showEPs"
    static let showLiveAlbums = "showLiveAlbums"
    static let showCompilations = "showCompilations"
    static let showRemixes = "showRemixes"

    /// User-customizable hex colors for each release-type badge. Stored as
    /// 6-digit hex without a leading `#`. Singles render no badge so there's
    /// no key for them.
    /// Master toggle: when off, no `ReleaseTypeBadge` is rendered anywhere.
    static let showReleaseTypeBadges = "showReleaseTypeBadges"

    /// Whether a deliberate horizontal swipe across the tab bar area switches
    /// tabs. Off-by-default-able from Settings since some users prefer not to
    /// have a gesture that can collide with horizontal scroll/search content.
    static let swipeBetweenTabs = "swipeBetweenTabs"
    /// Master toggle: when true, the Videos tab is shown in the tab bar /
    /// sidebar and video refresh runs alongside release refresh.
    static let enableVideosTab = "enableVideosTab"
    /// Send a notification when a tracked artist gets a new music video or
    /// interview. Only fires when `enableVideosTab` and `notificationsEnabled`
    /// are both true.
    static let videoNotificationsEnabled = "videoNotificationsEnabled"
    /// Which two months the Upcoming calendar shows. `"future"` = current +
    /// next (default — matches the tab's name). `"past"` = previous + current.
    static let upcomingCalendarDirection = "upcomingCalendarDirection"

    // MARK: - Concerts (Bandsintown)
    /// Master toggle: when true, the Concerts tab is shown and concert refresh
    /// runs alongside release refresh.
    static let enableConcertsTab = "enableConcertsTab"
    /// `true` → use CoreLocation for the Nearby filter. `false` → use the
    /// manual city override below.
    static let useLocationForNearby = "useLocationForNearby"
    /// Free-text city the user picked. Geocoded once to lat/long and cached
    /// in `cachedLatitude`/`cachedLongitude`.
    static let manualCityOverride = "manualCityOverride"
    /// Radius in kilometers for the Nearby filter and notification trigger.
    static let nearbyRadiusKm = "nearbyRadiusKm"
    /// Send a notification when a tracked artist announces a show within
    /// `nearbyRadiusKm` of the cached location.
    static let concertNotificationsEnabled = "concertNotificationsEnabled"

    // Cached location (CoreLocation last fix, or geocoded manual city).
    static let cachedLatitude = "cachedLatitude"
    static let cachedLongitude = "cachedLongitude"
    static let cachedLocationTimestamp = "cachedLocationTimestamp"

    static let albumBadgeColorHex = "albumBadgeColorHex"
    static let epBadgeColorHex = "epBadgeColorHex"
    static let liveBadgeColorHex = "liveBadgeColorHex"
    static let compilationBadgeColorHex = "compilationBadgeColorHex"
    static let remixBadgeColorHex = "remixBadgeColorHex"

    static let defaultAlbumBadgeColorHex = "4ade80"      // green
    static let defaultEPBadgeColorHex = "FBBF24"         // amber
    static let defaultLiveBadgeColorHex = "C084FC"       // purple
    static let defaultCompilationBadgeColorHex = "38BDF8" // cyan
    static let defaultRemixBadgeColorHex = "F472B6"      // pink
}
