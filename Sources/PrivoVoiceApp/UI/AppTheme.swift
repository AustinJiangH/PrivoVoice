// Shared visual theme, ported from the Voxtine app so PrivoVoice reads with the
// same warm palette and light/dark behavior.
//
// Three layers, used top-down:
//   • Palette   — raw hues (below). Do NOT reference these in feature views.
//   • Semantic  — named roles (accent/positive/warning/…). Views use THESE.
//   • Surfaces  — adaptive tints washed over the window's frosted material.
//
// `Color(light:dark:)` yields a macOS appearance-aware color, so the surface
// tints follow the system light/dark setting automatically. The semantic hues
// are fixed accent colors that read on both appearances (like system accents).

import AppKit
import SwiftUI

extension Color {
    /// 0xRRGGBB hex initializer.
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255,
            opacity: 1
        )
    }

    /// Light/dark adaptive color from hex values (macOS appearance-aware).
    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
                green: CGFloat((hex >> 8) & 0xff) / 255,
                blue: CGFloat(hex & 0xff) / 255,
                alpha: 1
            )
        })
    }
}

enum AppTheme {

    // MARK: - Palette (raw hues — do not use directly in views)
    // Source: https://coolors.co/fe5d26-f2c078-faedca-c1dbb3-7ebc89
    static let tigerFlame = Color(hex: 0xFE5D26)   // vivid orange-red
    static let sunlitClay = Color(hex: 0xF2C078)   // warm amber
    static let pearlBeige = Color(hex: 0xFAEDCA)   // cream
    static let teaGreen = Color(hex: 0xC1DBB3)     // soft green
    static let emerald = Color(hex: 0x7EBC89)      // green

    // MARK: - Semantic roles (use these in views)

    /// App-wide accent — controls, selection, links, active glyphs.
    static let accent = tigerFlame
    /// Secondary / positive — listening, granted, streaming, complete.
    static let positive = emerald
    /// Caution — approaching a limit, waiting, a missing permission.
    static let warning = sunlitClay
    /// Warning TEXT. The amber `warning` hue is too light to read as text on
    /// light backgrounds, so light mode uses a deep amber; dark mode keeps it.
    static let warningText = Color(light: 0x8A5300, dark: 0xF2C078)
    /// Alert / stop — over a limit, errors, destructive actions.
    static let danger = tigerFlame
    /// In-flight work — transcribing, downloading, indeterminate progress.
    static let progress = sunlitClay
    /// Informational categorical badges (accuracy, languages, …).
    static let info = teaGreen

    /// Amplitude-meter hues (quiet → loud): cool green up to a hot flame.
    static let meterIn = teaGreen
    static let meterOut = sunlitClay
    static let meterHot = tigerFlame

    // MARK: - Surfaces (adaptive) + cards

    static let backgroundTint = Color(light: 0xEADFDF, dark: 0x1A1617)  // warm neutral base
    static let panelTint = Color(light: 0xFDFCFB, dark: 0x322E30)       // near-white / dark warm grey

    /// Light translucent card on top of a panel.
    static func cardFrost(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.08) : Color.white.opacity(0.5)
    }
}

extension View {
    /// Tint wash for a detail panel, over the window's frosted material (set
    /// once on the window via `containerBackground(_:for: .window)`). Only the
    /// BACKGROUND extends under the transparent toolbar; the content keeps its
    /// top safe area so a nav title never overlaps it.
    func detailPanelStyle(tint: Color = AppTheme.panelTint) -> some View {
        background(TintWash(tint: tint).ignoresSafeArea())
    }
}

/// A translucent color wash over whatever material is behind it — the
/// window's behind-window frost, so the desktop still shows through.
struct TintWash: View {
    let tint: Color
    var opacity: Double = 0.35

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        tint.opacity(effectiveOpacity)
    }

    /// Dark tints need a touch more wash; light tints use the default.
    private var effectiveOpacity: Double {
        colorScheme == .dark ? min(1, opacity + 0.12) : opacity
    }
}
