// Global push-to-talk via a CONSUMING CGEventTap — the same approach Handy uses.
//
// The key insight: a consuming tap (`kCGEventTapOptionDefault`) requires
// ACCESSIBILITY, not Input Monitoring — only the passive `.listenOnly` tap needs
// Input Monitoring. Since we already need Accessibility to paste, this costs no
// extra permission, works with ANY key (including `fn`+Space and bare keys), and
// CONSUMES the trigger so it doesn't type while you dictate.
//
// The tap reads `settings.hotkey` live on each event, so changing the shortcut
// takes effect immediately with no re-registration.

import AppKit
import CoreGraphics
import VoixfulKit

@MainActor
final class HotkeyMonitor {
    var onPress: (@MainActor () -> Void)?
    var onRelease: (@MainActor () -> Void)?
    var onPermissionChange: (@MainActor () -> Void)?

    private let settings: AppSettings
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var isDown = false
    private var retryTimer: Timer?

    /// Tap installed — implies Accessibility is granted (which also enables paste).
    private(set) var isActive = false
    /// Accessibility is the single permission; the hotkey tap and paste share it.
    var canPaste: Bool { isActive }

    init(settings: AppSettings) {
        self.settings = settings
    }

    func start() {
        // Prompt for Accessibility — covers both the consuming tap and the paste.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        installTap()
        scheduleRetry()
        onPermissionChange?()
    }

    /// Install the tap if permission was just granted (called on app focus).
    func refresh() {
        installTap()
        scheduleRetry()
        onPermissionChange?()
    }

    func stop() {
        removeTap()
        retryTimer?.invalidate()
        retryTimer = nil
    }

    // MARK: Tap lifecycle

    private func installTap() {
        guard tap == nil else { return }
        // A consuming tap needs the process trusted for Accessibility.
        guard AXIsProcessTrusted() else { isActive = false; return }

        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,          // consuming: needs Accessibility, can swallow keys
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                // The tap runs on the main run loop. `handle` returns whether to
                // consume; build the Unmanaged here (CGEvent isn't Sendable, so it
                // can't cross the assumeIsolated boundary).
                let consume = MainActor.assumeIsolated { monitor.handle(type: type, event: event) }
                return consume ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: refcon
        ) else {
            isActive = false
            return
        }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        isActive = true
    }

    private func removeTap() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        isActive = false
        isDown = false
    }

    /// Poll for Accessibility until the tap installs — a menu-bar app can't rely
    /// on `applicationDidBecomeActive` firing after the user grants it.
    private func scheduleRetry() {
        if isActive { retryTimer?.invalidate(); retryTimer = nil; return }
        guard retryTimer == nil else { return }
        retryTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.installTap()
                self.onPermissionChange?()
                if self.isActive { self.retryTimer?.invalidate(); self.retryTimer = nil }
            }
        }
    }

    // MARK: Matching

    /// Returns `true` to consume (swallow) the event so its key doesn't type.
    private func handle(type: CGEventType, event: CGEvent) -> Bool {
        // Re-enable if the system disabled the tap (slow callback / input storm).
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }

        let combo = settings.hotkey
        guard !combo.isEmpty else { return false }
        let flags = event.flags

        if combo.isModifierOnly {
            // fn / modifier-only: fire on the modifier engaging/disengaging.
            // Don't consume — modifier keys don't type, and swallowing a
            // flagsChanged would corrupt global modifier state.
            if type == .flagsChanged {
                transition(to: satisfies(flags, combo.modifiers))
            }
            return false
        }

        guard let keyCode = combo.keyCode else { return false }
        let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        switch type {
        case .keyDown where code == keyCode:
            if satisfies(flags, combo.modifiers) {
                transition(to: true)
                return true   // CONSUME → the trigger key doesn't type
            }
            return false
        case .keyUp where code == keyCode:
            if isDown {
                transition(to: false)
                return true   // consume the matching key-up too
            }
            return false
        default:
            return false
        }
    }

    /// Edge-detect, and defer the (possibly slow) start/stop off the tap callback
    /// so it returns immediately and the tap stays responsive.
    private func transition(to engaged: Bool) {
        if engaged, !isDown {
            isDown = true
            let cb = onPress
            Task { @MainActor in cb?() }
        } else if !engaged, isDown {
            isDown = false
            let cb = onRelease
            Task { @MainActor in cb?() }
        }
    }

    /// Exact-match the ⌘⌥⌃⇧ modifiers (so extra held modifiers don't over-trigger)
    /// while requiring any `fn` in the chord to be present.
    private func satisfies(_ flags: CGEventFlags, _ mods: KeyModifiers) -> Bool {
        let required = requiredFlags(mods)
        guard flags.contains(required) else { return false }
        let chord: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
        return flags.intersection(chord) == required.intersection(chord)
    }

    private func requiredFlags(_ mods: KeyModifiers) -> CGEventFlags {
        var flags: CGEventFlags = []
        if mods.contains(.command) { flags.insert(.maskCommand) }
        if mods.contains(.option) { flags.insert(.maskAlternate) }
        if mods.contains(.control) { flags.insert(.maskControl) }
        if mods.contains(.shift) { flags.insert(.maskShift) }
        if mods.contains(.function) { flags.insert(.maskSecondaryFn) }
        return flags
    }
}
