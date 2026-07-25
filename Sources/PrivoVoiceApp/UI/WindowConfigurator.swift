// Makes the hosting NSWindow non-opaque with a clear background and a
// transparent, full-size-content title bar, so the tinted frosted material
// samples the desktop behind the window and app content fills to the top edge.
// Ported from the Voxtine app so PrivoVoice matches its window treatment.

import SwiftUI
import AppKit

struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowConfigHost {
        WindowConfigHost()
    }

    func updateNSView(_ nsView: WindowConfigHost, context: Context) {
        nsView.configureWindow()
    }

    /// Host view that re-applies window chrome hiding whenever the view attaches
    /// to a window or lays out — macOS can re-insert title-bar decoration views
    /// after the first pass.
    final class WindowConfigHost: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configureWindow()
        }

        override func layout() {
            super.layout()
            hideTitlebarChromeIfNeeded()
        }

        func configureWindow() {
            guard let window else { return }
            window.isOpaque = false
            window.backgroundColor = .clear
            window.styleMask.insert(.fullSizeContentView)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            hideTitlebarChromeIfNeeded()
        }

        private func hideTitlebarChromeIfNeeded() {
            guard let themeFrame = window?.contentView?.superview else { return }
            Self.hideTitlebarChrome(themeFrame)
        }

        /// Hide the title-bar background + decoration views (which paint the grey
        /// strip). Traffic-light widgets are separate and untouched.
        private static func hideTitlebarChrome(_ view: NSView) {
            for sub in view.subviews {
                let name = String(describing: type(of: sub))
                if name.contains("TitlebarBackground") || name.contains("TitlebarDecoration") {
                    sub.isHidden = true
                }
                hideTitlebarChrome(sub)
            }
        }
    }
}
