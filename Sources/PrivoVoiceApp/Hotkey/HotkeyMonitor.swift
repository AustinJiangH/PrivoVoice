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
import Observation
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

    /// Number of shortcut recorders in the UI currently capturing. While any
    /// are, new presses pass through so pressing an existing binding records
    /// it instead of starting dictation (and isn't swallowed before the
    /// recorder sees it). Releases are still tracked so a trigger held when
    /// recording began can't strand a session. A count, not a flag, so two
    /// recorders can't re-enable each other's suspension.
    private static var suspendCount = 0
    static var isSuspended: Bool { suspendCount > 0 }
    static func suspend() { suspendCount += 1 }
    static func resume() { suspendCount = max(0, suspendCount - 1) }

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
    /// A modifier-only toggle chord is a *tap*: it fires on release, and only
    /// if nothing else was pressed while it was held — so fn+← or ⌃⌥⌘T don't
    /// latch an open mic.
    private var modifierToggleDown = false
    private var modifierToggleClean = false
    /// Whether the installed tap listens to extra mouse buttons. Only true
    /// while a mouse binding exists, so middle/side-button drags system-wide
    /// don't route through our main-thread callback for nothing.
    private var tapHasMouse = false

    /// Tap installed — implies Accessibility is granted (which also enables paste).
    private(set) var isActive = false
    /// Accessibility is the single permission; the hotkey tap and paste share it.
    var canPaste: Bool { isActive }

    init(settings: AppSettings) {
        self.settings = settings
        observeMouseBindings()
    }

    private var wantsMouse: Bool {
        settings.mousePushToTalkButton != nil || settings.mouseToggleButton != nil
    }

    /// Reinstall the tap with/without the mouse events when the mouse bindings
    /// are set or cleared (Observation fires once per change, so re-arm).
    private func observeMouseBindings() {
        withObservationTracking {
            _ = wantsMouse
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if self.tap != nil, self.wantsMouse != self.tapHasMouse {
                    self.removeTap()
                    self.installTap()
                }
                self.observeMouseBindings()
            }
        }
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

        let withMouse = wantsMouse
        var mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)
        if withMouse {
            mask |= (1 << CGEventType.otherMouseDown.rawValue) |
                (1 << CGEventType.otherMouseUp.rawValue) |
                (1 << CGEventType.otherMouseDragged.rawValue)
        }

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
        tapHasMouse = withMouse
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
        // Auto-repeat is never a fresh press — even if `held` was reset by a
        // tap timeout while the key stayed down.
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        if type == .keyDown { modifierToggleClean = false }

        // Never let the toggle chord fire alongside the push-to-talk chord it
        // collides with (the UI refuses this; guard any other writer too).
        let toggle = settings.toggleHotkey.conflicts(with: settings.hotkey)
            ? KeyCombo.unset : settings.toggleHotkey
        var consume = false

        for (trigger, combo) in [(Trigger.keyboardPushToTalk, settings.hotkey),
                                 (Trigger.keyboardToggle, toggle)] {
            guard !combo.isEmpty, combo.isValidGlobalShortcut else { continue }

            if combo.isModifierOnly {
                // fn / modifier-only. Don't consume — modifiers don't type, and
                // swallowing flagsChanged would corrupt global modifier state.
                guard type == .flagsChanged else { continue }
                // Subset (not exact) test so tapping another modifier while the
                // trigger is held doesn't spuriously stop/restart.
                let engaged = flags.contains(requiredFlags(combo.modifiers))
                if trigger.isToggle {
                    handleModifierToggle(engaged: engaged, flags: flags, combo: combo)
                } else if !engaged || !Self.isSuspended {
                    setHeld(trigger, engaged)
                }
                continue
            }

            guard let keyCode = combo.keyCode, code == keyCode else { continue }
            switch type {
            case .keyDown:
                if held.contains(trigger) || isRepeat {
                    // Swallow the repeat of a trigger we own; don't re-fire.
                    consume = held.contains(trigger)
                } else if !Self.isSuspended, satisfies(flags, combo.modifiers) {
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

    /// Fire a modifier-only toggle on a clean tap: engaged, then released with
    /// no key pressed and no extra ⌘⌥⌃⇧ added in between.
    private func handleModifierToggle(engaged: Bool, flags: CGEventFlags, combo: KeyCombo) {
        let chord: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
        let required = requiredFlags(combo.modifiers)
        if engaged {
            if !modifierToggleDown {
                modifierToggleDown = true
                modifierToggleClean = true
            }
            if !flags.intersection(chord).subtracting(required).isEmpty {
                modifierToggleClean = false
            }
        } else if modifierToggleDown {
            modifierToggleDown = false
            if modifierToggleClean, !Self.isSuspended {
                setHeld(.keyboardToggle, true)
                setHeld(.keyboardToggle, false)
            }
        }
    }

    private func handleMouse(type: CGEventType, event: CGEvent) -> Bool {
        let number = Int(event.getIntegerValueField(.mouseEventButtonNumber))
        var consume = false

        // As with the keyboard pair, a toggle sharing the push-to-talk button
        // is ignored rather than firing both at once.
        let ptt = settings.mousePushToTalkButton
        let toggle = settings.mouseToggleButton?.conflicts(with: ptt) == true
            ? nil : settings.mouseToggleButton

        for (trigger, button) in [(Trigger.mousePushToTalk, ptt), (Trigger.mouseToggle, toggle)] {
            guard let button, button.isAssignable, button.number == number else { continue }
            switch type {
            case .otherMouseDown:
                // Exactly the bound ⌘⌥⌃⇧ must be held, so e.g. ⌥+Back fires
                // while a bare Back still navigates.
                guard !Self.isSuspended, satisfies(event.flags, button.modifiers) else { continue }
                setHeld(trigger, true)
                consume = true
            case .otherMouseUp:
                // Only swallow the up whose down we swallowed (a binding set
                // mid-press shouldn't eat a stray up the app is waiting for).
                // No modifier check: letting go of ⌥ before the button must
                // still end push-to-talk.
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
        modifierToggleDown = false
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
