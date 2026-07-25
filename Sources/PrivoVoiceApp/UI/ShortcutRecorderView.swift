// A click-to-record control for the push-to-talk chord.
//
// While recording it installs a *local* NSEvent monitor (works without any
// special permission because our window is focused), captures the next key or
// modifier-only chord, and writes it back through the binding. Press a key with
// optional modifiers for a key chord; press-and-release modifiers alone (e.g.
// `fn`) for a modifier-only chord. Esc cancels, Delete clears.

import SwiftUI
import AppKit
import PrivoVoiceKit

struct ShortcutRecorderView: View {
    @Binding var combo: KeyCombo

    @State private var recording = false
    @State private var monitor: Any?
    @State private var pendingModifiers: KeyModifiers = []

    var body: some View {
        HStack(spacing: 6) {
            Button(action: toggle) {
                HStack {
                    Image(systemName: recording ? "record.circle" : "keyboard")
                        .foregroundStyle(recording ? AppTheme.danger : .secondary)
                    if recording {
                        Text("Press keys…  (Esc to cancel)")
                            .monospaced()
                    } else {
                        KeyComboBadges(combo: combo)
                    }
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
        pendingModifiers = []
        // Capture keys AND modifier changes so `fn`/modifier-only chords can be
        // recorded too. (This local monitor is for recording only; the live
        // hotkey fires from a CGEventTap.)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            handle(event)
            return nil   // swallow while recording
        }
    }

    private func stop() {
        recording = false
        pendingModifiers = []
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func handle(_ event: NSEvent) {
        let mods = Self.modifiers(from: event.modifierFlags)

        switch event.type {
        case .keyDown:
            if event.keyCode == 53 {   // Escape cancels
                stop()
                return
            }
            if event.keyCode == 51 && mods.isEmpty {   // Delete clears
                combo = KeyCombo(keyCode: nil, modifiers: [])
                stop()
                return
            }
            let candidate = KeyCombo(
                keyCode: event.keyCode,
                keyLabel: Self.label(for: event),
                modifiers: mods)
            // Reject a bare printable key — the consuming tap would swallow it
            // system-wide. Keep recording so the user adds a modifier/function key.
            guard candidate.isValidGlobalShortcut else { return }
            combo = candidate
            stop()

        case .flagsChanged:
            // Modifiers released with no key pressed → a modifier-only chord
            // (e.g. hold `fn`). Commit the union of everything held, if valid.
            if mods.isEmpty {
                if !pendingModifiers.isEmpty {
                    let candidate = KeyCombo(keyCode: nil, keyLabel: nil, modifiers: pendingModifiers)
                    if candidate.isValidGlobalShortcut {
                        combo = candidate
                        stop()
                    } else {
                        pendingModifiers = []   // e.g. a lone ⇧ — ignore, keep recording
                    }
                }
            } else {
                pendingModifiers.formUnion(mods)
            }

        default:
            break
        }
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
