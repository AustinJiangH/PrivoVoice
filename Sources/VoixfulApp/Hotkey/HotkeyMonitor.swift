// Global push-to-talk via a CGEventTap.
//
// Watches key + modifier events session-wide (listen-only, so it never swallows
// the key). Fires `onPress` when the configured chord engages and `onRelease`
// when it disengages, both on the main actor (the tap runs on the main run loop).
//
// Two SEPARATE TCC permissions are involved — this is the usual reason
// push-to-talk "does nothing":
//   • Input Monitoring — REQUIRED for a keyboard event tap to receive events.
//     Without it `CGEvent.tapCreate` returns nil and nothing ever fires.
//   • Accessibility    — required to synthesize the ⌘V paste (`CGEvent.post`).
// `start()` requests both (prompting); `retry()` installs the tap once the user
// grants permission — called on app re-activation, so no relaunch is needed.

import AppKit
import CoreGraphics
import IOKit.hid
import VoixfulKit

@MainActor
final class HotkeyMonitor {
    var onPress: (@MainActor () -> Void)?
    var onRelease: (@MainActor () -> Void)?
    /// Fired for every global key event the tap sees (a liveness diagnostic).
    var onActivity: (@MainActor () -> Void)?
    /// Fired when permission/activation state changes (so the UI can update).
    var onPermissionChange: (@MainActor () -> Void)?

    private let settings: AppSettings
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var isDown = false
    private var retryTimer: Timer?

    /// Tap installed and receiving events (Input Monitoring granted).
    private(set) var isActive = false
    /// Accessibility granted — needed to post the paste keystroke.
    private(set) var canPaste = false

    init(settings: AppSettings) {
        self.settings = settings
    }

    /// Request both permissions (prompting) and install the tap if allowed.
    func start() {
        // Input Monitoring: prompts to add Voixful to the list.
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        // Accessibility: prompt (needed for paste). Literal key avoids the
        // non-Sendable global `kAXTrustedCheckOptionPrompt` under Swift 6.
        canPaste = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        installTap()
        scheduleRetry()
    }

    /// Re-check permissions (no prompt) and install the tap if it isn't yet.
    func retry() {
        if !canPaste { canPaste = AXIsProcessTrusted() }
        installTap()
        scheduleRetry()
    }

    /// Poll for permission until the tap is live. A menu-bar (`LSUIElement`) app
    /// can't rely on `applicationDidBecomeActive` firing after the user grants in
    /// System Settings, so we check on a timer instead of only on focus.
    private func scheduleRetry() {
        if isActive {
            retryTimer?.invalidate(); retryTimer = nil
            onPermissionChange?()
            return
        }
        guard retryTimer == nil else { return }
        retryTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if !self.canPaste { self.canPaste = AXIsProcessTrusted() }
                self.installTap()
                self.onPermissionChange?()
                if self.isActive { self.retryTimer?.invalidate(); self.retryTimer = nil }
            }
        }
    }

    /// The keyboard tap only succeeds once Input Monitoring is granted.
    private func installTap() {
        guard !isActive else { return }
        guard IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted else {
            return
        }

        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                if let refcon {
                    let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                    // The tap runs on the main run loop, so we are on the main thread.
                    MainActor.assumeIsolated {
                        monitor.handle(type: type, event: event)
                    }
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: refcon
        ) else {
            return
        }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        isActive = true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }

    // MARK: Matching

    private func handle(type: CGEventType, event: CGEvent) {
        // The system disables a tap if a callback runs too long or during an
        // input storm, delivering one of these event types. Re-enable it —
        // otherwise push-to-talk silently dies for the rest of the session.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }

        // Liveness: any event here proves Input Monitoring is working.
        onActivity?()

        let combo = settings.hotkey
        guard !combo.isEmpty else { return }
        let flags = event.flags

        if combo.isModifierOnly {
            transition(to: satisfies(flags, combo.modifiers))
            return
        }

        // Key-code chord: match on keyDown / keyUp of the exact key.
        guard let keyCode = combo.keyCode else { return }
        let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        switch type {
        case .keyDown where code == keyCode:
            if satisfies(flags, combo.modifiers) { transition(to: true) }
        case .keyUp where code == keyCode:
            transition(to: false)
        default:
            break
        }
    }

    /// Exact-match the four chord modifiers (⌘⌥⌃⇧) so extra held modifiers don't
    /// over-trigger the chord, while still requiring any `fn` in the chord to be
    /// present. `fn` is left out of the strict comparison because macOS also sets
    /// it for the arrow/F-key group, which would otherwise break key-code chords.
    private func satisfies(_ flags: CGEventFlags, _ mods: KeyModifiers) -> Bool {
        let required = requiredFlags(mods)
        guard flags.contains(required) else { return false }
        let chord: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
        return flags.intersection(chord) == required.intersection(chord)
    }

    /// Fire the press/release edge exactly once.
    private func transition(to engaged: Bool) {
        if engaged, !isDown {
            isDown = true
            onPress?()
        } else if !engaged, isDown {
            isDown = false
            onRelease?()
        }
    }

    /// Map our modifier set to a combined CGEvent flag mask.
    private func requiredFlags(_ mods: KeyModifiers) -> CGEventFlags {
        var out: CGEventFlags = []
        if mods.contains(.command) { out.insert(.maskCommand) }
        if mods.contains(.option) { out.insert(.maskAlternate) }
        if mods.contains(.control) { out.insert(.maskControl) }
        if mods.contains(.shift) { out.insert(.maskShift) }
        if mods.contains(.function) { out.insert(.maskSecondaryFn) }
        return out
    }
}
