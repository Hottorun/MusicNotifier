//
//  AppTheme.swift
//  MusicNotifier
//
//  ─────────────────────────────────────────────────────────────────────────
//  DESIGN SYSTEM — "Release Sheet"
//
//  The app's job is to answer one question fast: what dropped, and what's
//  coming. Its edge over a streaming app is that it knows *dates*. So the
//  visual system makes the date the structural spine of every list rather
//  than a caption at the bottom of a row.
//
//  Voice — SF Pro's width axes carry the personality. Structural type
//  (dates, section headers, eyebrows, hero titles) is set COMPRESSED and
//  heavy, which reads like a printed release schedule stapled to a record
//  shop wall. Body copy stays standard-width so nothing becomes hard to
//  read. The previous system used `design: .rounded` for every headline,
//  which is the friendly iOS default and said nothing about music.
//
//  Color — album artwork is the only saturated thing on screen. Chrome is a
//  cool graphite neutral, and the brand accent is reserved for *meaning*
//  (out today, unread, active filter, destructive) rather than decoration.
//  ─────────────────────────────────────────────────────────────────────────
//

import SwiftUI
import UIKit

enum AppTheme {
    // Adaptive palette. Dark mode keeps OLED-tuned near-black values; light
    // mode lifts to a near-white base with subtle gray surfaces so the same
    // card/section structure reads at a glance under either appearance.
    private static func adaptive(dark: UIColor, light: UIColor) -> Color {
        Color(uiColor: UIColor { trait in
            // Only `.dark` gets the dark value. The previous
            // `== .light ? light : dark` also mapped `.unspecified` to dark,
            // so any resolution without a real trait collection — UIKit
            // chrome like a toolbar background, widget snapshots — silently
            // came back near-black on an otherwise light screen.
            trait.userInterfaceStyle == .dark ? dark : light
        })
    }

    // MARK: - Surfaces
    //
    // The neutrals carry a slight blue-violet cast rather than being pure
    // gray. Against them, album artwork (which is almost always warm or
    // saturated) separates instead of blending into the chrome.

    static let background = adaptive(
        dark: UIColor(red: 0.043, green: 0.043, blue: 0.055, alpha: 1),
        light: UIColor(red: 0.945, green: 0.945, blue: 0.957, alpha: 1)
    )
    static let surface = adaptive(
        dark: UIColor(red: 0.078, green: 0.078, blue: 0.098, alpha: 1),
        light: UIColor(white: 1.0, alpha: 1.0)
    )
    static let elevatedSurface = adaptive(
        dark: UIColor(red: 0.125, green: 0.125, blue: 0.153, alpha: 1),
        light: UIColor(red: 0.902, green: 0.902, blue: 0.925, alpha: 1)
    )
    static let hairline = adaptive(
        dark: UIColor(white: 1.0, alpha: 0.09),
        light: UIColor(white: 0.0, alpha: 0.10)
    )

    /// Body-text foreground that adapts: near-white in dark mode, near-black
    /// in light. Use this in place of literal `.white` everywhere text sits
    /// on `background`/`surface`/`elevatedSurface`. Text on a colored fill
    /// (accent CTA, badge) should keep its own explicit color.
    static let primaryText = adaptive(
        dark: UIColor(red: 0.965, green: 0.965, blue: 0.976, alpha: 1),
        light: UIColor(red: 0.063, green: 0.063, blue: 0.078, alpha: 1)
    )

    /// Secondary/metadata foreground. Both values clear WCAG AA for small
    /// text against `background` and `surface` in their own appearance.
    static let secondary = adaptive(
        dark: UIColor(red: 0.659, green: 0.659, blue: 0.714, alpha: 1),
        light: UIColor(red: 0.361, green: 0.361, blue: 0.420, alpha: 1)
    )

    /// Deliberately below AA — for structural marks only (rules, inactive
    /// rail segments, watermark numerals), never for text a user must read.
    static let faint = adaptive(
        dark: UIColor(white: 1.0, alpha: 0.22),
        light: UIColor(white: 0.0, alpha: 0.20)
    )

    // Brand accent follows the selected music provider. Spotify → green,
    // Apple Music → red/pink.
    static var accent: Color {
        switch UserDefaults.standard.string(forKey: AppSettings.selectedMusicProvider) {
        case MusicProvider.spotify.rawValue:
            return Color(red: 0.114, green: 0.725, blue: 0.329)
        default:
            return Color(red: 0.980, green: 0.141, blue: 0.235)
        }
    }
    static var accentSoft: Color { accent.opacity(0.16) }
    // Neutral nav accent — used for toolbar icons, Done buttons, refresh
    // chevrons. Keeping nav off the brand red preserves red for *meaning*
    // (destructive, imminent badges, unread dots) instead of decoration.
    static let navAccent = primaryText

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

    // MARK: - Metrics
    //
    // One scale, used everywhere. Named by role rather than by number so a
    // card and a chip can't drift apart as views get edited independently.

    enum Radius {
        /// Full-width cards and grouped containers.
        static let card: CGFloat = 16
        /// Album artwork in rows and grids.
        static let tile: CGFloat = 10
        /// Large artwork (hero rows, detail headers).
        static let heroTile: CGFloat = 14
        /// Buttons and inputs.
        static let control: CGFloat = 12
    }

    enum Space {
        /// Screen gutter. Every top-level list, header, and section aligns
        /// to this, so the left edge of the app is a single vertical line.
        static let gutter: CGFloat = 18
        static let rowGap: CGFloat = 8
        static let sectionGap: CGFloat = 22
    }

    /// The left date rail's fixed width. Every row that shows one reserves
    /// exactly this, which is what makes titles line up down the whole feed.
    static let railWidth: CGFloat = 38
}

// MARK: - Typography

/// The type ramp. `display` is the compressed structural voice; `text` is
/// standard-width body. Keeping both behind named helpers means a future
/// change of voice is one file, not four hundred call sites.
enum AppFont {
    /// Compressed + heavy. The app's structural voice: date numerals,
    /// section headers, hero titles. Use with restraint — at body sizes
    /// compressed type is harder to read, so it stays above ~16pt or in
    /// short uppercase runs.
    static func display(_ size: CGFloat, _ weight: Font.Weight = .heavy) -> Font {
        .system(size: size, weight: weight).width(.compressed)
    }

    /// One step wider than `display`. For hero titles long enough that full
    /// compression starts to hurt legibility.
    static func condensed(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight).width(.condensed)
    }

    /// Standard-width body text. Takes a nominal point size for readability
    /// at the call site but resolves to the nearest Dynamic Type style, so
    /// every piece of body copy still scales with the user's text-size
    /// setting. (Fixed `.system(size:)` does not scale — which is fine for
    /// the display sizes above, where type is set optically, but wrong for
    /// anything the user has to actually read.)
    static func text(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(textStyle(forNominal: size), weight: weight)
    }

    /// Compressed uppercase label that still honors Dynamic Type. Used for
    /// eyebrows and rail captions — small structural type that must stay
    /// readable when a user turns text size up.
    static func label(_ size: CGFloat, _ weight: Font.Weight = .heavy) -> Font {
        .system(textStyle(forNominal: size), weight: weight).width(.compressed)
    }

    /// Maps a nominal point size onto the closest system text style. The
    /// sizes are the platform defaults at the Large content-size category.
    private static func textStyle(forNominal size: CGFloat) -> Font.TextStyle {
        switch size {
        case ..<11.5: .caption2   // 11
        case ..<12.5: .caption    // 12
        case ..<14: .footnote     // 13
        case ..<15.5: .subheadline // 15
        case ..<16.5: .callout    // 16
        case ..<18: .body         // 17
        case ..<19.5: .title3     // 20
        default: .title2          // 22
        }
    }

    /// Small uppercase label that sits above a title (artist name, kind).
    /// Pair with `.tracking(0.8)` — supplied by `EyebrowText` below.
    static let eyebrow = label(11, .heavy)

    /// Section headers and rail captions.
    static let railCaption = label(10, .bold)

    /// Numerals that must not jitter as they tick (countdowns, X/Y counts).
    static func data(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight).monospacedDigit()
    }
}

/// Uppercase tracked label — the app's standard eyebrow. Used for artist
/// names above release titles, which is the scan order that matters in a
/// release radar: you look for *who* first, then what.
struct EyebrowText: View {
    let text: String
    var color: Color = AppTheme.secondary
    var size: CGFloat = 11

    var body: some View {
        Text(text.uppercased())
            // Scales with Dynamic Type — an artist name is a primary scan
            // target, not decoration, so it can't be frozen at 11pt.
            .font(AppFont.label(size, .heavy))
            .tracking(0.8)
            .foregroundStyle(color)
            .lineLimit(1)
    }
}

// MARK: - Screen / card modifiers

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
                RoundedRectangle(cornerRadius: AppTheme.Radius.card, style: .continuous)
                    .fill(AppTheme.surface)
                    .padding(.vertical, 2)
            )
            .listRowSeparator(.hidden)
    }
}

/// Standard card container: surface fill plus a hairline stroke. The stroke
/// is what keeps cards legible in light mode, where a white card on a
/// near-white background would otherwise have no edge at all.
struct AppCardSurface: ViewModifier {
    var radius: CGFloat = AppTheme.Radius.card
    var padding: CGFloat = 12

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(AppTheme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(AppTheme.hairline, lineWidth: 1)
            )
    }
}

extension View {
    func appScreenBackground() -> some View {
        modifier(AppScreenBackground())
    }

    func appCardRow() -> some View {
        modifier(AppCardStyle())
    }

    func appCard(radius: CGFloat = AppTheme.Radius.card, padding: CGFloat = 12) -> some View {
        modifier(AppCardSurface(radius: radius, padding: padding))
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

// MARK: - The date rail (signature element)

/// The app's signature: a fixed-width left column carrying a release's day
/// numeral over its month. Set in heavy compressed type so a column of them
/// reads as a schedule rather than as repeated metadata.
///
/// Because every rail is `AppTheme.railWidth` wide, artwork and titles line
/// up down the entire feed — the rail is a layout device as much as a
/// stylistic one. Releases that are still upcoming get the accent color;
/// released ones stay neutral so the eye lands on what hasn't happened yet.
struct DateRail: View {
    let date: Date?
    /// Highlights the numeral. Callers pass `true` for releases that are out
    /// today, which is the one row in the feed worth interrupting for.
    var isToday: Bool = false
    /// Adds the weekday under the month. Worth the extra line on the Upcoming
    /// tab — new music drops on Fridays, so "FRI" is real information there —
    /// but noise in the Feed, where everything is already out.
    var showsWeekday: Bool = false

    /// The rail's width scales with the user's text size. Because every rail
    /// in a list scales by the same factor, the column stays perfectly
    /// aligned — a fixed width would simply clip the numeral at large
    /// accessibility sizes.
    @ScaledMetric(relativeTo: .caption2) private var railWidth: CGFloat = AppTheme.railWidth

    private static let monthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM"
        return f
    }()

    private static let weekdayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE"
        return f
    }()

    var body: some View {
        VStack(spacing: -1) {
            if let date {
                Text(Self.dayString(date))
                    // `.title` (28pt at default) rather than a frozen 26 —
                    // the numeral is the row's anchor and has to grow with
                    // the rest of the row.
                    .font(.system(.title, weight: .heavy).width(.compressed))
                    .foregroundStyle(isToday ? AppTheme.accent : AppTheme.primaryText)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(Self.monthFormatter.string(from: date).uppercased())
                    .font(AppFont.railCaption)
                    .tracking(0.9)
                    .foregroundStyle(isToday ? AppTheme.accent : AppTheme.secondary)
                if showsWeekday {
                    Text(Self.weekdayFormatter.string(from: date).uppercased())
                        // Scales with the rest of the rail; it's set apart
                        // from the month by weight and color, not by a
                        // frozen point size.
                        .font(AppFont.label(10, .semibold))
                        .tracking(0.7)
                        .foregroundStyle(AppTheme.faint)
                        .padding(.top, 2)
                }
            } else {
                // Unknown release date. An em-dash keeps the rail's rhythm
                // instead of collapsing the row's left edge out of alignment.
                Text("—")
                    .font(.system(.title3, weight: .heavy).width(.compressed))
                    .foregroundStyle(AppTheme.faint)
                Text("TBA")
                    .font(AppFont.railCaption)
                    .tracking(0.9)
                    .foregroundStyle(AppTheme.faint)
            }
        }
        .frame(width: railWidth, alignment: .center)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilityLabel(for: date))
    }

    private static func dayString(_ date: Date) -> String {
        String(Calendar.current.component(.day, from: date))
    }

    private static func accessibilityLabel(for date: Date?) -> String {
        guard let date else { return "Release date not announced" }
        return date.formatted(.dateTime.day().month(.wide))
    }
}

/// The "out today" marker. A single full-width rule with the date set into
/// it, dropped into the feed where today falls. It's what turns an endless
/// scroll into a *now* — everything above it hasn't happened yet.
struct TodayDivider: View {
    var label: String = "TODAY"

    var body: some View {
        HStack(spacing: 10) {
            Rectangle()
                .fill(AppTheme.accent)
                .frame(width: 22, height: 2)
            Text(label.uppercased())
                .font(AppFont.display(12, .heavy))
                .tracking(1.4)
                .foregroundStyle(AppTheme.accent)
            Rectangle()
                .fill(AppTheme.hairline)
                .frame(height: 1)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Section header. Compressed uppercase title with an optional count and a
/// hairline running to the right edge, so sections read as ruled-off bands
/// on a sheet rather than as floating captions.
struct SectionHeader: View {
    let title: String
    var count: Int? = nil

    var body: some View {
        HStack(spacing: 8) {
            Text(title.uppercased())
                .font(AppFont.display(13, .heavy))
                .tracking(1.3)
                .foregroundStyle(AppTheme.primaryText)
            if let count, count > 0 {
                Text("\(count)")
                    .font(AppFont.data(11, .bold))
                    .foregroundStyle(AppTheme.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(AppTheme.elevatedSurface))
            }
            Rectangle()
                .fill(AppTheme.hairline)
                .frame(height: 1)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Badges and pills

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
                .font(AppFont.label(10, .heavy))
                .tracking(0.7)
                .lineLimit(1)
                // Never compress. These sit next to a truncating artist name
                // in feed rows; without this the badge is what gives way and
                // "ALBUM" renders clipped.
                .fixedSize(horizontal: true, vertical: false)
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
                .font(AppFont.label(10, .heavy))
                .tracking(0.7)
        }
        .fixedSize(horizontal: true, vertical: false)
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
            .font(AppFont.text(12, .semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(color.opacity(0.14))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
}

/// The unread marker. A small filled square rather than the usual dot —
/// it echoes the rail's rectangular rules, and squares are easier to spot
/// in peripheral vision at the same area as a circle.
struct UnreadMark: View {
    var size: CGFloat = 7

    var body: some View {
        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
            .fill(AppTheme.accent)
            .frame(width: size, height: size)
            .accessibilityLabel("Unread")
    }
}

/// "IN 3 DAYS" / "TOMORROW" / "TODAY" chip. The one place the accent is
/// allowed to shout on a list row — and only inside the 7-day window, so a
/// screen of far-off releases stays quiet and the imminent ones pop.
///
/// Shape carries the state as well as color: imminent chips are filled,
/// distant ones are outlined. That keeps the distinction legible without
/// relying on hue.
struct CountdownChip: View {
    let date: Date
    /// Larger variant for artwork overlays, where the chip sits on an
    /// unpredictable background and needs more presence.
    var prominent: Bool = false

    var body: some View {
        let imminent = ReleaseCountdown.isImminent(date)
        let isToday = ReleaseCountdown.days(to: date) == 0

        Text(ReleaseCountdown.label(for: date))
            .font(AppFont.display(prominent ? 11 : 10, .heavy))
            .tracking(0.7)
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, prominent ? 8 : 6)
            .padding(.vertical, prominent ? 4 : 2)
            .foregroundStyle(imminent ? .white : AppTheme.secondary)
            .background(
                Capsule().fill(imminent ? AppTheme.accent : AppTheme.elevatedSurface)
            )
            .overlay(
                Capsule().strokeBorder(
                    isToday ? .white.opacity(0.5) : .clear,
                    lineWidth: 1
                )
            )
    }
}

// MARK: - Empty states

/// Shared empty state. An empty screen is an invitation to act, so the
/// action is part of the component rather than something each caller
/// remembers to add.
struct AppEmptyState<Actions: View>: View {
    let title: String
    let message: String
    let systemImage: String
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: systemImage)
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(AppTheme.secondary)
                .frame(width: 64, height: 64)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(AppTheme.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(AppTheme.hairline, lineWidth: 1)
                )

            VStack(spacing: 6) {
                Text(title.uppercased())
                    .font(AppFont.display(17, .heavy))
                    .tracking(1.0)
                    .foregroundStyle(AppTheme.primaryText)
                Text(message)
                    .font(AppFont.text(13))
                    .foregroundStyle(AppTheme.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
            }
            .padding(.horizontal, 16)

            actions
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .padding(.horizontal, 24)
    }
}

// MARK: - Button styles

struct PrimaryButtonStyle: ButtonStyle {
    var tint: Color = AppTheme.accent

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(AppFont.text(15, .semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(tint.opacity(configuration.isPressed ? 0.85 : 1.0))
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct GhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(AppFont.text(15, .semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(AppTheme.elevatedSurface.opacity(configuration.isPressed ? 0.7 : 1.0))
            // Was hardcoded `.white`, which vanished on the light-mode
            // elevated surface.
            .foregroundStyle(AppTheme.primaryText)
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct CompactActionButtonStyle: ButtonStyle {
    var tint: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(AppFont.text(15, .semibold))
            .frame(maxWidth: .infinity)
            .frame(height: 42)
            .background(tint.opacity(configuration.isPressed ? 0.78 : 1.0))
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Pill control used for filters and layout toggles in list headers. Active
/// state is carried by fill + weight rather than by color alone, so it still
/// reads for a user who can't distinguish the accent hue.
struct ChipButtonStyle: ButtonStyle {
    var isActive: Bool = false
    var tint: Color = AppTheme.accent

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(AppFont.text(13, .semibold))
            .foregroundStyle(isActive ? tint : AppTheme.secondary)
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(
                Capsule().fill(isActive ? tint.opacity(0.15) : AppTheme.surface)
            )
            .overlay(
                Capsule().strokeBorder(isActive ? tint.opacity(0.35) : AppTheme.hairline, lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.7 : 1.0)
    }
}
