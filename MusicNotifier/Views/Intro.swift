//
//  Intro.swift
//  MusicNotifier
//
//  Created by Dimitris Kern on 28.07.25.
//

import SwiftUI
import MusicKit
import SwiftData
import UIKit

struct Intro: View {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @AppStorage(AppSettings.selectedMusicProvider) private var selectedMusicProvider = MusicProvider.appleMusic.rawValue
    @State private var selectedItem: String = MusicProvider.appleMusic.rawValue
    @State private var authorizationMessage: String?
    @State private var isChoosingArtists = false
    @State private var authorizationDenied = false
    // User explicitly chose "I already have a watchlist in iCloud — wait
    // for it" — drives the ICloudSyncWaitingView takeover.
    @State private var isWaitingForICloud = false

    /// Today's date under the wordmark — the same rule that anchors the Feed
    /// and Upcoming lists, introduced on the very first screen.
    private static let introDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d MMMM"
        return f
    }()

    var body: some View {
        NavigationStack {
            if isWaitingForICloud {
                ICloudSyncWaitingView(
                    onCancel: { isWaitingForICloud = false }
                )
            } else if isChoosingArtists {
                OnboardingArtistImportView(
                    onFinish: { hasCompletedOnboarding = true }
                )
            } else {
                VStack(spacing: 0) {
                    Spacer()

                    // Opens on the app's own device rather than an app-icon
                    // restatement: a stacked wordmark cut off by the dated
                    // rule that runs through the whole product. The first
                    // screen should look like the thing it's selling.
                    VStack(alignment: .leading, spacing: 18) {
                        VStack(alignment: .leading, spacing: -10) {
                            Text("MUSIC")
                                .font(AppFont.display(64, .heavy))
                                .foregroundStyle(AppTheme.primaryText)
                            Text("NOTIFIER")
                                .font(AppFont.display(64, .heavy))
                                .foregroundStyle(AppTheme.accent)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Music Notifier")

                        TodayDivider(label: Self.introDateFormatter.string(from: Date()))

                        Text("Every release from every artist you follow, the day it lands.")
                            .font(AppFont.text(16))
                            .foregroundStyle(AppTheme.secondary)
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)

                    Spacer()

                    VStack(spacing: 12) {
                        HStack(spacing: 12) {
                            providerButton(name: MusicProvider.appleMusic.rawValue, imageName: "AppleMusicIcon", isAvailable: true)
                        }

                        if let authorizationMessage {
                            Text(authorizationMessage)
                                .font(.footnote)
                                .foregroundStyle(AppTheme.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 8)
                        }

                        Button {
                            Task { await authorize() }
                        } label: {
                            Label(authorizationDenied ? "Retry" : "Continue",
                                  systemImage: authorizationDenied ? "arrow.clockwise" : "arrow.forward")
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .padding(.top, 4)

                        if authorizationDenied {
                            Button {
                                if let url = URL(string: UIApplication.openSettingsURLString) {
                                    UIApplication.shared.open(url)
                                }
                            } label: {
                                Label("Open iOS Settings", systemImage: "gear")
                            }
                            .buttonStyle(GhostButtonStyle())
                        }

                        // Returning-user escape hatch. If they've used
                        // MusicNotifier before and have an iCloud-mirrored
                        // watchlist, skip the provider/import flow entirely
                        // and just sit on a waiting screen until CloudKit
                        // delivers — which on a fresh install can take
                        // several minutes for a real watchlist.
                        Button {
                            isWaitingForICloud = true
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "icloud.fill")
                                    .font(.footnote)
                                Text("I already have a watchlist in iCloud")
                                    .font(AppFont.text(13, .semibold))
                            }
                        }
                        .buttonStyle(.plain)
                        // Neutral, not accent. This is the rarely-used escape
                        // hatch; with the wordmark and the CTA already in
                        // accent, a third red element made the screen read as
                        // three competing calls to action.
                        .foregroundStyle(AppTheme.secondary)
                        .padding(.top, 8)
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 32)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(AppTheme.background.ignoresSafeArea())
            }
        }
        .tint(AppTheme.accent)
    }

    private func providerButton(name: String, imageName: String, isAvailable: Bool) -> some View {
        Button {
            selectedItem = name
            selectedMusicProvider = name
            UserDefaults(suiteName: AppSettings.appGroupIdentifier)?
                .set(name, forKey: AppSettings.selectedMusicProvider)
            authorizationMessage = nil
        } label: {
            // Compact row rather than a tall tile. With one provider this is
            // a statement of what the app connects to, not a real choice —
            // it shouldn't outweigh the Continue button beneath it.
            HStack(spacing: 12) {
                Image(imageName)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

                VStack(alignment: .leading, spacing: 1) {
                    Text(name)
                        .font(AppFont.text(15, .semibold))
                        .foregroundStyle(AppTheme.primaryText)
                    if !isAvailable {
                        Text("Not available")
                            .font(AppFont.text(12))
                            .foregroundStyle(AppTheme.secondary)
                    }
                }

                Spacer(minLength: 0)

                if selectedItem == name && isAvailable {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(AppTheme.accent)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(AppTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous)
                    .strokeBorder(
                        selectedItem == name ? AppTheme.accent.opacity(0.5) : AppTheme.hairline,
                        lineWidth: 1
                    )
            }
            .opacity(isAvailable ? 1.0 : 0.55)
        }
        .buttonStyle(.plain)
    }

    private func authorize() async {
        let auth = await MusicAuthorization.request()
        if auth == .authorized {
            selectedMusicProvider = selectedItem
            UserDefaults(suiteName: AppSettings.appGroupIdentifier)?
                .set(selectedItem, forKey: AppSettings.selectedMusicProvider)
            authorizationDenied = false
            isChoosingArtists = true
            // Resolve MusicKit identity in the background while the user picks artists,
            // so the first post-onboarding refresh doesn't hang on ICError -7007.
            Task.detached(priority: .utility) {
                _ = try? await MusicSubscription.current
            }
        } else {
            authorizationDenied = true
            switch auth {
            case .denied:
                authorizationMessage = "Apple Music access was denied. Enable it in iOS Settings, then tap Retry."
            case .restricted:
                authorizationMessage = "Apple Music access is restricted on this device (parental controls or MDM)."
            default:
                authorizationMessage = "Apple Music access is needed to import artists from your library."
            }
        }
    }
}

private struct OnboardingArtistImportView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ArtistData.name) private var artists: [ArtistData]
    @AppStorage(AppSettings.selectedMusicProvider) private var selectedMusicProvider = MusicProvider.appleMusic.rawValue
    @State private var importMode: ArtistImportMode = .all
    @State private var isImporting = false
    @State private var importMessage: String?
    @State private var notificationMessage: String?
    let onFinish: () -> Void

    private var trackedArtists: [ArtistData] {
        artists.filter(\.isTracked)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 20) {
                    header

                    importCard

                    if artists.isEmpty {
                        emptyState
                    } else {
                        artistList
                    }

                    if let importMessage {
                        Text(importMessage)
                            .font(.footnote)
                            .foregroundStyle(AppTheme.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 20)
                    }

                    if let notificationMessage {
                        Text(notificationMessage)
                            .font(.footnote)
                            .foregroundStyle(AppTheme.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 20)
                    }

                    if trackedArtists.count > 100 {
                        Text("Tracking many artists can slow refreshes and hit API limits.")
                            .font(.footnote)
                            .foregroundStyle(AppTheme.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 20)
                    }

                    Spacer(minLength: 120)
                }
                .padding(.top, 8)
            }

            bottomBar
        }
        .navigationTitle("Track Artists")
        .navigationBarTitleDisplayMode(.inline)
        .appScreenBackground()
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Skip") {
                    onFinish()
                }
                .foregroundStyle(AppTheme.secondary)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Pick the artists you follow")
                .font(AppFont.display(30, .heavy))
                .foregroundStyle(AppTheme.primaryText)
            Text("Import from Apple Music, then tap the bell beside each artist you want release alerts for.")
                .font(.subheadline)
                .foregroundStyle(AppTheme.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
    }

    private var importCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ForEach(ArtistImportMode.allCases) { mode in
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { importMode = mode }
                    } label: {
                        Text(mode.rawValue)
                            .font(.footnote.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(
                                Capsule().fill(importMode == mode ? AppTheme.accent : AppTheme.elevatedSurface)
                            )
                            .foregroundStyle(importMode == mode ? .white : AppTheme.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }

            Text(importMode.description)
                .font(.footnote)
                .foregroundStyle(AppTheme.secondary)

            Button {
                Task { await importArtists() }
            } label: {
                Label(isImporting ? "Importing…" : "Import from Apple Music", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(isImporting)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(AppTheme.surface))
        .padding(.horizontal, 20)
    }

    private var bulkActions: some View {
        HStack(spacing: 10) {
            Button {
                setAllArtistsTracked(true)
            } label: {
                Label("Track all", systemImage: "bell.badge")
            }
            .buttonStyle(GhostButtonStyle())
            .disabled(artists.isEmpty)

            Button {
                setAllArtistsTracked(false)
            } label: {
                Label("Untrack all", systemImage: "bell.slash")
            }
            .buttonStyle(GhostButtonStyle())
            .disabled(trackedArtists.isEmpty)
        }
        .padding(.horizontal, 20)
    }

    private var artistList: some View {
        VStack(spacing: 8) {
            ForEach(artists) { artist in
                HStack(spacing: 12) {
                    AsyncImage(url: artist.artworkURL) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().aspectRatio(contentMode: .fill)
                        default:
                            Circle().fill(AppTheme.elevatedSurface)
                        }
                    }
                    .frame(width: 40, height: 40)
                    .clipShape(Circle())

                    Text(artist.name)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(AppTheme.primaryText)
                        .lineLimit(1)

                    Spacer()

                    Button {
                        artist.isTracked.toggle()
                        try? modelContext.save()
                    } label: {
                        Image(systemName: artist.isTracked ? "bell.fill" : "bell")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(artist.isTracked ? AppTheme.accent : AppTheme.secondary)
                            .frame(width: 32, height: 32)
                            .background(
                                Circle().fill(artist.isTracked ? AppTheme.accentSoft : AppTheme.elevatedSurface)
                            )
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(AppTheme.surface))
            }
        }
        .padding(.horizontal, 20)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "music.note.list")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(AppTheme.secondary)
            Text("Nothing imported yet")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.primaryText)
            Text("Choose an import mode above and pull your library in.")
                .font(.footnote)
                .foregroundStyle(AppTheme.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .padding(.horizontal, 24)
    }

    private var bottomBar: some View {
        VStack(spacing: 0) {
            Divider().background(AppTheme.hairline)
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(trackedArtists.count) tracked")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.primaryText)
                    Text("of \(artists.count) imported")
                        .font(.caption)
                        .foregroundStyle(AppTheme.secondary)
                }

                Spacer()

                if !trackedArtists.isEmpty {
                    Button {
                        // Fire-and-forget the notification prompt so onboarding always advances,
                        // even if the system prompt is slow or wedged.
                        Task.detached {
                            await NotificationScheduler().requestAuthorization()
                        }
                        onFinish()
                    } label: {
                        HStack(spacing: 6) {
                            Text("Enable & continue")
                            Image(systemName: "arrow.forward")
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .frame(maxWidth: 220)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(AppTheme.background)
        }
    }

    @MainActor
    private func importArtists() async {
        isImporting = true
        importMessage = nil

        do {
            // Always report the outcome. Reporting only failures meant a
            // library with nothing to import (or nothing matching the mode)
            // looked identical to a button that did nothing at all.
            let imported = try await AppleMusicLibraryImportService()
                .importArtists(mode: importMode, into: modelContext)
            if imported > 0 {
                importMessage = "Imported \(imported) artist\(imported == 1 ? "" : "s")."
            } else if artists.isEmpty {
                importMessage = "No artists found in your Apple Music library for this import mode."
            } else {
                importMessage = "No new artists to import — everything is already here."
            }
        } catch {
            importMessage = "Could not import artists: \(error.localizedDescription)"
        }

        isImporting = false
    }

    private func setAllArtistsTracked(_ isTracked: Bool) {
        artists.forEach { artist in
            artist.isTracked = isTracked
        }
        try? modelContext.save()
    }

    @MainActor
    private func requestNotificationAccess() async {
        let granted = await NotificationScheduler().requestAuthorization()
        notificationMessage = granted ? "Notifications enabled." : "Notifications were not enabled. You can change this later in Settings."
    }
}

#Preview {
    Intro()
        .modelContainer(for: [ArtistData.self, ReleaseData.self], inMemory: true)
}
