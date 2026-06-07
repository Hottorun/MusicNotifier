//
//  ICloudWelcomeView.swift
//  MusicNotifier
//
//  Shown on a fresh install when CloudKit-mirrored SwiftData has already
//  hydrated artists from a previous device. Lets the user skip onboarding
//  since their watchlist is already populated.
//

import SwiftUI
import SwiftData

struct ICloudWelcomeView: View {
    let artistCount: Int
    let trackedCount: Int
    let onContinue: () -> Void
    let onStartFresh: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 20) {
                ZStack {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(AppTheme.accent)
                        .frame(width: 96, height: 96)
                    Image(systemName: "checkmark.icloud.fill")
                        .font(.system(size: 38, weight: .semibold))
                        .foregroundStyle(AppTheme.primaryText)
                }

                VStack(spacing: 10) {
                    Text("Welcome back")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .foregroundStyle(AppTheme.primaryText)
                    Text("We found your watchlist on iCloud.")
                        .font(.body)
                        .foregroundStyle(AppTheme.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                HStack(spacing: 24) {
                    statTile(value: "\(artistCount)", label: "imported")
                    statTile(value: "\(trackedCount)", label: "tracked")
                }
                .padding(.top, 8)
            }

            Spacer()

            VStack(spacing: 12) {
                Button {
                    onContinue()
                } label: {
                    Label("Continue", systemImage: "arrow.forward")
                }
                .buttonStyle(PrimaryButtonStyle())

                Button {
                    onStartFresh()
                } label: {
                    Text("Start fresh instead")
                }
                .buttonStyle(GhostButtonStyle())
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.background.ignoresSafeArea())
        .tint(AppTheme.accent)
    }

    private func statTile(value: String, label: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(AppTheme.primaryText)
            Text(label)
                .font(.caption)
                .foregroundStyle(AppTheme.secondary)
        }
        .frame(minWidth: 96)
        .padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(AppTheme.surface))
    }
}
