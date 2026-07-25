// Shared visual theme, ported from the Voxtine app so PrivoVoice reads with the
// same warm palette and light/dark behavior.
//
// Three layers, used top-down:
//   • Palette   — raw hues (below). Do NOT reference these in feature views.
//   • Semantic  — named roles (accent/positive/warning/…). Views use THESE.
//   • Surfaces  — adaptive tints + frosted materials for backgrounds.
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
    /// Sidebar wash — clay (per design). Applied at low opacity over the frosted
    /// `.sidebar` material, so it reads as a soft amber tint in both appearances.
    static let sidebarTint = sunlitClay
    static let panelTint = Color(light: 0xFDFCFB, dark: 0x322E30)       // near-white / dark warm grey

    /// Light translucent card on top of a panel.
    static func cardFrost(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.08) : Color.white.opacity(0.5)
    }
}

extension View {
    /// Tinted frosted background for a detail panel. Only the BACKGROUND extends
    /// under the transparent title bar / toolbar; the content keeps its top safe
    /// area so a nav-title / search header never overlaps it (our panels live in
    /// a NavigationSplitView with a fixed header, unlike Voxtine's HSplitView).
    func detailPanelStyle(tint: Color = AppTheme.panelTint) -> some View {
        background(TintedMaterial(tint: tint).ignoresSafeArea())
    }
}

/// A behind-window frosted backdrop (samples the desktop) with a color tint
/// washed over it. Requires the window to be non-opaque.
struct TintedMaterial: View {
    let tint: Color
    var material: NSVisualEffectView.Material = .underWindowBackground
    var opacity: Double = 0.35

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VisualEffectView(material: material)
            .overlay(tint.opacity(effectiveOpacity))
    }

    /// Dark tints need a touch more wash; light tints use the default.
    private var effectiveOpacity: Double {
        colorScheme == .dark ? min(1, opacity + 0.12) : opacity
    }
}

/// AppKit `NSVisualEffectView` with **behind-window** blending so the frost
/// samples the desktop / windows behind ours.
struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .underWindowBackground
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blending
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blending
        view.state = .active
    }
}
