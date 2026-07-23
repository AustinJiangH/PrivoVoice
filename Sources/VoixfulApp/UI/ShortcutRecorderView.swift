// A click-to-record control for the push-to-talk chord.
//
// While recording it installs a *local* NSEvent monitor (works without any
// special permission because our window is focused), captures the next key or
// modifier-only chord, and writes it back through the binding. Press a key with
// optional modifiers for a key chord; press-and-release modifiers alone (e.g.
// `fn`) for a modifier-only chord. Esc cancels, Delete clears.

import SwiftUI
import AppKit
import VoixfulKit

struct ShortcutRecorderView: View {
    @Binding var combo: KeyCombo

    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            Button(action: toggle) {
                HStack {
                    Image(systemName: recording ? "record.circle" : "keyboard")
                        .foregroundStyle(recording ? .red : .secondary)
                    Text(recording ? "Press keys…  (Esc to cancel)" : combo.displayString)
                        .monospaced()
                    Spacer()
                }
                .frame(minWidth: 200)
                .contentShape(Rectangle())
            }
            .buttonStyle(.bordered)

            // Sibling control, not nested in the recorder button's label, so the
            // click reliably clears instead of toggling recording.
            if !recording && !combo.isEmpty {
                Button {
                    combo = KeyCombo(keyCode: nil, modifiers: [])
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Clear shortcut")
            }
        }
        .onDisappear(perform: stop)
    }

    private func toggle() {
        recording ? stop() : startRecording()
    }

    private func startRecording() {
        recording = true
        // Only key-down: the global hotkey is registered via Carbon, which needs
        // a key code (plus optional ⌘⌥⌃⇧). Pure-modifier chords aren't captured.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            handle(event)
            return nil   // swallow while recording
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func handle(_ event: NSEvent) {
        if event.keyCode == 53 {   // Escape cancels
            stop()
            return
        }
        var mods = Self.modifiers(from: event.modifierFlags)
        if event.keyCode == 51 && mods.isEmpty {   // Delete clears
            combo = KeyCombo(keyCode: nil, modifiers: [])
            stop()
            return
        }
        // `fn` has no Carbon equivalent and can't be part of a registered hotkey.
        mods.remove(.function)
        let candidate = KeyCombo(
            keyCode: event.keyCode,
            keyLabel: Self.label(for: event),
            modifiers: mods)
        // Only accept a chord that can actually be registered — a modifier + key
        // (e.g. ⌥Space) or a function key. A bare key like Space is ignored so we
        // don't bind a hotkey that fires on every keystroke.
        guard candidate.isRegisterableHotkey else { return }
        combo = candidate
        stop()
    }

    // MARK: Mapping

    static func modifiers(from flags: NSEvent.ModifierFlags) -> KeyModifiers {
        var m: KeyModifiers = []
        if flags.contains(.command) { m.insert(.command) }
        if flags.contains(.option) { m.insert(.option) }
        if flags.contains(.control) { m.insert(.control) }
        if flags.contains(.shift) { m.insert(.shift) }
        if flags.contains(.function) { m.insert(.function) }
        return m
    }

    /// Readable label for the pressed key.
    static func label(for event: NSEvent) -> String {
        if let named = specialKeys[event.keyCode] { return named }
        if let chars = event.charactersIgnoringModifiers, !chars.isEmpty,
           chars.first.map({ $0.isLetter || $0.isNumber || $0.isPunctuation || $0.isSymbol }) == true {
            return chars.uppercased()
        }
        return "Key \(event.keyCode)"
    }

    private static let specialKeys: [UInt16: String] = [
        49: "Space", 36: "Return", 48: "Tab", 53: "Esc", 51: "Delete",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]
}
