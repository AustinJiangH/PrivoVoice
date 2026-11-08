// Global dictation triggers via a CONSUMING CGEventTap — the same approach Handy uses.
//
// The key insight: a consuming tap (`kCGEventTapOptionDefault`) requires
// ACCESSIBILITY, not Input Monitoring — only the passive `.listenOnly` tap needs
// Input Monitoring. Since we already need Accessibility to paste, this costs no
// extra permission, works with ANY key (including `fn`+Space and bare keys), and
// CONSUMES the trigger so it doesn't type while you dictate.
//
// Four optional triggers share the tap: a keyboard push-to-talk chord, a
// keyboard toggle chord, and the same pair on extra mouse buttons (middle /
// side buttons). Push-to-talk records while held; toggle starts on one press
// and stops on the next. The tap reads the bindings from `settings` live on
// each event, so changing a shortcut takes effect immediately with no
// re-registration.

import AppKit
import CoreGraphics
import PrivoVoiceKit

@MainActor
final class HotkeyMonitor {
    /// The four bindable triggers.
    enum Trigger {
        case keyboardPushToTalk, keyboardToggle, mousePushToTalk, mouseToggle

        var isToggle: Bool { self == .keyboardToggle || self == .mouseToggle }
    }

    var onStart: (@MainActor () -> Void)?
    var onStop: (@MainActor () -> Void)?
    /// Whether a recording session is live right now. Lets a toggle press
    /// resync after a session ended without us (start failed, cancelled), so
    /// the next press starts instead of being swallowed as a no-op stop.
    var isRecording: (@MainActor () -> Bool)?
    var onPermissionChange: (@MainActor () -> Void)?

    /// Set while a shortcut recorder in the UI is capturing, so pressing an
    /// existing binding records it instead of starting dictation (and isn't
    /// swallowed before the recorder sees it).
    static var isSuspended = false

    private let settings: AppSettings
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var retryTimer: Timer?

    /// Triggers physically held right now — edge detection, auto-repeat
    /// suppression, and knowing which key-up / mouse-up to consume.
    private var held: Set<Trigger> = []
    /// Whether we started a session that hasn't been stopped yet.
    private var sessionOn = false
    /// The push-to-talk trigger that owns the live session (its release
    /// stops it), or `nil` for a toggle-started session.
    private var holdOwner: Trigger?

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
        // Detect Accessibility revoked at runtime: the tap is dead but our flag
        // says active. Tear it down so it can re-arm and the UI reflects it.
        if isActive, !AXIsProcessTrusted() { removeTap() }
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
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.otherMouseDown.rawValue) |
            (1 << CGEventType.otherMouseUp.rawValue) |
            (1 << CGEventType.otherMouseDragged.rawValue)

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
        releaseAll()
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

    /// Returns `true` to consume (swallow) the event so its key doesn't type
    /// (or its mouse button doesn't navigate).
    private func handle(type: CGEventType, event: CGEvent) -> Bool {
        // Re-enable if the system disabled the tap (slow callback / input storm).
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            // A trigger's release may have been missed during the disabled
            // window — don't strand a held session.
            releaseAll()
            return false
        }
        guard !Self.isSuspended else { return false }

        switch type {
        case .otherMouseDown, .otherMouseUp, .otherMouseDragged:
            return handleMouse(type: type, event: event)
        default:
            return handleKey(type: type, event: event)
        }
    }

    private func handleKey(type: CGEventType, event: CGEvent) -> Bool {
        let flags = event.flags
        let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        var consume = false

        for (trigger, combo) in [(Trigger.keyboardPushToTalk, settings.hotkey),
                                 (Trigger.keyboardToggle, settings.toggleHotkey)] {
            guard !combo.isEmpty, combo.isValidGlobalShortcut else { continue }

            if combo.isModifierOnly {
                // fn / modifier-only: fire on the modifier engaging/disengaging.
                // Use a subset (not exact) test so tapping another modifier while
                // the trigger is held doesn't spuriously stop/restart. Don't
                // consume — modifiers don't type, and swallowing flagsChanged
                // would corrupt global modifier state.
                if type == .flagsChanged {
                    setHeld(trigger, flags.contains(requiredFlags(combo.modifiers)))
                }
                continue
            }

            guard let keyCode = combo.keyCode, code == keyCode else { continue }
            switch type {
            case .keyDown:
                // Auto-repeat of a held trigger: swallow it, don't re-fire.
                if held.contains(trigger) {
                    consume = true
                } else if satisfies(flags, combo.modifiers) {
                    setHeld(trigger, true)
                    consume = true   // CONSUME → the trigger key doesn't type
                }
            case .keyUp:
                if held.contains(trigger) {
                    setHeld(trigger, false)
                    consume = true   // consume the matching key-up too
                }
            default:
                break
            }
        }
        return consume
    }

    private func handleMouse(type: CGEventType, event: CGEvent) -> Bool {
        let number = Int(event.getIntegerValueField(.mouseEventButtonNumber))
        var consume = false

        for (trigger, button) in [(Trigger.mousePushToTalk, settings.mousePushToTalkButton),
                                  (Trigger.mouseToggle, settings.mouseToggleButton)] {
            guard let button, button.isAssignable, button.number == number else { continue }
            switch type {
            case .otherMouseDown:
                setHeld(trigger, true)
                consume = true
            case .otherMouseUp:
                // Only swallow the up whose down we swallowed (a binding set
                // mid-press shouldn't eat a stray up the app is waiting for).
                if held.contains(trigger) {
                    setHeld(trigger, false)
                    consume = true
                }
            default:
                // Drags with the bound button held belong to the press we ate.
                consume = held.contains(trigger)
            }
        }
        return consume
    }

    // MARK: Session state

    /// Edge-detect a trigger going down/up and drive the session.
    private func setHeld(_ trigger: Trigger, _ down: Bool) {
        if down {
            guard held.insert(trigger).inserted else { return }
            pressed(trigger)
        } else {
            guard held.remove(trigger) != nil else { return }
            if trigger == holdOwner { endSession() }
        }
    }

    private func pressed(_ trigger: Trigger) {
        // Resync if the session ended without us (failed start, cancel, …).
        if sessionOn, let isRecording, !isRecording() {
            sessionOn = false
            holdOwner = nil
        }
        if trigger.isToggle {
            // Toggle: start when idle; stop any live session (including one a
            // push-to-talk trigger is still holding).
            sessionOn ? endSession() : beginSession(owner: nil)
        } else if !sessionOn {
            // Push-to-talk while a session is already live is a no-op; its
            // release then won't stop a session it didn't start.
            beginSession(owner: trigger)
        }
    }

    /// Defer the (possibly slow) start/stop off the tap callback so it returns
    /// immediately and the tap stays responsive.
    private func beginSession(owner: Trigger?) {
        sessionOn = true
        holdOwner = owner
        let cb = onStart
        Task { @MainActor in cb?() }
    }

    private func endSession() {
        guard sessionOn else { return }
        sessionOn = false
        holdOwner = nil
        let cb = onStop
        Task { @MainActor in cb?() }
    }

    /// Forget every held trigger; stop a push-to-talk session whose release
    /// we can no longer observe. A toggle session keeps running — it doesn't
    /// depend on anything being held.
    private func releaseAll() {
        if holdOwner != nil { endSession() }
        held.removeAll()
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
