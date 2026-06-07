//
//  AppTheme.swift
//  MusicNotifier
//

import SwiftUI
import UIKit

enum AppTheme {
    // Adaptive palette. Dark mode keeps the true-black OLED-tuned values; light
    // mode lifts to a near-white base with subtle gray surfaces so the same
    // card/section structure reads at a glance under either appearance.
    private static func adaptive(dark: UIColor, light: UIColor) -> Color {
        Color(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .light ? light : dark
        })
    }

    static let background = adaptive(
        dark: UIColor(red: 0.055, green: 0.055, blue: 0.055, alpha: 1),
        light: UIColor(red: 0.97, green: 0.97, blue: 0.98, alpha: 1)
    )
    static let surface = adaptive(
        dark: UIColor(red: 0.086, green: 0.086, blue: 0.086, alpha: 1),
        light: UIColor(white: 1.0, alpha: 1.0)
    )
    static let elevatedSurface = adaptive(
        dark: UIColor(red: 0.122, green: 0.122, blue: 0.122, alpha: 1),
        light: UIColor(red: 0.93, green: 0.93, blue: 0.94, alpha: 1)
    )
    static let hairline = adaptive(
        dark: UIColor(white: 1.0, alpha: 0.06),
        light: UIColor(white: 0.0, alpha: 0.08)
    )

    /// Body-text foreground that adapts: white in dark mode, near-black in
    /// light. Use this in place of literal `.white` everywhere text sits on
    /// `background`/`surface`/`elevatedSurface`. Text that sits on top of a
    /// colored fill (accent CTA, badge) should keep its own explicit color.
    static let primaryText = adaptive(
        dark: UIColor.white,
        light: UIColor(white: 0.07, alpha: 1.0)
    )

    // Brand accent follows the selected music provider. Spotify → green, Apple Music → red/pink.
    static var accent: Color {
        switch UserDefaults.standard.string(forKey: AppSettings.selectedMusicProvider) {
        case MusicProvider.spotify.rawValue:
            return Color(red: 0.114, green: 0.725, blue: 0.329)
        default:
            return Color(red: 0.980, green: 0.141, blue: 0.235)
        }
    }
    static var accentSoft: Color { accent.opacity(0.16) }
    // Neutral nav accent — used for toolbar icons, Done buttons, refresh chevrons.
    // Keeping nav off the brand red preserves red for *meaning* (destructive,
    // imminent badges, unread dots) instead of decoration.
    static let navAccent = primaryText
    // Brightened secondary so caption metadata clears WCAG AA against the
    // dark surface — previous 0.62 grey failed contrast for small text.
    static let secondary = adaptive(
        dark: UIColor(white: 0.75, alpha: 1),
        light: UIColor(red: 0.36, green: 0.36, blue: 0.40, alpha: 1)
    )

    static var coral: Color { accent }
    static let teal = Color(red: 0.40, green: 0.78, blue: 0.78)
    static let yellow = Color(red: 0.96, green: 0.80, blue: 0.45)

    static var accentGradient: LinearGradient {
        LinearGradient(
            colors: [accent, accent.opacity(0.75)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

struct AppScreenBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background(AppTheme.background.ignoresSafeArea())
            .tint(AppTheme.accent)
    }
}

struct AppCardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .listRowBackground(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(AppTheme.surface)
                    .padding(.vertical, 2)
            )
            .listRowSeparator(.hidden)
    }
}

extension View {
    func appScreenBackground() -> some View {
        modifier(AppScreenBackground())
    }

    func appCardRow() -> some View {
        modifier(AppCardStyle())
    }
}

extension Color {
    /// Initialize from a 6-digit hex string ("4ade80" or "#4ade80"). Falls back
    /// to gray for malformed input rather than crashing — the badge stays visible.
    init(hex: String) {
        var trimmed = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("#") { trimmed.removeFirst() }
        guard trimmed.count == 6, let value = UInt32(trimmed, radix: 16) else {
            self = .gray
            return
        }
        let r = Double((value >> 16) & 0xFF) / 255.0
        let g = Double((value >> 8) & 0xFF) / 255.0
        let b = Double(value & 0xFF) / 255.0
        self = Color(red: r, green: g, blue: b)
    }

    /// Encode back to 6-digit hex so a user-picked color can persist in @AppStorage.
    var hexString: String {
        let ui = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(
            format: "%02X%02X%02X",
            Int((r * 255).rounded()),
            Int((g * 255).rounded()),
            Int((b * 255).rounded())
        )
    }
}

/// Small colored pill that surfaces a release's kind at a glance on Feed rows
/// and grid cards. Singles deliberately get no badge — only the "album" family
/// and the special types (EP, live, compilation, remix) render one.
struct ReleaseTypeBadge: View {
    let kind: ReleaseKind
    @AppStorage(AppSettings.showReleaseTypeBadges) private var showReleaseTypeBadges = true
    // Subscribing to each hex via @AppStorage is what lets badges re-render
    // when the user picks a new color in Settings. A bare
    // `UserDefaults.standard.string(forKey:)` lookup isn't observed by
    // SwiftUI, so previously the new color only appeared after a full view
    // rebuild (relaunching the app, scrolling the row out and back in).
    @AppStorage(AppSettings.albumBadgeColorHex) private var albumHex = AppSettings.defaultAlbumBadgeColorHex
    @AppStorage(AppSettings.epBadgeColorHex) private var epHex = AppSettings.defaultEPBadgeColorHex
    @AppStorage(AppSettings.liveBadgeColorHex) private var liveHex = AppSettings.defaultLiveBadgeColorHex
    @AppStorage(AppSettings.compilationBadgeColorHex) private var compilationHex = AppSettings.defaultCompilationBadgeColorHex
    @AppStorage(AppSettings.remixBadgeColorHex) private var remixHex = AppSettings.defaultRemixBadgeColorHex

    var body: some View {
        guard showReleaseTypeBadges, let palette = currentPalette else {
            return AnyView(EmptyView())
        }
        return AnyView(
            Text(palette.label)
                .font(.system(size: 9, weight: .heavy))
                .tracking(0.6)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .foregroundStyle(palette.fg)
                .background(Capsule().fill(palette.bg))
        )
    }

    struct Palette {
        let bg: Color
        let fg: Color
        let label: String
    }

    /// Builds the live palette from observed @AppStorage hex values, so badge
    /// recolors in Settings propagate immediately to every feed row.
    private var currentPalette: Palette? {
        let (hex, label): (String, String)
        switch kind {
        case .single: return nil
        case .album: (hex, label) = (albumHex, "ALBUM")
        case .ep: (hex, label) = (epHex, "EP")
        case .liveAlbum: (hex, label) = (liveHex, "LIVE")
        case .compilation: (hex, label) = (compilationHex, "COMP")
        case .remix: (hex, label) = (remixHex, "REMIX")
        }
        let fg = Color(hex: hex)
        return Palette(bg: fg.opacity(0.18), fg: fg, label: label)
    }

    /// Static fallback used by callers outside SwiftUI views (e.g. the widget
    /// extension or one-off renders that don't get @AppStorage observation).
    /// In-app SwiftUI callers should rely on the instance `body` so changes
    /// propagate live.
    static func palette(for kind: ReleaseKind) -> Palette? {
        guard let spec = ReleaseTypeBadge.colorSpec(for: kind) else { return nil }
        let hex = UserDefaults.standard.string(forKey: spec.storageKey) ?? spec.defaultHex
        let fg = Color(hex: hex)
        return Palette(bg: fg.opacity(0.18), fg: fg, label: spec.label)
    }

    /// Static metadata for each configurable kind: where to read/write the
    /// color, what default to fall back to, and what label to render.
    struct ColorSpec {
        let storageKey: String
        let defaultHex: String
        let label: String
    }

    static func colorSpec(for kind: ReleaseKind) -> ColorSpec? {
        switch kind {
        case .single:
            return nil
        case .album:
            return ColorSpec(storageKey: AppSettings.albumBadgeColorHex,
                             defaultHex: AppSettings.defaultAlbumBadgeColorHex,
                             label: "ALBUM")
        case .ep:
            return ColorSpec(storageKey: AppSettings.epBadgeColorHex,
                             defaultHex: AppSettings.defaultEPBadgeColorHex,
                             label: "EP")
        case .liveAlbum:
            return ColorSpec(storageKey: AppSettings.liveBadgeColorHex,
                             defaultHex: AppSettings.defaultLiveBadgeColorHex,
                             label: "LIVE")
        case .compilation:
            return ColorSpec(storageKey: AppSettings.compilationBadgeColorHex,
                             defaultHex: AppSettings.defaultCompilationBadgeColorHex,
                             label: "COMP")
        case .remix:
            return ColorSpec(storageKey: AppSettings.remixBadgeColorHex,
                             defaultHex: AppSettings.defaultRemixBadgeColorHex,
                             label: "REMIX")
        }
    }
}

/// Small "from label" badge surfaced on release rows when the source artist
/// is actually a record label rather than an artist.
struct LabelSourceBadge: View {
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "music.note.house.fill")
                .font(.system(size: 9, weight: .bold))
            Text("LABEL")
                .font(.system(size: 9, weight: .heavy))
                .tracking(0.6)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .foregroundStyle(.white)
        .background(Capsule().fill(AppTheme.accent.opacity(0.85)))
    }
}

struct StatusPill: View {
    let title: String
    let systemImage: String
    var color: Color = AppTheme.accent

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(color.opacity(0.14))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
}

struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.caption.weight(.semibold))
            .tracking(1.2)
            .foregroundStyle(AppTheme.secondary)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    var tint: Color = AppTheme.accent

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(tint.opacity(configuration.isPressed ? 0.85 : 1.0))
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct GhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(AppTheme.elevatedSurface.opacity(configuration.isPressed ? 0.7 : 1.0))
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct CompactActionButtonStyle: ButtonStyle {
    var tint: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity)
            .frame(height: 42)
            .background(tint.opacity(configuration.isPressed ? 0.78 : 1.0))
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
