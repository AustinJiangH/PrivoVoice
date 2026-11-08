// A click-to-record control for a mouse dictation trigger: one button, or a
// chord of several pressed together (e.g. Back + Middle).
//
// While recording it installs a *local* NSEvent monitor for extra mouse
// buttons (middle / side buttons — never left or right click), so the user
// presses the button(s) with the pointer over this window. Every button held
// down together is collected; the chord is committed once they're all
// released. Esc cancels. A chord that overlaps `conflict` (the other mouse
// action) is refused with a note and recording continues.

import SwiftUI
import AppKit
import PrivoVoiceKit

struct MouseChordRecorderView: View {
    @Binding var chord: MouseChord?
    /// The other mouse binding this one must not overlap — a binding so the
    /// check reads it live (see `ShortcutRecorderView.conflict`).
    var conflict: Binding<MouseChord?> = .constant(nil)
    /// What `conflict` is called, for the rejection note.
    var conflictName: String = "another action"

    @State private var recording = false
    @State private var monitor: Any?
    @State private var rejection: String?
    /// Buttons currently held, and every button pressed since the first one
    /// went down (the chord being recorded).
    @State private var down: Set<Int> = []
    @State private var pending: Set<Int> = []

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 6) {
                Button(action: toggle) {
                    HStack {
                        Image(systemName: recording ? "record.circle" : "computermouse")
                            .foregroundStyle(recording ? AppTheme.danger : .secondary)
                        if recording {
                            if pending.isEmpty {
                                Text("Press mouse button(s)…  (Esc to cancel)")
                                    .monospaced()
                            } else {
                                MouseChordBadges(chord: MouseChord(buttons: pending))
                            }
                        } else {
                            MouseChordBadges(chord: chord)
                        }
                        Spacer()
                    }
                    .frame(minWidth: 200)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.bordered)

                // Sibling control so the click clears instead of toggling recording.
                if !recording && chord != nil {
                    Button {
                        chord = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Clear mouse binding")
                }
            }
            if let rejection {
                Text(rejection)
                    .font(.caption2)
                    .foregroundStyle(AppTheme.warning)
            }
        }
        .onDisappear(perform: stop)
        // Switching away mid-record would otherwise leave every global
        // trigger suspended until the user comes back and presses Esc.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didResignActiveNotification)) { _ in stop() }
    }

    private func toggle() {
        recording ? stop() : startRecording()
    }

    private func startRecording() {
        recording = true
        rejection = nil
        down = []
        pending = []
        // Let already-bound buttons reach this window instead of firing
        // dictation (the tap would otherwise swallow them).
        HotkeyMonitor.suspend()
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.otherMouseDown, .otherMouseUp, .keyDown]) { event in
            handle(event)
            return nil   // swallow while recording
        }
    }

    private func stop() {
        if recording { HotkeyMonitor.resume() }
        recording = false
        down = []
        pending = []
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .keyDown:
            if event.keyCode == 53 { stop() }   // Escape cancels
        case .otherMouseDown:
            guard event.buttonNumber >= MouseChord.firstAssignable else { return }
            down.insert(event.buttonNumber)
            pending.insert(event.buttonNumber)
        case .otherMouseUp:
            down.remove(event.buttonNumber)
            // Commit once every button of the chord has been let go.
            guard down.isEmpty, !pending.isEmpty else { return }
            let candidate = MouseChord(buttons: pending)
            pending = []
            if candidate.conflicts(with: conflict.wrappedValue) {
                rejection = "Overlaps \(conflictName) — pick different button(s)."
                return
            }
            rejection = nil
            chord = candidate
            stop()
        default:
            break
        }
    }
}

/// Key-cap badges naming the bound mouse button(s) — "[Back] + [Middle]" — or
/// "Not set", matching `KeyComboBadges`.
struct MouseChordBadges: View {
    let chord: MouseChord?

    var body: some View {
        if let chord {
            HStack(spacing: 5) {
                ForEach(Array(chord.badgeComponents.enumerated()), id: \.offset) { index, token in
                    if index > 0 {
                        Text("+")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    KeyCap(text: token, muted: false)
                }
            }
        } else {
            KeyCap(text: "Not set", muted: true)
        }
    }
}
