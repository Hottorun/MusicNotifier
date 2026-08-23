//
//  SettingsView.swift
//  MusicNotifier
//

import Foundation
import SwiftUI
import SwiftData
import UserNotifications
import CloudKit

private enum PreAlertOption: Int, CaseIterable, Identifiable {
    case oneDay = 1
    case threeDays = 3
    case sevenDays = 7

    var id: Int { rawValue }
    var days: Int { rawValue }
    var label: String {
        switch self {
        case .oneDay: "1 day before"
        case .threeDays: "3 days before"
        case .sevenDays: "1 week before"
        }
    }
    static func summaryLabel(for days: Int) -> String {
        switch days {
        case 1: "1d"
        case 3: "3d"
        case 7: "1w"
        default: "\(days)d"
        }
    }
}

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppSettings.autoRefreshOnLaunch) private var autoRefreshOnLaunch = true
    @AppStorage(AppSettings.releaseNotificationHour) private var releaseNotificationHour = 8
    @AppStorage(AppSettings.releaseNotificationMinute) private var releaseNotificationMinute = 0
    @AppStorage(AppSettings.notificationsEnabled) private var notificationsEnabled = true
    @AppStorage(AppSettings.upcomingReleaseNotificationsEnabled) private var upcomingReleaseNotificationsEnabled = true
    @AppStorage(AppSettings.sameDayReleaseSummaryEnabled) private var sameDayReleaseSummaryEnabled = true
    @AppStorage(AppSettings.globalNotificationReleasePreference) private var globalNotificationReleasePreference = ArtistNotificationPreference.all.rawValue
    @AppStorage(AppSettings.lastFMAPIKey) private var lastFMAPIKey = AppSettings.defaultLastFMAPIKey
    @AppStorage(AppSettings.releasePreAlertDays) private var releasePreAlertDays: String = ""
    @AppStorage(AppSettings.syncToApplePlaylist) private var syncToApplePlaylist: Bool = false
    @AppStorage(AppSettings.appleMusicPlaylistID) private var appleMusicPlaylistID: String = ""
    @AppStorage(AppSettings.showAlbums) private var showAlbums: Bool = true
    @AppStorage(AppSettings.showSingles) private var showSingles: Bool = true
    @AppStorage(AppSettings.showEPs) private var showEPs: Bool = true
    @AppStorage(AppSettings.showLiveAlbums) private var showLiveAlbums: Bool = true
    @AppStorage(AppSettings.showCompilations) private var showCompilations: Bool = true
    @AppStorage(AppSettings.showRemixes) private var showRemixes: Bool = true
    @AppStorage(AppSettings.albumBadgeColorHex) private var albumBadgeColorHex: String = AppSettings.defaultAlbumBadgeColorHex
    @AppStorage(AppSettings.epBadgeColorHex) private var epBadgeColorHex: String = AppSettings.defaultEPBadgeColorHex
    @AppStorage(AppSettings.liveBadgeColorHex) private var liveBadgeColorHex: String = AppSettings.defaultLiveBadgeColorHex
    @AppStorage(AppSettings.compilationBadgeColorHex) private var compilationBadgeColorHex: String = AppSettings.defaultCompilationBadgeColorHex
    @AppStorage(AppSettings.remixBadgeColorHex) private var remixBadgeColorHex: String = AppSettings.defaultRemixBadgeColorHex
    @AppStorage(AppSettings.showReleaseTypeBadges) private var showReleaseTypeBadges: Bool = true
    @AppStorage(AppSettings.swipeBetweenTabs) private var swipeBetweenTabs: Bool = true
    @AppStorage(AppSettings.enableVideosTab) private var enableVideosTab: Bool = false
    @AppStorage(AppSettings.videoNotificationsEnabled) private var videoNotificationsEnabled: Bool = false
    @AppStorage(AppSettings.includeInterviewVideos) private var includeInterviewVideos: Bool = false
    @AppStorage(AppSettings.upcomingCalendarDirection) private var calendarDirectionRaw: String = CalendarDirection.future.rawValue
    @AppStorage(AppSettings.enableConcertsTab) private var enableConcertsTab: Bool = false
    @AppStorage(AppSettings.concertNotificationsEnabled) private var concertNotificationsEnabled: Bool = false
    @AppStorage(AppSettings.appearance) private var appearanceRaw: String = "system"
    @Query(sort: \ArtistData.name) private var artists: [ArtistData]
    @Query(sort: \ReleaseData.firstSeenAt, order: .reverse) private var releases: [ReleaseData]
    @State private var statusMessage: String?
    @State private var showingDangerZone = false
    @State private var pendingDangerAction: PendingDangerAction?

    /// Counted once per body pass instead of walking the whole roster twice
    /// inside the danger-zone row (once for `isDisabled`, once for the
    /// confirmation copy).
    private var untrackedArtistCount: Int {
        artists.reduce(into: 0) { $0 += $1.isTracked ? 0 : 1 }
    }

    private var trackedArtists: [ArtistData] {
        artists.filter(\.isTracked)
    }

    var body: some View {
        ScrollView {
            // LazyVStack so sections below the fold (Calendar / Videos /
            // Gestures / Danger) don't get instantiated until scrolled into
            // view. First-open paints noticeably faster.
            LazyVStack(spacing: 24) {
                statsCard

                iCloudStatusSection

                applePlaylistSection

                VStack(alignment: .leading, spacing: 8) {
                    Text("NOTIFICATIONS")
                        .font(.caption.weight(.semibold))
                        .tracking(1.2)
                        .foregroundStyle(AppTheme.secondary)
                        .padding(.horizontal, 24)

                    VStack(spacing: 0) {
                        settingsToggle("Notifications", isOn: Binding(
                            get: { notificationsEnabled },
                            set: { newValue in
                                withAnimation(.easeInOut(duration: 0.25)) {
                                    notificationsEnabled = newValue
                                }
                            }
                        ))

                        if notificationsEnabled {
                            settingsDivider
                            settingsToggle("Upcoming release alerts", isOn: $upcomingReleaseNotificationsEnabled)
                            settingsToggle("Same-day summary", isOn: $sameDayReleaseSummaryEnabled)
                            settingsDivider
                            timePicker
                            settingsDivider
                            preAlertPicker
                            settingsDivider
                            notificationTypePicker
                        }
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(AppTheme.surface)
                    )
                    .padding(.horizontal, 20)

                }

                appearanceSection

                section(title: "Refresh") {
                    settingsToggle("Refresh on app launch", isOn: $autoRefreshOnLaunch)
                }

                releaseTypesSection

                calendarSection

                videosSection

                gesturesSection

                section(title: "Danger zone", tint: .red) {
                    Button {
                        withAnimation { showingDangerZone.toggle() }
                    } label: {
                        HStack {
                            Label(showingDangerZone ? "Hide" : "Show", systemImage: showingDangerZone ? "eye.slash" : "eye")
                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                    }
                    .foregroundStyle(AppTheme.secondary)

                    if showingDangerZone {
                        settingsDivider
                        dangerButton(
                            "Reset onboarding only",
                            systemImage: "arrow.uturn.backward",
                            confirmation: (
                                "You'll be taken back through setup. Your artists and releases are kept.",
                                "Reset Onboarding"
                            ),
                            action: resetOnboardingOnly
                        )
                        dangerButton(
                            "Clear releases",
                            systemImage: "trash",
                            isDisabled: releases.isEmpty,
                            confirmation: (
                                "Deletes all \(releases.count) stored releases on this device and every device signed in to your iCloud account. Your tracked artists are kept, and the next refresh will repopulate recent releases.",
                                "Clear Releases"
                            ),
                            action: clearReleases
                        )
                        dangerButton(
                            "Clear untracked artists",
                            systemImage: "person.crop.circle.badge.minus",
                            isDisabled: untrackedArtistCount == 0,
                            confirmation: (
                                "Deletes \(untrackedArtistCount) artists you aren't tracking. This syncs to your other devices and can't be undone.",
                                "Clear Untracked"
                            ),
                            action: clearUntrackedArtists
                        )
                        dangerButton(
                            "Clear old releases (180d+)",
                            systemImage: "calendar.badge.minus",
                            isDisabled: releases.isEmpty,
                            confirmation: (
                                "Deletes releases older than 180 days. This syncs to your other devices and can't be undone.",
                                "Clear Old Releases"
                            ),
                            action: clearStaleReleases
                        )
                        dangerButton(
                            "Clear all artists & releases",
                            systemImage: "person.crop.circle.badge.xmark",
                            isDisabled: artists.isEmpty,
                            confirmation: (
                                "Deletes your entire watchlist — all \(artists.count) artists and \(releases.count) releases — on this device and every device signed in to your iCloud account. This can't be undone.",
                                "Delete Everything"
                            ),
                            action: clearArtistsAndReleases
                        )
                    }
                }

                if let statusMessage {
                    Text(statusMessage)
                        .font(.footnote)
                        .foregroundStyle(AppTheme.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                }

                Spacer(minLength: 24)
            }
            .padding(.top, 8)
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .appScreenBackground()
        // Re-apply at the SettingsView level so the picker's effect is
        // visible immediately, even if the enclosing sheet hadn't picked up
        // the parent's preferredColorScheme yet.
        .preferredColorScheme(resolvedColorScheme)
        .confirmationDialog(
            pendingDangerAction?.title ?? "",
            isPresented: Binding(
                get: { pendingDangerAction != nil },
                set: { if !$0 { pendingDangerAction = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDangerAction
        ) { pending in
            Button(pending.confirmLabel, role: .destructive) {
                pending.perform()
                pendingDangerAction = nil
            }
            Button("Cancel", role: .cancel) { pendingDangerAction = nil }
        } message: { pending in
            Text(pending.message)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") {
                    dismiss()
                }
                .foregroundStyle(AppTheme.accent)
            }
        }
    }

    private var resolvedColorScheme: ColorScheme? {
        switch appearanceRaw {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    // MARK: - Building blocks

    private var statsCard: some View {
        HStack(spacing: 0) {
            statTile(value: "\(artists.count)", label: "imported")
            tileDivider
            statTile(value: "\(trackedArtists.count)", label: "tracked")
            tileDivider
            statTile(value: "\(releases.count)", label: "releases")
        }
        .padding(.vertical, 18)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(AppTheme.surface)
        )
        .padding(.horizontal, 20)
    }

    private func statTile(value: String, label: String, accent: Bool = false) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(accent ? AppTheme.accent : AppTheme.primaryText)
            Text(label)
                .font(.caption)
                .foregroundStyle(AppTheme.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var tileDivider: some View {
        Rectangle()
            .fill(AppTheme.hairline)
            .frame(width: 1, height: 36)
    }

    private func section<Content: View>(title: String, tint: Color = AppTheme.secondary, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .tracking(1.2)
                .foregroundStyle(tint == AppTheme.secondary ? AppTheme.secondary : tint)
                .padding(.horizontal, 24)

            VStack(spacing: 0) {
                content()
            }
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(AppTheme.surface)
            )
            .padding(.horizontal, 20)
        }
    }

    private var settingsDivider: some View {
        Rectangle()
            .fill(AppTheme.hairline)
            .frame(height: 1)
            .padding(.leading, 14)
    }

    private func settingsToggle(_ title: String, isOn: Binding<Bool>, isDisabled: Bool = false) -> some View {
        Toggle(isOn: isOn) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(isDisabled ? AppTheme.secondary : AppTheme.primaryText)
        }
        .tint(AppTheme.accent)
        .disabled(isDisabled)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    /// Unified per-kind row: visibility toggle + label + (for kinds that show a
    /// badge) color swatch + reset. Replaces the old split "View" + "Badge
    /// colors" sections — both controls for a kind now live in one place.
    private var releaseTypesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("RELEASE TYPES")
                    .font(.caption.weight(.semibold))
                    .tracking(1.2)
                    .foregroundStyle(AppTheme.secondary)
                Spacer()
                Button {
                    resetAllReleaseTypeCustomizations()
                } label: {
                    Text("Reset")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.accent)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)

            VStack(spacing: 0) {
                settingsToggle("Show release type badges", isOn: $showReleaseTypeBadges)
                settingsDivider

                releaseTypeRow(kind: .album, visible: $showAlbums, hex: $albumBadgeColorHex, defaultHex: AppSettings.defaultAlbumBadgeColorHex)
                settingsDivider
                releaseTypeRow(kind: .single, visible: $showSingles, hex: nil, defaultHex: nil)
                settingsDivider
                releaseTypeRow(kind: .ep, visible: $showEPs, hex: $epBadgeColorHex, defaultHex: AppSettings.defaultEPBadgeColorHex)
                settingsDivider
                releaseTypeRow(kind: .liveAlbum, visible: $showLiveAlbums, hex: $liveBadgeColorHex, defaultHex: AppSettings.defaultLiveBadgeColorHex)
                settingsDivider
                releaseTypeRow(kind: .compilation, visible: $showCompilations, hex: $compilationBadgeColorHex, defaultHex: AppSettings.defaultCompilationBadgeColorHex)
                settingsDivider
                releaseTypeRow(kind: .remix, visible: $showRemixes, hex: $remixBadgeColorHex, defaultHex: AppSettings.defaultRemixBadgeColorHex)
            }
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous).fill(AppTheme.surface)
            )
            .padding(.horizontal, 20)

            Text("Hide a type to remove it from every list. Tap the swatch to recolor its badge.")
                .font(.caption)
                .foregroundStyle(AppTheme.secondary)
                .padding(.horizontal, 24)
        }
    }

    private func releaseTypeRow(
        kind: ReleaseKind,
        visible: Binding<Bool>,
        hex: Binding<String>?,
        defaultHex: String?
    ) -> some View {
        let swatchColor: Color = {
            guard let hex else { return AppTheme.elevatedSurface }
            return Color(hex: hex.wrappedValue)
        }()
        let dimmed = !visible.wrappedValue

        return HStack(spacing: 12) {
            // Color swatch doubles as the picker affordance; tappable only when
            // this kind actually renders a badge.
            ZStack {
                Circle()
                    .fill(swatchColor.opacity(showReleaseTypeBadges ? 0.22 : 0.08))
                    .frame(width: 28, height: 28)
                // Shape-codes the kind on top of the swatch so colorblind
                // users still see *which* kind they're configuring. Falls
                // back to a filled dot for the unknown/single case.
                Image(systemName: kindGlyph(kind))
                    .font(.system(size: 12, weight: .heavy))
                    .foregroundStyle(swatchColor)
                if hex != nil && showReleaseTypeBadges {
                    ColorPicker("", selection: Binding<Color>(
                        get: { Color(hex: hex!.wrappedValue) },
                        set: { hex!.wrappedValue = $0.hexString }
                    ), supportsOpacity: false)
                    .labelsHidden()
                    .opacity(0.02)
                    .frame(width: 28, height: 28)
                }
            }
            .opacity(dimmed ? 0.4 : 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(kindDisplayName(kind))
                    .font(.subheadline.weight(.semibold))
                    // `.white` here left every release-type row unlabeled in
                    // light mode — the section read as six anonymous toggles.
                    .foregroundStyle(dimmed ? AppTheme.secondary : AppTheme.primaryText)
                if hex == nil {
                    Text("No badge — singles render unlabeled")
                        .font(.caption2)
                        .foregroundStyle(AppTheme.secondary)
                } else if !showReleaseTypeBadges {
                    Text("Badges hidden globally")
                        .font(.caption2)
                        .foregroundStyle(AppTheme.secondary)
                }
            }

            Spacer()

            if let hex, let defaultHex, hex.wrappedValue.lowercased() != defaultHex.lowercased() {
                Button {
                    hex.wrappedValue = defaultHex
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.secondary)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(AppTheme.elevatedSurface))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Reset \(kind.rawValue) color")
            }

            Toggle("", isOn: visible)
                .labelsHidden()
                .tint(AppTheme.accent)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var calendarSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("UPCOMING CALENDAR")
                .font(.caption.weight(.semibold))
                .tracking(1.2)
                .foregroundStyle(AppTheme.secondary)
                .padding(.horizontal, 24)

            VStack(spacing: 8) {
                Picker("Direction", selection: $calendarDirectionRaw) {
                    ForEach(CalendarDirection.allCases) { direction in
                        Text(direction.label).tag(direction.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous).fill(AppTheme.surface)
            )
            .padding(.horizontal, 20)

            Text(currentCalendarDirectionDescription)
                .font(.caption)
                .foregroundStyle(AppTheme.secondary)
                .padding(.horizontal, 24)
        }
    }

    private var currentCalendarDirectionDescription: String {
        let direction = CalendarDirection(rawValue: calendarDirectionRaw) ?? .future
        return direction.description + ". Past-day tiles render greyed out."
    }

    private var videosSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("VIDEOS & INTERVIEWS")
                .font(.caption.weight(.semibold))
                .tracking(1.2)
                .foregroundStyle(AppTheme.secondary)
                .padding(.horizontal, 24)

            VStack(spacing: 0) {
                settingsToggle("Show Videos tab", isOn: $enableVideosTab)
                if enableVideosTab {
                    settingsDivider
                    settingsToggle("Notify for new videos", isOn: $videoNotificationsEnabled)
                    settingsDivider
                    settingsToggle("Include interviews & sessions", isOn: $includeInterviewVideos)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous).fill(AppTheme.surface)
            )
            .padding(.horizontal, 20)

            Text("Pulls music videos from Apple Music for tracked artists. Interviews (Zane Lowe / Apple Music Sessions) are slower to fetch — leave that toggle off to keep refresh quick.")
                .font(.caption)
                .foregroundStyle(AppTheme.secondary)
                .padding(.horizontal, 24)
        }
    }

    private var gesturesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("GESTURES")
                .font(.caption.weight(.semibold))
                .tracking(1.2)
                .foregroundStyle(AppTheme.secondary)
                .padding(.horizontal, 24)

            VStack(spacing: 0) {
                settingsToggle("Swipe between tabs", isOn: $swipeBetweenTabs)
            }
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous).fill(AppTheme.surface)
            )
            .padding(.horizontal, 20)

            Text("Horizontal flicks at the bottom of the screen switch tabs. Disabled automatically when you're inside an album or artist.")
                .font(.caption)
                .foregroundStyle(AppTheme.secondary)
                .padding(.horizontal, 24)
        }
    }

    private func kindGlyph(_ kind: ReleaseKind) -> String {
        switch kind {
        case .album: return "opticaldisc"
        case .single: return "music.note"
        case .ep: return "square.stack"
        case .liveAlbum: return "mic"
        case .compilation: return "rectangle.stack"
        case .remix: return "waveform"
        }
    }

    private func kindDisplayName(_ kind: ReleaseKind) -> String {
        switch kind {
        case .album: "Albums"
        case .single: "Singles"
        case .ep: "EPs"
        case .liveAlbum: "Live albums"
        case .compilation: "Compilations"
        case .remix: "Remixes"
        }
    }

    private func resetAllReleaseTypeCustomizations() {
        showAlbums = true
        showSingles = true
        showEPs = true
        showLiveAlbums = true
        showCompilations = true
        showRemixes = true
        showReleaseTypeBadges = true
        albumBadgeColorHex = AppSettings.defaultAlbumBadgeColorHex
        epBadgeColorHex = AppSettings.defaultEPBadgeColorHex
        liveBadgeColorHex = AppSettings.defaultLiveBadgeColorHex
        compilationBadgeColorHex = AppSettings.defaultCompilationBadgeColorHex
        remixBadgeColorHex = AppSettings.defaultRemixBadgeColorHex
    }

    /// A destructive action awaiting confirmation. These operations delete
    /// SwiftData rows that CloudKit mirrors, so a mis-tap doesn't just wipe
    /// this device — it propagates the deletion to every signed-in device,
    /// with no undo. Previously each button fired the moment it was touched.
    struct PendingDangerAction: Identifiable {
        let id = UUID()
        let title: String
        let message: String
        let confirmLabel: String
        let perform: () -> Void
    }

    private func dangerButton(
        _ title: String,
        systemImage: String,
        isDisabled: Bool = false,
        confirmation: (message: String, confirmLabel: String),
        action: @escaping () -> Void
    ) -> some View {
        dangerButton(title, systemImage: systemImage, isDisabled: isDisabled) {
            pendingDangerAction = PendingDangerAction(
                title: title,
                message: confirmation.message,
                confirmLabel: confirmation.confirmLabel,
                perform: action
            )
        }
    }

    private func dangerButton(_ title: String, systemImage: String, isDisabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Label(title, systemImage: systemImage)
                    .font(.subheadline)
                Spacer(minLength: 8)
            }
            .foregroundStyle(isDisabled ? AppTheme.secondary : .red)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
    }

    private var alertTimeBinding: Binding<Date> {
        Binding(
            get: {
                var components = DateComponents()
                components.hour = releaseNotificationHour
                components.minute = releaseNotificationMinute
                return Calendar.current.date(from: components) ?? Date()
            },
            set: { newDate in
                let components = Calendar.current.dateComponents([.hour, .minute], from: newDate)
                releaseNotificationHour = components.hour ?? 8
                releaseNotificationMinute = components.minute ?? 0
            }
        )
    }

    private var timePicker: some View {
        DatePicker(
            "Alert time",
            selection: alertTimeBinding,
            displayedComponents: .hourAndMinute
        )
        .tint(AppTheme.accent)
        .foregroundStyle(AppTheme.primaryText)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    /// Shows whether the iCloud account is signed in and reachable. SwiftData
    /// handles the actual sync; this section just surfaces the account state so
    /// the user knows when their watchlist is mirrored across devices.
    private var iCloudStatusSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ICLOUD SYNC")
                .font(.caption.weight(.semibold))
                .tracking(1.2)
                .foregroundStyle(AppTheme.secondary)
                .padding(.horizontal, 24)

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: iCloudIcon)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(iCloudOK ? AppTheme.accent : AppTheme.secondary)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(iCloudHeadline)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AppTheme.primaryText)
                        Text(iCloudSubtitle)
                            .font(.caption2)
                            .foregroundStyle(AppTheme.secondary)
                            .lineLimit(2)
                    }
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(AppTheme.surface))
            .padding(.horizontal, 20)
        }
        .task { await refreshICloudStatus() }
        .onAppear {
            if enableConcertsTab { enableConcertsTab = false }
            if concertNotificationsEnabled { concertNotificationsEnabled = false }
        }
    }

    @State private var iCloudAccountStatus: CKAccountStatus = .couldNotDetermine
    @ObservedObject private var cloudSyncMonitor = CloudSyncMonitor.shared

    /// The store fell back to local-only — the CloudKit container itself
    /// couldn't be opened. Narrow but unambiguous.
    private var isLocalOnlyDespiteAccount: Bool {
        AppSchema.storeIsCloudKitBacked == false
    }

    /// The real mirroring verdict. `CKAccountStatus` being `.available` only
    /// means an iCloud account exists — it does not mean this app's container
    /// is reachable or that its schema has been deployed, which is precisely
    /// the failure that leaves a shipped app silently not syncing.
    private var cloudSyncError: String? {
        cloudSyncMonitor.lastErrorDescription
    }

    private var iCloudOK: Bool {
        iCloudAccountStatus == .available && !isLocalOnlyDespiteAccount
    }

    private var iCloudIcon: String {
        if isLocalOnlyDespiteAccount || cloudSyncError != nil { return "exclamationmark.icloud" }
        return switch iCloudAccountStatus {
        case .available: "checkmark.icloud.fill"
        case .noAccount, .restricted, .temporarilyUnavailable: "xmark.icloud"
        case .couldNotDetermine: "icloud"
        @unknown default: "icloud"
        }
    }

    private var iCloudHeadline: String {
        if isLocalOnlyDespiteAccount { return "Not syncing — local only" }
        if cloudSyncError != nil { return "iCloud sync failing" }
        return switch iCloudAccountStatus {
        case .available: "Syncing"
        case .noAccount: "Not signed in to iCloud"
        case .restricted: "Restricted"
        case .temporarilyUnavailable: "Temporarily unavailable"
        case .couldNotDetermine: "Checking…"
        @unknown default: "Unknown"
        }
    }

    private var iCloudSubtitle: String {
        if isLocalOnlyDespiteAccount {
            return "The iCloud container couldn't be opened, so your watchlist is stored only on this device."
        }
        if let cloudSyncError {
            return cloudSyncError
        }
        return switch iCloudAccountStatus {
        case .available: "Your tracked artists and releases mirror across iPhone, iPad, and Mac."
        case .noAccount: "Sign in to iCloud in Settings to sync your watchlist across devices."
        case .restricted: "iCloud is restricted on this device (parental controls or MDM)."
        case .temporarilyUnavailable: "Couldn't reach iCloud right now — will retry automatically."
        case .couldNotDetermine: "—"
        @unknown default: "—"
        }
    }

    @MainActor
    private func refreshICloudStatus() async {
        do {
            iCloudAccountStatus = try await CKContainer.default().accountStatus()
        } catch {
            iCloudAccountStatus = .couldNotDetermine
        }
    }

    /// Toggle for the auto-maintained "Music Notifier" Apple Music playlist. Off
    /// by default since it writes to the user's library. Includes a debug
    /// "recreate" action that clears the stored ID so the next sync creates a
    /// fresh playlist (handy if the user manually deletes it).
    private var applePlaylistSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("APPLE MUSIC PLAYLIST")
                .font(.caption.weight(.semibold))
                .tracking(1.2)
                .foregroundStyle(AppTheme.secondary)
                .padding(.horizontal, 24)

            VStack(spacing: 0) {
                settingsToggle("Sync new releases to a playlist", isOn: $syncToApplePlaylist)
                if syncToApplePlaylist {
                    settingsDivider
                    HStack {
                        Text("Playlist status")
                            .foregroundStyle(AppTheme.primaryText)
                        Spacer()
                        Text(appleMusicPlaylistID.isEmpty ? "Not created yet" : "Active")
                            .foregroundStyle(AppTheme.secondary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                }

                // Always available — rules work independently of the default
                // sync toggle. A user can have rules without mirroring everything.
                settingsDivider
                NavigationLink {
                    PlaylistRulesView()
                } label: {
                    HStack {
                        Image(systemName: "slider.horizontal.3")
                        Text("Playlist rules")
                            .foregroundStyle(AppTheme.primaryText)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(AppTheme.secondary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .foregroundStyle(AppTheme.accent)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(AppTheme.surface)
            )
            .padding(.horizontal, 20)

            if syncToApplePlaylist {
                Text("New releases from tracked artists are added to a playlist called \"Music Notifier\" in your Apple Music library. Play it from CarPlay, HomePod, your watch, or the Music app.")
                    .font(.caption)
                    .foregroundStyle(AppTheme.secondary)
                    .padding(.horizontal, 24)
            }
        }
    }

    private var preAlertPicker: some View {
        Menu {
            ForEach(PreAlertOption.allCases) { option in
                Button {
                    togglePreAlert(option)
                } label: {
                    HStack {
                        Text(option.label)
                        Spacer()
                        if preAlertSelection.contains(option.days) {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
            if !preAlertSelection.isEmpty {
                Divider()
                Button(role: .destructive) {
                    releasePreAlertDays = ""
                } label: {
                    Label("None", systemImage: "xmark")
                }
            }
        } label: {
            HStack {
                Text("Pre-release alerts")
                    .foregroundStyle(AppTheme.primaryText)
                Spacer()
                Text(preAlertSummary)
                    .foregroundStyle(AppTheme.secondary)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(AppTheme.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }

    private var preAlertSelection: Set<Int> {
        Set(releasePreAlertDays
            .split(separator: ",")
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) })
    }

    private var preAlertSummary: String {
        guard !preAlertSelection.isEmpty else { return "Off" }
        return preAlertSelection.sorted().map(PreAlertOption.summaryLabel(for:)).joined(separator: ", ")
    }

    private func togglePreAlert(_ option: PreAlertOption) {
        var current = preAlertSelection
        if current.contains(option.days) {
            current.remove(option.days)
        } else {
            current.insert(option.days)
        }
        releasePreAlertDays = current.sorted().map(String.init).joined(separator: ",")
    }

    /// Built as a `Menu` rather than a `Picker`, matching `preAlertPicker`
    /// directly above it. A `.menu` Picker outside a Form/List drops its
    /// label, so this row rendered as a lone centered "Albums & Singles" in
    /// accent red with no indication of what it controlled — every other row
    /// in the card is left-aligned label + right-aligned value.
    private var notificationTypePicker: some View {
        Menu {
            Picker("Notify for", selection: $globalNotificationReleasePreference) {
                Text("Albums & Singles").tag(ArtistNotificationPreference.all.rawValue)
                Text("Albums Only").tag(ArtistNotificationPreference.albumsOnly.rawValue)
                Text("Singles Only").tag(ArtistNotificationPreference.singlesOnly.rawValue)
            }
        } label: {
            HStack {
                Text("Notify for")
                    .foregroundStyle(AppTheme.primaryText)
                Spacer()
                Text(notificationTypeSummary)
                    .foregroundStyle(AppTheme.secondary)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(AppTheme.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }

    private var notificationTypeSummary: String {
        switch ArtistNotificationPreference(rawValue: globalNotificationReleasePreference) {
        case .albumsOnly: "Albums Only"
        case .singlesOnly: "Singles Only"
        default: "Albums & Singles"
        }
    }

    // MARK: - Appearance

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("APPEARANCE")
                .font(.caption.weight(.semibold))
                .tracking(1.2)
                .foregroundStyle(AppTheme.secondary)
                .padding(.horizontal, 24)

            VStack(spacing: 0) {
                Picker("Appearance", selection: $appearanceRaw) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous).fill(AppTheme.surface)
            )
            .padding(.horizontal, 20)

            Text("Match iOS, or force a light or dark theme regardless of the system setting.")
                .font(.caption)
                .foregroundStyle(AppTheme.secondary)
                .padding(.horizontal, 24)
        }
    }

    // MARK: - Actions

    private func clearReleases() {
        Task {
            await NotificationScheduler().cancelReleaseNotifications()
        }
        releases.forEach(modelContext.delete)
        try? modelContext.save()
        statusMessage = "Cleared saved releases."
    }

    private func resetOnboardingOnly() {
        UserDefaults.standard.set(false, forKey: "hasCompletedOnboarding")
        statusMessage = "Onboarding will show next time the main view reloads."
    }

    private func clearArtistsAndReleases() {
        Task {
            await NotificationScheduler().cancelReleaseNotifications()
        }
        releases.forEach(modelContext.delete)
        artists.forEach(modelContext.delete)
        try? modelContext.save()
        statusMessage = "Cleared imported artists and saved releases."
    }

    private func clearUntrackedArtists() {
        artists.filter { !$0.isTracked }.forEach(modelContext.delete)
        try? modelContext.save()
        statusMessage = "Cleared untracked artists."
    }

    private func clearStaleReleases() {
        let cutoff = Calendar.current.date(byAdding: .day, value: -180, to: Date()) ?? Date.distantPast
        let staleReleases = releases.filter { release in
            (release.releaseDate ?? release.firstSeenAt) < cutoff
        }

        staleReleases.forEach(modelContext.delete)
        try? modelContext.save()
        statusMessage = "Cleared \(staleReleases.count) old releases."
    }

}

#Preview {
    NavigationStack {
        SettingsView()
    }
    .modelContainer(for: [ArtistData.self, ReleaseData.self], inMemory: true)
}
