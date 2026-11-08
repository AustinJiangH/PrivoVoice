// A click-to-record control for a mouse-button dictation trigger.
//
// While recording it installs a *local* NSEvent monitor for extra mouse
// buttons (middle / side buttons — never left or right click), so the user
// presses the button with the pointer over this window. Esc cancels. A button
// already bound to `conflict` (the other mouse action) is refused with a note
// and recording continues.

import SwiftUI
import AppKit
import PrivoVoiceKit

struct MouseButtonRecorderView: View {
    @Binding var button: MouseButton?
    /// The other mouse binding this one must not reuse.
    var conflict: MouseButton?
    /// What `conflict` is called, for the rejection note.
    var conflictName: String = "another action"

    @State private var recording = false
    @State private var monitor: Any?
    @State private var rejection: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 6) {
                Button(action: toggle) {
                    HStack {
                        Image(systemName: recording ? "record.circle" : "computermouse")
                            .foregroundStyle(recording ? AppTheme.danger : .secondary)
                        if recording {
                            Text("Press a mouse button…  (Esc to cancel)")
                                .monospaced()
                        } else {
                            MouseButtonBadge(button: button)
                        }
                        Spacer()
                    }
                    .frame(minWidth: 200)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.bordered)

                // Sibling control so the click clears instead of toggling recording.
                if !recording && button != nil {
                    Button {
                        button = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Clear mouse button")
                }
            }
            if let rejection {
                Text(rejection)
                    .font(.caption2)
                    .foregroundStyle(AppTheme.warning)
            }
        }
        .onDisappear(perform: stop)
    }

    private func toggle() {
        recording ? stop() : startRecording()
    }

    private func startRecording() {
        recording = true
        rejection = nil
        // Let an already-bound button reach this window instead of firing
        // dictation (the tap would otherwise swallow it).
        HotkeyMonitor.isSuspended = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.otherMouseDown, .keyDown]) { event in
            handle(event)
            return nil   // swallow while recording
        }
    }

    private func stop() {
        if recording { HotkeyMonitor.isSuspended = false }
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .keyDown:
            if event.keyCode == 53 { stop() }   // Escape cancels
        case .otherMouseDown:
            let candidate = MouseButton(number: event.buttonNumber)
            guard candidate.isAssignable else { return }
            if candidate == conflict {
                rejection = "Already used by \(conflictName) — pick a different button."
                return
            }
            rejection = nil
            button = candidate
            stop()
        default:
            break
        }
    }
}

/// A single key-cap style badge naming the bound mouse button (or "Not set"),
/// matching `KeyComboBadges`.
struct MouseButtonBadge: View {
    let button: MouseButton?

    var body: some View {
        Text(button?.displayName ?? "Not set")
            .font(.caption.monospaced().weight(.medium))
            .foregroundStyle(button == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.quaternary)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color.secondary.opacity(0.22), lineWidth: 1)))
    }
}
