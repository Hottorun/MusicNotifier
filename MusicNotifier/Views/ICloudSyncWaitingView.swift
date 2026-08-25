//
//  ICloudSyncWaitingView.swift
//  MusicNotifier
//
//  Shown when the user explicitly tells us "I have an existing watchlist
//  in iCloud, just wait for it." CloudKit hydration on a fresh device
//  can take several minutes for a real watchlist (hundreds of artists,
//  thousands of releases), so blocking onboarding behind a short loader
//  is the wrong tool. This view keeps watching the SwiftData store for
//  ArtistData rows to land — works while the app is foregrounded — and
//  the moment any arrive, completes onboarding and fires a local
//  notification confirming the sync is ready.
//

import SwiftUI
import SwiftData
import UserNotifications
import UIKit
import MusicKit

struct ICloudSyncWaitingView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    let onCancel: () -> Void

    @State private var elapsedSeconds: Int = 0
    @State private var foundCount: Int? = nil
    @State private var lowPowerOn: Bool = ProcessInfo.processInfo.isLowPowerModeEnabled
    @State private var bgRefreshStatus: UIBackgroundRefreshStatus = UIApplication.shared.backgroundRefreshStatus
    @State private var appleMusicAuth: MusicAuthorization.Status = MusicAuthorization.currentStatus

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 24) {
                ZStack {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(AppTheme.accent)
                        .frame(width: 96, height: 96)
                    Image(systemName: "icloud.and.arrow.down.fill")
                        .font(.system(size: 38, weight: .semibold))
                        .foregroundStyle(AppTheme.primaryText)
                }

                VStack(spacing: 10) {
                    Text("Syncing from iCloud")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(AppTheme.primaryText)
                    Text("Your watchlist is on the way. This can take several minutes on a fresh install — keep the app open for the fastest result.")
                        .font(.body)
                        .foregroundStyle(AppTheme.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(AppTheme.accent)
                    Text(elapsedSeconds < 60
                         ? "Listening for iCloud (\(elapsedSeconds)s)"
                         : "Listening for iCloud (\(elapsedSeconds / 60)m \(elapsedSeconds % 60)s)")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(AppTheme.secondary)
                }
                .padding(.top, 4)

                // System-state warnings. Each of these can stall CloudKit
                // sync (especially when the app is backgrounded) so it's
                // worth surfacing them up-front rather than letting the
                // user sit on a hung loader.
                if !systemWarnings.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("To finish faster:")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(AppTheme.secondary)
                        ForEach(systemWarnings, id: \.self) { warning in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                                Text(warning)
                                    .font(.footnote)
                                    .foregroundStyle(AppTheme.primaryText)
                            }
                        }
                    }
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(AppTheme.surface))
                    .padding(.horizontal, 24)
                    .padding(.top, 12)
                }
            }

            Spacer()

            VStack(spacing: 12) {
                Button {
                    onCancel()
                } label: {
                    Text("Set up as new instead")
                        .font(.footnote.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(AppTheme.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.background.ignoresSafeArea())
        .task {
            // Request both permissions up-front. This path skips the
            // Intro's provider-picker (where MusicAuthorization is
            // normally requested), so without doing it here the user
            // would land in the main app with MusicKit unauthorized
            // and the first refresh would fail. Requesting now —
            // while they're already waiting — also keeps the system
            // prompt out of their way later.
            _ = try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
            _ = await MusicAuthorization.request()
            refreshSystemState()
            await pollForICloudData()
        }
        .onChange(of: scenePhase) { _, newPhase in
            // Each time the app comes back to the foreground, refresh
            // system-state warnings (the user may have just toggled
            // Low Power off / enabled Background App Refresh) and kick
            // an immediate fetch — CloudKit may have delivered rows
            // while we were suspended.
            if newPhase == .active {
                refreshSystemState()
                Task { await checkOnce() }
            }
        }
    }

    /// Friendly, action-oriented warnings for system settings that
    /// throttle background work. Empty when everything looks healthy.
    private var systemWarnings: [String] {
        var out: [String] = []
        if lowPowerOn {
            out.append("Turn off Low Power Mode — it suspends CloudKit sync.")
        }
        if bgRefreshStatus == .denied {
            out.append("Enable Background App Refresh for MusicNotifier in Settings → General.")
        } else if bgRefreshStatus == .restricted {
            out.append("Background App Refresh is restricted on this device.")
        }
        if appleMusicAuth == .denied || appleMusicAuth == .restricted {
            out.append("Allow Apple Music access in Settings if you plan to import or refresh later.")
        }
        return out
    }

    /// Refresh the system-state @State values. The view's `.task` and
    /// scene-phase resume both call this so the UI reflects changes the
    /// user makes while bouncing through iOS Settings.
    private func refreshSystemState() {
        lowPowerOn = ProcessInfo.processInfo.isLowPowerModeEnabled
        bgRefreshStatus = UIApplication.shared.backgroundRefreshStatus
        appleMusicAuth = MusicAuthorization.currentStatus
    }

    /// Long-running poll. Runs while the view is alive and the app is
    /// foregrounded; iOS will suspend the task with the app in the
    /// background, but `.onChange(scenePhase)` re-checks the moment we
    /// come back.
    private func pollForICloudData() async {
        let descriptor = FetchDescriptor<ArtistData>()
        while !Task.isCancelled {
            elapsedSeconds += 1
            if let fetched = try? modelContext.fetch(descriptor), !fetched.isEmpty {
                await completeSync(found: fetched)
                return
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    /// Single-shot fetch used by the scene-phase resume hook.
    private func checkOnce() async {
        let descriptor = FetchDescriptor<ArtistData>()
        if let fetched = try? modelContext.fetch(descriptor), !fetched.isEmpty {
            await completeSync(found: fetched)
        }
    }

    /// Apply the arriving iCloud data and finish onboarding. Posts a
    /// local notification so the user gets a heads-up even if they've
    /// already left the app and come back to a different screen.
    private func completeSync(found: [ArtistData]) async {
        guard foundCount == nil else { return } // run-once guard
        foundCount = found.count

        // Some sources of mirrored data carry `isTracked = false` (the
        // field didn't round-trip on the original device, or the user
        // imported but never tracked). Auto-enable tracking so the
        // Feed isn't empty after sync.
        if !found.contains(where: \.isTracked) {
            for artist in found { artist.isTracked = true }
            try? modelContext.save()
        }

        await fireReadyNotification(artistCount: found.count)
        hasCompletedOnboarding = true
    }

    private func fireReadyNotification(artistCount: Int) async {
        let content = UNMutableNotificationContent()
        content.title = "Watchlist Ready"
        content.body = "We've synced \(artistCount) artists from iCloud. Open MusicNotifier to see them."
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "icloud-sync-ready",
            content: content,
            // 1s trigger (not nil) so it fires reliably whether we're
            // currently foreground or background.
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        )
        try? await UNUserNotificationCenter.current().add(request)
    }
}
