// Delivers the finished transcript to wherever the cursor is, by putting it on
// the pasteboard and synthesizing ⌘V. Because the app is a non-activating
// accessory, the previously-focused app stays key and receives the paste.
//
// Requires Accessibility permission to post the key events.

import AppKit
import CoreGraphics

enum Paster {
    /// Virtual key code for the `v` key on a US layout.
    private static let vKeyCode: CGKeyCode = 0x09

    /// Put `text` on the clipboard and paste it at the cursor.
    ///
    /// - Parameter keepInClipboard: when `false`, the prior clipboard contents
    ///   are restored shortly after pasting (so a transcript doesn't clobber the
    ///   user's clipboard when auto-copy is off).
    static func deliver(_ text: String, keepInClipboard: Bool) {
        guard !text.isEmpty else { return }
        let pb = NSPasteboard.general
        let previous = keepInClipboard ? nil : pb.string(forType: .string)

        pb.clearContents()
        pb.setString(text, forType: .string)

        // Let the pasteboard settle, then paste.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            postPaste()
            if let previous {
                // Restore the user's clipboard once the paste has been consumed.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    pb.clearContents()
                    pb.setString(previous, forType: .string)
                }
            }
        }
    }

    /// Copy without pasting.
    static func copyToClipboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    private static func postPaste() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true)
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
