# MusicNotifier Tasks

## Current Status

- [x] Apple Music onboarding
- [x] Apple Music library artist import
- [x] Import modes: all artists, skip names containing `&`, favorites-only placeholder
- [x] Onboarding artist selection
- [x] Track and untrack individual artists
- [x] Track all and untrack all artists
- [x] Persist imported artists with SwiftData
- [x] Persist discovered releases with SwiftData
- [x] Home release feed grouped by Upcoming, New, and Past
- [x] Album/release detail view with Apple Music link
- [x] Manual release refresh
- [x] Auto refresh on app start
- [x] Background app refresh request via `BGAppRefreshTask`
- [x] Local release-day notifications
- [x] Configurable notification time
- [x] Settings page with reset/refetch controls
- [x] Basic Concerts page scaffold
- [x] Hide Concerts tab until implementation is complete
- [x] Removed stale `FetchLibraryArtist.swift` resource warning from the app target.

## Blocking Setup

- [x] Enable MusicKit on the App ID in the Apple Developer portal.
- [x] Ensure Xcode signing team and Apple Developer portal team match.
- [x] Ensure the bundle identifier in Xcode matches the MusicKit-enabled App ID.
- [x] Add Background Modes capability in Xcode and enable Background fetch. (Info.plist `UIBackgroundModes` has `processing` + `fetch`; `BGTaskSchedulerPermittedIdentifiers` set.)
- [x] Test on a physical iPhone with Background App Refresh enabled.

## Release Accuracy

- [x] Replace broad `MusicCatalogSearchRequest(term: artistName)` matching with a more accurate artist-ID-based flow.
- [x] Store catalog artist IDs separately from library artist IDs where Apple Music exposes them.
- [x] Fetch albums from artist relationships/catalog endpoints instead of free-text search when possible.
- [x] Deduplicate deluxe, clean, explicit, remaster, live, and commentary variants.
- [x] Add release type filtering: albums, EPs, singles, compilations.
- [x] Add market/region handling for release availability.
- [x] Handle unknown release dates explicitly instead of grouping them as new releases.

## Artist Management

- [x] Add artist import by searching Apple Music manually.
- [x] Add search field to the Artists page.
- [x] Add Artists page filters: All, Tracked, Untracked.
- [x] Add Artists page sort options: A-Z, recently added.
- [x] Add bulk actions for visible/filter results, not just all imported artists.
- [x] Add Artists page sort option: recently updated.
- [x] Add warning when tracking a very large artist list because refresh may be slow.
- [x] Wire favorites-only import once MusicKit entitlement/catalog favorites access is working.

## Refresh And Background Behavior

- [x] Store `lastRefreshAt`.
- [x] Store `lastSuccessfulRefreshAt`.
- [x] Store `lastBackgroundRefreshAt`.
- [x] Store `lastBackgroundRefreshResult`.
- [x] Show refresh history in Settings.
- [x] Show last background refresh status in Settings.
- [x] Add a debug action to simulate/force a background refresh during development.
- [x] Add refresh cancellation if the foreground refresh is taking too long. (5-min watchdog plus user-driven stop button on the progress bar.)
- [x] Batch artist checks to avoid long refresh runs and rate-limit errors.
- [x] Add retry/backoff for temporary MusicKit failures.
- [x] Increase foreground refresh parallelism for large tracked-artist lists.
- [x] Move widget artwork caching off the refresh critical path.

## Notifications

- [x] Add notifications on/off setting.
- [x] Add upcoming release reminders on/off setting.
- [x] Add same-day release summary on/off setting.
- [x] Add notification type filters: albums only, singles only, albums and singles.
- [x] Store `notifiedAt` on releases.
- [x] Avoid duplicate notifications when a release is rediscovered.
- [x] Add test notification action in Settings.
- [x] Add pending notifications debug count.
- [x] Add pending notifications debug list.

## Release State And UX

- [x] Add `discoveredAt` field to releases.
- [x] Add `notifiedAt` field to releases.
- [x] Add `dismissedAt` or `isDismissed`.
- [x] Add `isSeen` behavior in the release detail.
- [x] Add release feed filters: All, Upcoming, New, Seen.
- [x] Add richer empty states for no artists, no releases, and MusicKit entitlement failures.
- [x] Add pull-to-refresh on Home.

## Onboarding

- [x] Add final onboarding summary with imported artist count and tracked artist count.
- [x] Ask for notification permission after the user tracks artists.
- [x] Add a skip option that enters the app with zero tracked artists.
- [x] Add clearer Spotify disabled state until OAuth is implemented.
- [x] Add retry path when MusicKit authorization is denied.

## Settings

- [x] Add reset onboarding only, without clearing data.
- [x] Add export/import debug data for local testing.
- [x] Add clear only untracked artists.
- [x] Add clear stale releases older than a chosen date.
- [x] Add app diagnostics section for MusicKit entitlement/token status.
- [x] Add App Group diagnostics in Settings.

## Concerts

- [x] Choose a concerts provider: **Bandsintown** (free, no auth, public REST). App ID `"MusicNotifier"` sent with every request.
- [x] Add concert data model (`ConcertData` — CloudKit-mirrored with venue, location, ticket URL, lineup, saved/dismissed/notified state).
- [x] Match tracked artists to event-provider artist IDs (Bandsintown matches by artist name in the URL path; no separate ID lookup needed).
- [x] Add location setting for nearby concerts (`LocationService` wrapping CoreLocation + manual city geocode fallback).
- [x] Add radius setting (25 / 50 / 100 / 250 km picker).
- [x] Add concert notification settings (one notification per newly discovered show within radius).
- [x] Add Concerts page filters: Upcoming, Nearby, Saved.
- [x] Add concert detail view with venue, city, date, ticket link, lineup, MapKit map of the venue.
- [x] Add concert refresh to foreground refresh pipeline (`ConcertRefreshService` called from `RefreshCoordinator` after release apply when `enableConcertsTab` is on; uses same tracked-artist list).

## Spotify

- [x] Create Spotify Developer app.
- [x] Add OAuth Authorization Code with PKCE.
- [x] Import followed/saved Spotify artists.
- [ ] Import saved Spotify artists via library APIs where available.
- [x] Search Spotify artists manually.
- [x] Fetch Spotify artist albums/releases.
- [x] Add Spotify deep links on release detail.

## Release Type Filtering

- [x] Store release type per `ReleaseData` (Album, Single, EP, Compilation, LiveAlbum, Remix).
- [x] Map MusicKit `Album` flags (`isSingle`, `isCompilation`, `trackCount`, title hints) onto the type enum during fetch.
- [x] Add release-type filter chips on the Home feed (All, Albums, EPs, Singles).
- [x] Add notification-type preference: notify for albums only / singles only / both.
- [x] Per-artist override of notification-type preference.

## Widgets

- [x] Add a Widget extension target.
- [x] "Next release" widget: countdown to the soonest upcoming release across tracked artists.
- [x] "Today's releases" widget: grid/list of release titles dropping today.
- [x] Add cached artwork thumbnails to widgets.
- [x] Provide WidgetKit timeline with explicit refresh on release-day boundaries.
- [x] Use App Group container so widget reads a release snapshot exported from SwiftData.
- [x] Tap widget → deep-link into the release detail.
- [x] Replace hard-coded "blue" accents with `AppTheme.accent` violet. (Widget palette now tracks the selected music provider via App Group: Apple Music red, Spotify green.)
- [x] Use a system-aware container background so light-mode home screens render correctly.
- [x] Add lock-screen accessory widgets: `accessoryCircular`, `accessoryRectangular`, `accessoryInline`.
- [x] Add an "Upcoming releases" widget showing the next 3-5 upcoming items.
- [x] Add StandBy support (iOS 17+). Existing widgets use `.containerBackground(.fill.tertiary, for: .widget)` and support `.systemSmall` + `.accessoryRectangular` — StandBy picks them up automatically.
- [x] Show in-progress refresh indicator on the widget when the app is actively refreshing.

## Artist Detail

- [x] Push an `ArtistDetailView` from each row on the Artists tab.
- [x] Header: avatar, name, tracked-since date, total releases tracked, last checked date.
- [x] Chronological release timeline grouped by year.
- [x] Per-artist tracking toggle and per-artist notification preferences.
- [x] Show pending notifications for this artist.
- [x] Open in Apple Music shortcut.

## iCloud Sync

- [x] Enable CloudKit-backed SwiftData via `ModelConfiguration(cloudKitDatabase: .private("iCloud.com.kern.functional.MusicNotifier"))`. Falls back to a local-only store if iCloud isn't reachable.
- [x] Add iCloud capability entitlement (CloudKit service + container identifier) to `MusicNotifier.entitlements`.
- [x] Make all `ArtistData` and `ReleaseData` properties optional or defaulted — CloudKit's mirroring layer requires this.
- [x] **Manual step:** Enable the iCloud/CloudKit container on the App ID in the Apple Developer portal (Identifiers → App ID → iCloud capability → configure container `iCloud.com.kern.functional.MusicNotifier`). Then re-fetch the provisioning profile in Xcode.
- [x] Handle first-launch sync state in onboarding ("we found your existing artists on iCloud"). `ICloudWelcomeView` shown when `hasCompletedOnboarding == false` but CloudKit has already mirrored artists in; offers a "Start fresh" escape hatch.
- [x] Surface sync/capability status in Settings — new "ICLOUD SYNC" section uses `CKContainer.default().accountStatus()` to show signed-in/restricted/no-account/unavailable states.
- [x] Add conflict handling for duplicated iCloud/local artists. `CloudSyncDeduplicator` runs on every app launch — groups `ArtistData` and `ReleaseData` by `(provider, providerID)`, picks the earliest survivor, OR-merges `isTracked`/`isSeen`/`notifiedAt`/`dismissedAt`, and deletes the rest.

## Concerts (Bandsintown)

- [x] Register a Bandsintown app ID — using `"MusicNotifier"` (public attribution string, not a secret).
- [x] Add a `ConcertData` SwiftData model.
- [x] Fetch upcoming + 30-day-past events for each tracked artist alongside release refresh, using artist name as the lookup key (`date=YYYY-MM-DD,2099-12-31` server-side range).
- [x] CoreLocation-based "near me" filter and manual city override (city is geocoded once on submit and cached as lat/long).
- [x] Concerts tab filters: Upcoming, Nearby, Saved.
- [x] Optional concert notifications: alert when a tracked artist announces a show within `nearbyRadiusKm`.

## Last.fm Integration

- [x] Register a Last.fm API key (free, no OAuth needed for read).
- [x] Add Last.fm API key setting in Settings.
- [x] On artist detail: show listeners count, playcount, similar artists, short bio.
- [x] On album detail: show listeners + tags.
- [x] Cache responses with TTL so we don't hammer the API.
- [x] Optional: Last.fm OAuth for users who want their own scrobbles surfaced.

## Empty States & Error Recovery

- [x] Detect MusicKit entitlement failure and surface contextual empty state.
- [x] "No artists tracked" state with import CTA.
- [x] "No releases yet" state with refresh CTA.
- [x] "MusicKit unavailable" state with retry + open-iOS-settings link.
- [x] Add inline retry for the refresh status pill.

## Notification Grouping & Polish

- [x] Group multiple same-day notifications by thread identifier (per-artist or per-day).
- [x] Use `interruptionLevel = .timeSensitive` for release-day alerts.
- [x] Attach album artwork as `UNNotificationAttachment` so banner shows the cover.
- [x] Add tap action that deep-links to the release detail.

## App Intents / Shortcuts

- [x] "What's new today?" intent → reads the same-day release summary.
- [x] "When does <artist> release next?" intent. (Implemented as a global "next release" intent — per-artist parameter still pending.)
- [x] "Mark all as seen" intent.
- [x] Provide Shortcuts donation so frequently used intents appear in Siri Suggestions.

## In-App Preview Playback

- [x] Use `ApplicationMusicPlayer` to play 30-second previews from the album detail without leaving the app.
- [x] Play/pause UI on the album detail and a global mini-player. (Album-detail bar done; global mini-player still pending.)
- [x] Queue the entire album as a preview reel.

## Discovery

- [x] "You might also follow" carousel using Last.fm similar-artists.
- [x] Source ranking from already-tracked artists' similarity overlap.
- [x] One-tap track-from-suggestion.
- [x] Discovery feed in Artists tab (collapsible section).
- [x] ~~Add Apple Music `with([.similarArtists])` as a second discovery source.~~ Not needed — Last.fm similar artists is sufficient.

## Redesign

- [x] Drop the "All" tab on Home; keep Releases (New + Seen) and Upcoming as two top-level segments.
- [x] Compress the "83 artists / 2 upcoming / 153 unread" stat block into one tight header line.
- [x] Move "Check for releases" out of the giant pill into a small icon-only refresh button in the top bar.
- [x] Use bigger hero artwork cards for New releases; keep Seen as compact rows.
- [x] Tighten Artist detail: collapse stat card + Tracking/Notify + Apple Music into one compact row below the hero.
- [x] Move Album detail "Preview album" below "Open in Apple Music" so Open is the primary action.
- [x] Album detail: show full tracklist (with discs when applicable) styled like Apple Music; highlight the most popular tracks (Last.fm playcount or Apple Music popularity).
- [x] Make Similar Artists rows on Artist detail tappable — open in-app if tracked, else open the catalog artist in Apple Music.
- [x] ~~Play around with surfacing Last.fm listener/playcount stats on the Artists list rows.~~ Replaced with relative "Checked …" time — 83+ Last.fm requests per visit was too expensive even with caching.
- [x] Remove the trailing chevron arrow from Artists list rows.
- [x] Drop "Apple Music" subtitle on Artist list rows unless mixed providers are present. (Replaced with "Checked …" relative time.)
- [x] Notifications: title `"X new releases"`, body `"Artist A, Artist B and N more"`.
- [x] Remove the Last.fm API key field from Settings (key is now shipped as a default).
- [x] Switch to true-black theme (#0E0E0E base / #161616 surface / #1F1F1F elevated).
- [x] Remove the "Step 2 of 2" label from onboarding.
- [x] On Spotify Premium-required error during import, bounce user back to provider selection with Apple Music preselected and an explanation.
- [x] Album detail: navigation title swaps to "Upcoming" when that filter is active on Home.
- [x] Album detail: tap a track to start preview playback from that track.
- [x] Album detail: stack "Open in Apple Music" + "Add to Library" + Preview as consistent action buttons.
- [x] Album detail: "Add to Library" moved to a `+` icon in the navigation toolbar (cycles `+` → `…` → `✓`).
- [x] Album detail: toolbar `+` is now a menu with **Add to Library** and **Add to Playlist…**. Playlist option opens a sheet listing the user's Apple Music playlists; tapping one adds the album via `MusicLibrary.shared.add(album, to: playlist)`.
- [x] Album detail: compact horizontal hero (smaller artwork + side-by-side title) so tracklist sits above the fold.
- [x] Album detail: replace the bulky in-line playback card with a sticky bottom mini-player (Spotify/Apple Music style) shown only while audio is active.
- [x] Album detail: small circular "play album" icon next to the Tracks header instead of a dedicated bar.
- [x] ~~Album detail: swipe-left on a track reveals an Add action that writes that song to the user's Apple Music library.~~ Reverted — gesture wasn't reliable; replaced with an inline `+` button on each track.
- [x] Album detail: inline `+` button on each track to add it to the Apple Music library; cycles `+` → spinner → ✓.
- [x] ~~Album detail: disable NavigationStack interactive back-swipe so the row swipe-to-add has the full row width.~~ Reverted along with the swipe-to-add removal.
- [x] Mini-player: thin progress bar at the bottom showing track position / duration, polled at 5Hz via TimelineView.
- [x] Preview playback restores prior Apple Music playback: capture `SystemMusicPlayer` status on start, resume it on stop if it was playing.
- [x] Strip "- Single" / "- EP" / "- Album" suffix from release titles app-wide via `ReleaseTitleFormatter.displayTitle`.
- [x] Promote "Upcoming" from a segmented control on Home to its own top-level tab (MusicHarbor-style).
- [x] Inline stats + type filter chip on one row under the title (Home and Upcoming both).
- [x] Upcoming tab carries the same album/EP/single type filter as Home (with its own persisted setting).
- [x] New unseen releases on Home rendered as a 2-column album grid (Apple Music style) instead of stacked hero cards.
- [x] Past releases bucketed by release month on Home instead of one long flat list.
- [x] Unread metric color changed from teal to yellow for more visual punch.
- [x] Upcoming items rendered as large hero cards (wide artwork + bold title + days-until badge), since there are usually few.
- [x] Discover carousel: real artwork via Apple Music catalog search, exclusion of already-tracked artists tightened (handles Last.fm vs catalog name mismatch).
- [x] Similar Artists on Artist detail: rebuilt as avatar cards with circular artwork instead of plain text capsules.
- [x] Tracking + Notify collapsed into one tile on Artist detail; "Notify Inherit" replaced with "Use default notification settings".
- [x] Mini-player progress bar reads duration from the already-loaded track list (MusicKit's Queue.Entry.item cast was returning nil).
- [x] Interactive-pop disabler walks the UIResponder chain to find the real UINavigationController (the prior UIViewControllerRepresentable approach didn't have access).
- [x] Mini-player X button: drop `.loading` from `isActive`, also wipe the queue in `stop()` so the observer can't repopulate state.
- [x] Replace the UIViewRepresentable pop-disabler with `.onAppear`/`.onDisappear` UIWindow walking — no intermediate view to interfere with the row swipe gesture.
- [x] Album detail: mini-player floats — rounded card with margins and shadow instead of edge-to-edge bar.
- [x] Fix `bell.dashed` (invalid SF Symbol) → use `bell.badge` for the inherit notification preference.
- [x] Cached image loader to remove artwork flicker on tab switches and list re-renders.
- [x] Remove the "Checked X/X artists. Found N…" success summary line on Home (failure messages with retry stay).
- [x] Album detail: tap artist name → push that artist's detail page (with a graceful fall-through to name match for compilation/feature credits).
- [x] ~~Add an error-report action in error states that sends an automated diagnostic message to the developer.~~ Not needed — console logs + AppGroup diagnostics cover the cases that actually matter; users rarely fill out reports.

## Competitive Research Picks (BEEPR / MusicHarbor / Crabhands)

- [x] **List ↔ Grid toggle on Home.** Three-state cycle: hybrid (new=grid + past=list, default) → list → grid → hybrid. Icon changes accordingly.
- [x] **Add to Apple Calendar.** Standalone toolbar icon on AlbumView for upcoming releases (no longer buried in `+` menu). Inline `AddToCalendarButton` also embedded in every Upcoming row + grid card.
- [x] **Upcoming layout: third "grid" option.** Cycle: list → grid → calendar → list.
- [x] **Artists grid view.** New list/grid toggle in the Artists filter row. Grid renders a 3-column LazyVGrid of circular artist tiles with a bell badge for tracked ones.
- [x] **Album detail: bigger play button + smaller Apple Music button.** Top action row is now a 56pt circular Play button (primary CTA) next to a compact "Open in Apple Music" capsule. Removed the small play button from the Tracks header.
- [x] **Playlist picker filters to user-editable playlists.** Both the album picker and the rules editor now skip Apple's editorial / personal-mix / replay playlists.
- [x] **Restored swipe between tabs.** Reverted to `.simultaneousGesture` so tab swipes work alongside taps; the deliberate-swipe thresholds prevent accidental triggers.
- [x] **Notification tap deep-links to the release detail.** `ForegroundNotificationDelegate` posts the URL via `NotificationCenter`; `ContentView` subscribes and routes through `DeepLinkRouter`, opening AlbumView in the sheet just like an external `musicnotifier://release/<id>` deep link.
- [x] **Popular-track indicator → leading dot.** Replaced the right-side chart-bar icon (confusing) with a small accent-colored circle to the left of the track title. Reserves a fixed 6pt slot so titles stay aligned across rows.
- [x] **Concerts (Bandsintown).** Shipped — see the Concerts and Concerts (Bandsintown) sections above. Tab toggle in Settings, refresh runs after release apply, MapKit-backed detail view.
- [x] **Follow record labels.** `ArtistData.kind` field discriminates "artist" vs "label". New `searchCatalogLabels` and `importLabel` paths. `AppleMusicReleaseService.fetchLabelReleases` resolves the `RecordLabel` and pulls `latestReleases`.
- [x] **Unified Add (artist or label) flow.** Single Add menu item opens one search sheet with one text field; debounced (300ms) as-you-type search hits artist + label catalogs in parallel and shows mixed results.
- [x] **Label-source badge on releases.** Releases discovered via a tracked label render a small "LABEL" capsule next to the artist name (list rows) or on the bottom-left of the artwork (hero grid).
- [x] **Widget data fix.** `AppSettings.appGroupIdentifier` was `"group.functional.MusicNotifier"` but both entitlements files use `"group.com.kern.functional"`. Mismatched IDs meant writes landed in a nonexistent container — widget read empty. Aligned to the entitlement value, then found the widget code hardcoded the old wrong ID in 4 places; fixed those too.
- [x] **App-Group container diagnostic.** Added a 3-line `[AppGroup]` print at the start of every refresh: container path, suite UserDefaults init result. Confirmed container resolves correctly.
- [x] **Refresh progress bar animation smoothed.** Linear 0.45s easing (matches the 150ms throttle cadence) + indeterminate white sheen sliding across the fill every 1.6s via TimelineView. Continuous-activity feel between real fraction updates.
- [x] **Removed All/Tracked/Untracked chips.** Folded into the sort menu as a "Show" picker section above the existing sort options. Sort/filter icon flips to a filled accent variant when a non-default filter is active.
- [x] **Track add button hidden for already-in-library songs.** `loadLibraryMembership()` queries `MusicLibraryRequest<Song>` once on album-detail open, builds an artist→titles index, pre-populates `addedSongIDs` for any tracks already in the user's Apple Music library. The `+` slot becomes a transparent placeholder so durations stay aligned.
- [x] **Widget reads App Group ID from a single shared constant.** New `WidgetConstants.appGroupIdentifier` in the widget file (mirrors `AppSettings.appGroupIdentifier`). All 4 widget read sites use the constant so they can never drift independently again.
- [x] **Widget diagnostics.** `Logger` (subsystem `MusicNotifierWidget`) + `NSLog` lines tagged `MN-WIDGET` at timeline load — confirms container URL, snapshot file URL, file existence, and decoded count. App launch now calls `WidgetCenter.shared.reloadAllTimelines()` so the logs fire reliably on every cold start.
- [x] **Widget snapshot sort fix.** Was sorting by `releaseDate` ascending then `.prefix(40)` — gave the oldest 40 releases (years-old past). Widget views filter to "today" / "upcoming" → always empty. Fixed to sort by absolute distance from today, so soonest-upcoming + most-recent-past come first.
- [x] **Mini-player track auto-advance now updates UI.** Added a 0.5s `Timer` polling `player.queue.currentEntry?.title` in `AlbumPreviewPlayer`. The state observer only fires on play/pause/stop changes, not on queue advances within an active session, so mini-player title + Tracks list "now playing" indicator was stuck on the originally-tapped track.
- [x] **Mini-player scrubbing is relative.** Captures the live fraction at drag start; finger movement = same bar movement (not absolute touch position). Touching anywhere on the bar starts from where the play head currently is.
- [x] **Tap album cover → fullscreen viewer.** New `FullscreenArtworkView` (full-color modal, status bar hidden). Pinch-to-zoom (1×–4× clamp), drag-down-to-dismiss while at 1×, close button + artist/title metadata at the top.
- [x] **Custom playlist routing.** New `PlaylistRule` model (UserDefaults JSON, no SwiftData migration needed). Each rule pipes filtered releases (by genre and/or kind) into a specific Apple Music playlist. `AppleMusicPlaylistSync` now takes `PlaylistSyncCandidate`s carrying genre + kind metadata, evaluates rules in addition to the default playlist. New `PlaylistRulesView` (Settings → Apple Music Playlist → Playlist rules) for managing rules.
- [x] **Each playlist rule creates its own playlist.** Refactored so the rule's name doubles as the playlist title; sync auto-creates the playlist on first match and caches the resulting ID. No more picking an existing playlist.
- [x] **Popular track indicator → leftmost.** Dot now sits in front of the track number (rather than between number and title) so popular tracks scan as a clean column.
- [x] **Artists grid bug fix.** Replaced `NavigationLink { ... } label: { tile }` with the same overlay-NavigationLink pattern used by list rows — fixes both the broken tap targeting (clicking one opened the wrong artist) and removes the auto-added chevron.
- [x] **Music videos + interviews.** New `VideoData` SwiftData model + `VideosView` tab (toggle in Settings → Videos & Interviews). `AppleMusicVideoService` does two passes per refresh: (1) `Artist.with([.musicVideos])` per tracked artist for their own catalog videos, (2) catalog searches against "Zane Lowe interview", "Apple Music Sessions", "Apple Music Up Next", "Apple Music 1" filtered locally to videos whose title/artist name mentions a tracked artist — catches interviews where the artist is the guest. Title heuristic classifies as `musicVideo` vs `interview`. Optional notifications via `videoNotificationsEnabled`. Apple Music has no public per-artist "shows" endpoint so radio-show episodes are out of scope.
- [x] **2-month rolling calendar.** Upcoming's calendar layout renders two months with past-day tiles greyed out (`isPast` desaturates artwork). Direction picker in Settings → Upcoming Calendar: "This + next month" (default) or "Last + this month".

## MusicHarbor-Inspired Features

- [x] Auto-generate an Apple Music playlist ("Music Notifier") that automatically appends each newly discovered release for tracked artists. Lets CarPlay / HomePod / Watch / Music app all surface new music without ever opening this app. Implemented via `AppleMusicPlaylistSync`, hooked from `ReleaseRefreshService.apply`.
- [x] Settings toggle "Sync new releases to a playlist" with a "Recreate on next refresh" action.
- [x] Calendar grid view as an alternative layout on the Upcoming tab — month at a glance, artwork tiles in each day cell. Toggle button next to the type filter switches between list and calendar; selected day expands a release list below the grid.
- [x] Custom release date pre-alerts: multi-select for "1 day / 3 days / 1 week before". Schedules extra `UNNotificationRequest`s alongside the same-day one; configured in Settings.
- [x] "Mark all as read" button in the Releases feed toolbar (in the ellipsis menu); confirmation prompt if there are more than 50 unread.
- [x] Search inside the Releases feed — searchable across release titles + artist names (`.searchable` in the nav bar).
- [x] Genre tagging on artists — `genres: [String]?` added to `ArtistData`, populated from Apple Music's `Artist.genreNames` during the artwork-backfill pass, surfaced as a filter chip menu on the Artists tab.
- [x] Genre-based bulk action: when a genre is selected on the Artists tab, a contextual bar shows "Track N artists" + an untrack-all icon. Reuses the already-imported library; one tap flips `isTracked` on every artist in that genre.
- [ ] App icon picker in Settings with 2–4 alternates. Use `UIApplication.shared.setAlternateIconName(_:)`. _(Deferred — needs alternate icon assets + Info.plist CFBundleAlternateIcons configured in Xcode first.)_
- [x] Alphabetical A–Z jump scrubber on the right edge of the Artists list. Only renders when sorted A-Z and visible-artist count is over 50. Uses `ScrollViewReader` + `.id(providerID)` per row to jump.
- [x] iPadOS layout — `NavigationSplitView` sidebar with Home / Upcoming / Artists rows, detail pane on the right. Auto-selected when `horizontalSizeClass == .regular`; compact size class still gets the bottom tab bar.
- [x] macOS (Mac Catalyst) — Supported Destinations now includes Mac. `splitLayout` renders via the regular size class; existing `#if os(iOS) || targetEnvironment(macCatalyst)` guards keep MusicKit calls compatible.

## Testing

- [x] Add focused unit tests for release grouping.
- [x] Add tests for artist import filtering.
- [x] Add tests for notification scheduling dates.
- [x] Add tests for release deduplication.
- [ ] Add UI smoke tests for onboarding, Artists, Home, Settings, and Concerts.
- [x] Add unit tests for widget deep links and widget snapshot encoding.
- [x] Test on a real iPhone with MusicKit entitlement enabled.
- [ ] Test Background App Refresh behavior over multiple days.
