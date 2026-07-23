// Delivers the finished transcript to wherever the cursor is, by putting it on
// the pasteboard and synthesizing ⌘V. Because the app is a non-activating
// accessory, the previously-focused app stays key and receives the paste.
//
// Requires Accessibility permission to post the key events.

import AppKit
import CoreGraphics

/// Main-actor isolated: all pasteboard + synthetic-event work happens on the
/// main thread, which also keeps the non-Sendable `NSPasteboardItem` snapshot
/// from crossing an isolation boundary.
@MainActor
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
        // Snapshot ALL types (not just string) so a non-text clipboard — image,
        // files, RTF — is restored intact when auto-copy is off.
        let restore = keepInClipboard ? nil : snapshot(pb)

        pb.clearContents()
        pb.setString(text, forType: .string)

        // Let the pasteboard settle, then paste. Restore the prior clipboard once
        // the paste has been consumed (best-effort: a very slow target app could
        // still read late).
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            postPaste()
            if let restore {
                try? await Task.sleep(nanoseconds: 400_000_000)
                pb.clearContents()
                if !restore.isEmpty { pb.writeObjects(restore) }
            }
        }
    }

    /// Deep-copy the current pasteboard's items across every type so they can be
    /// re-written after the paste.
    private static func snapshot(_ pb: NSPasteboard) -> [NSPasteboardItem] {
        (pb.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
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
