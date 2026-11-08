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
// and stops on the next. Changing a binding takes effect immediately with no
// re-registration (the tap reads a snapshot that's refreshed on every change).
//
// Threading: a consuming tap sits IN the system's input path — every key
// press (and extra-button click) system-wide waits for our callback. So the
// tap runs on its own thread (`TapEngine`), never the main thread: a busy UI
// must not be able to stall typing everywhere. The engine only matches events
// and decides what to swallow; it reports trigger edges to the main thread,
// where `HotkeyMonitor` runs the session logic (start/stop). If the system
// still keeps disabling the tap as unresponsive, the monitor backs off
// instead of re-enabling it in a loop.

import AppKit
import CoreGraphics
import Observation
import Synchronization
import PrivoVoiceKit

@MainActor
final class HotkeyMonitor {
    /// The four bindable triggers.
    enum Trigger: Sendable {
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
    /// recorders can't re-enable each other's suspension. Locked: the tap
    /// thread reads it.
    nonisolated private static let suspendCount = Mutex(0)
    nonisolated static var isSuspended: Bool { suspendCount.withLock { $0 > 0 } }
    static func suspend() { suspendCount.withLock { $0 += 1 } }
    static func resume() { suspendCount.withLock { $0 = max(0, $0 - 1) } }

    private let settings: AppSettings
    /// The running tap (and its thread), if installed.
    private var engine: TapEngine?
    private var retryTimer: Timer?

    /// Whether we started a session that hasn't been stopped yet.
    private var sessionOn = false
    /// The push-to-talk trigger that owns the live session (its release
    /// stops it), or `nil` for a toggle-started session.
    private var holdOwner: Trigger?

    /// Recent times the system disabled the tap for responding too slowly.
    private var timeouts: [Date] = []
    /// While set, the tap stays off after repeated timeouts (see `tapTimedOut`).
    private var backoffUntil: Date?
    private static let timeoutLimit = 3
    private static let timeoutWindow: TimeInterval = 10
    private static let backoffDuration: TimeInterval = 30

    /// Tap installed — implies Accessibility is granted.
    private(set) var isActive = false
    /// The tap is off for a while because the system kept disabling it.
    var isBackedOff: Bool { backoffUntil.map { $0 > Date() } ?? false }
    /// Accessibility is the single permission; the hotkey tap and paste share it.
    var canPaste: Bool { isActive || AXIsProcessTrusted() }

    init(settings: AppSettings) {
        self.settings = settings
        observeBindings()
    }

    private var bindings: TapEngine.Bindings {
        TapEngine.Bindings(hotkey: settings.hotkey, toggleHotkey: settings.toggleHotkey,
                           mousePushToTalk: settings.mousePushToTalkButton,
                           mouseToggle: settings.mouseToggleButton)
    }

    /// Hand every binding change to the tap thread, and reinstall the tap
    /// with/without the mouse events when the mouse bindings are set or
    /// cleared (Observation fires once per change, so re-arm).
    private func observeBindings() {
        withObservationTracking {
            _ = bindings
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if let engine = self.engine {
                    if engine.hasMouse != self.bindings.wantsMouse {
                        self.removeTap()
                        self.installTap()
                    } else {
                        engine.update(self.bindings)
                    }
                }
                self.observeBindings()
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
        guard engine == nil, !isBackedOff else { return }
        // A consuming tap needs the process trusted for Accessibility.
        guard AXIsProcessTrusted() else { isActive = false; return }

        let engine = TapEngine(bindings: bindings) { [weak self] report in
            // Delivered in order on the main queue.
            MainActor.assumeIsolated { self?.handle(report) }
        }
        guard engine.start() else {
            isActive = false
            return
        }
        self.engine = engine
        isActive = true
    }

    private func removeTap() {
        engine?.stop()
        engine = nil
        isActive = false
        releaseAll()
    }

    /// Poll for Accessibility until the tap installs — a menu-bar app can't rely
    /// on `applicationDidBecomeActive` firing after the user grants it. Also
    /// re-installs the tap once a timeout back-off has passed.
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

    // MARK: Reports from the tap thread

    private func handle(_ report: TapEngine.Report) {
        switch report {
        case .down(let trigger): pressed(trigger)
        case .up(let trigger): if trigger == holdOwner { endSession() }
        case .releasedAll: releaseAll()
        case .timedOut: tapTimedOut()
        }
    }

    /// The system disabled the tap because a callback was too slow. The
    /// engine re-enables it right away; if that keeps happening, take the tap
    /// down for a while so the system's input never stalls on us repeatedly
    /// (hotkeys show as inactive; the retry timer brings them back).
    private func tapTimedOut() {
        let now = Date()
        timeouts = timeouts.filter { now.timeIntervalSince($0) < Self.timeoutWindow } + [now]
        guard timeouts.count >= Self.timeoutLimit else { return }
        timeouts.removeAll()
        backoffUntil = now.addingTimeInterval(Self.backoffDuration)
        removeTap()
        scheduleRetry()
        onPermissionChange?()
    }

    // MARK: Session state

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

    private func beginSession(owner: Trigger?) {
        sessionOn = true
        holdOwner = owner
        onStart?()
    }

    private func endSession() {
        guard sessionOn else { return }
        sessionOn = false
        holdOwner = nil
        onStop?()
    }

    /// A trigger's release may have been missed (tap disabled or removed):
    /// stop a push-to-talk session whose release we can no longer observe. A
    /// toggle session keeps running — it doesn't depend on anything being held.
    private func releaseAll() {
        if holdOwner != nil { endSession() }
    }
}

// MARK: - Tap thread

/// The consuming event tap on its own thread with its own run loop. Owns all
/// per-event matching state (touched only on that thread) and reports
/// trigger edges to the main thread. Bindings arrive as a locked snapshot.
private final class TapEngine: @unchecked Sendable {
    typealias Trigger = HotkeyMonitor.Trigger

    struct Bindings: Sendable, Equatable {
        var hotkey: KeyCombo
        var toggleHotkey: KeyCombo
        var mousePushToTalk: MouseChord?
        var mouseToggle: MouseChord?

        var wantsMouse: Bool { mousePushToTalk != nil || mouseToggle != nil }
    }

    enum Report: Sendable {
        case down(Trigger), up(Trigger)
        /// Held state was reset (the tap was disabled; releases may be lost).
        case releasedAll
        /// The system disabled the tap for responding too slowly.
        case timedOut
    }

    /// Whether this tap listens to extra mouse buttons. Only while a mouse
    /// binding exists, so middle/side-button drags system-wide don't route
    /// through our callback for nothing.
    let hasMouse: Bool
    private let snapshot: Mutex<Bindings>
    private let report: @Sendable (Report) -> Void
    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?
    private var thread: Thread?

    // Tap-thread state.
    private var bindings: Bindings
    private var isSuspended: Bool { HotkeyMonitor.isSuspended }
    /// Triggers physically held right now — edge detection, auto-repeat
    /// suppression, and knowing which key-up / mouse-up to consume.
    private var held: Set<Trigger> = []
    /// A modifier-only toggle chord is a *tap*: it fires on release, and only
    /// if nothing else was pressed while it was held — so fn+← or ⌃⌥⌘T don't
    /// latch an open mic.
    private var modifierToggleDown = false
    private var modifierToggleClean = false
    /// Extra mouse buttons physically held right now (for chord matching).
    private var mouseDown: Set<Int> = []
    /// Chord buttons whose press we're holding back until the chord completes
    /// (fire) or the button is released alone / dragged (replay).
    private var deferred: Set<Int> = []
    /// Buttons whose press we consumed for a trigger — their up/drags are ours.
    private var swallowed: Set<Int> = []
    /// Tags clicks we re-post (`eventSourceUserData`) so the tap ignores them.
    private static let replayMarker: Int64 = 0x5052_5643   // "PRVC"

    /// `report` is called on the main queue, in order.
    init(bindings: Bindings, report: @escaping @Sendable (Report) -> Void) {
        self.bindings = bindings
        self.snapshot = Mutex(bindings)
        self.hasMouse = bindings.wantsMouse
        self.report = { r in DispatchQueue.main.async { report(r) } }
    }

    func update(_ bindings: Bindings) {
        snapshot.withLock { $0 = bindings }
    }

    /// Create the tap and start its thread. False if the tap can't be created.
    func start() -> Bool {
        var mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)
        if hasMouse {
            mask |= (1 << CGEventType.otherMouseDown.rawValue) |
                (1 << CGEventType.otherMouseUp.rawValue) |
                (1 << CGEventType.otherMouseDragged.rawValue)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,          // consuming: needs Accessibility, can swallow keys
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let engine = Unmanaged<TapEngine>.fromOpaque(refcon).takeUnretainedValue()
                return engine.handle(type: type, event: event) ? nil : Unmanaged.passUnretained(event)
            },
            // The thread below retains the engine for as long as the tap runs.
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        self.tap = tap

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            runLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(runLoop, source, .commonModes)
            ready.signal()
            CFRunLoopRun()   // returns once stopped, or when the source is gone
        }
        thread.name = "PrivoVoice hotkey tap"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        self.thread = thread
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    /// Tear the tap down for good: invalidating the port removes it from the
    /// system (a merely disabled tap lingers) and ends the thread's run loop.
    func stop() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        CFMachPortInvalidate(tap)
        if let runLoop { CFRunLoopStop(runLoop) }
        self.tap = nil
    }

    // MARK: Matching (tap thread)

    /// Returns `true` to consume (swallow) the event so its key doesn't type
    /// (or its mouse button doesn't navigate).
    private func handle(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // Re-enable (the monitor backs off if timeouts keep coming).
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            // A trigger's release may have been missed during the disabled
            // window — don't strand a held session.
            resetHeld()
            if type == .tapDisabledByTimeout { report(.timedOut) }
            return false
        }
        bindings = snapshot.withLock { $0 }
        switch type {
        case .otherMouseDown, .otherMouseUp, .otherMouseDragged:
            // A click we held back and re-posted — let it through untouched.
            if event.getIntegerValueField(.eventSourceUserData) == Self.replayMarker { return false }
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
        let toggle = bindings.toggleHotkey.conflicts(with: bindings.hotkey)
            ? KeyCombo.unset : bindings.toggleHotkey
        var consume = false

        for (trigger, combo) in [(Trigger.keyboardPushToTalk, bindings.hotkey),
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
                } else if !engaged || !isSuspended {
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
                } else if !isSuspended, satisfies(flags, combo.modifiers) {
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
            if modifierToggleClean, !isSuspended {
                setHeld(.keyboardToggle, true)
                setHeld(.keyboardToggle, false)
            }
        }
    }

    /// Mouse triggers, with chord support. A single-button trigger owns its
    /// button outright. A chord button's press is held back (`deferred`)
    /// until we know whether the rest of the chord follows: completing the
    /// chord fires the trigger; releasing the button alone replays its click so
    /// it still does its usual job (back/forward/middle-click), and starting a
    /// drag hands the press back immediately so middle-drag panning still works.
    private func handleMouse(type: CGEventType, event: CGEvent) -> Bool {
        let number = Int(event.getIntegerValueField(.mouseEventButtonNumber))

        // As with the keyboard pair, a toggle overlapping the push-to-talk
        // chord is ignored rather than firing both at once.
        let ptt = bindings.mousePushToTalk.flatMap { $0.isAssignable ? $0 : nil }
        var toggle = bindings.mouseToggle.flatMap { $0.isAssignable ? $0 : nil }
        if toggle?.conflicts(with: ptt) == true { toggle = nil }
        let bindings = [(Trigger.mousePushToTalk, ptt), (Trigger.mouseToggle, toggle)]
            .compactMap { trigger, chord in chord.map { (trigger, $0) } }

        switch type {
        case .otherMouseDown:
            mouseDown.insert(number)
            guard !isSuspended else { return false }
            // This press completes a binding: fire it. Its earlier, held-back
            // buttons were part of the chord, so they're never replayed.
            if let (trigger, chord) = bindings.first(where: {
                $0.1.buttons.contains(number) && Set($0.1.buttons).isSubset(of: mouseDown)
            }) {
                for button in chord.buttons {
                    deferred.remove(button)
                    swallowed.insert(button)
                }
                setHeld(trigger, true)
                return true
            }
            // Part of a chord that isn't complete yet: hold the click back.
            if bindings.contains(where: { $0.1.isChord && $0.1.buttons.contains(number) }) {
                deferred.insert(number)
                return true
            }
            return false

        case .otherMouseUp:
            mouseDown.remove(number)
            // Letting go of any button of a held binding ends it.
            for (trigger, chord) in bindings where chord.buttons.contains(number) {
                setHeld(trigger, false)
            }
            // Released alone — it was a plain click after all.
            if deferred.remove(number) != nil {
                replay(.otherMouseDown, button: number, at: event.location)
                replay(.otherMouseUp, button: number, at: event.location)
                return true
            }
            // Only swallow the up whose down we swallowed (a binding set
            // mid-press shouldn't eat a stray up the app is waiting for).
            return swallowed.remove(number) != nil

        default:   // .otherMouseDragged
            // A drag on a held-back chord button: give the press back first,
            // then let the drag through.
            if deferred.remove(number) != nil {
                replay(.otherMouseDown, button: number, at: event.location)
                return false
            }
            // Drags with a trigger's button held belong to the press we ate.
            return swallowed.contains(number)
        }
    }

    /// Re-post a mouse event we held back, tagged so our own tap lets it pass.
    private func replay(_ type: CGEventType, button: Int, at location: CGPoint) {
        // CGMouseButton only names left/right/center; any higher button is
        // created as `.center` and identified by its button-number field.
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type,
                                  mouseCursorPosition: location,
                                  mouseButton: CGMouseButton(rawValue: UInt32(button)) ?? .center)
        else { return }
        event.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button))
        event.setIntegerValueField(.eventSourceUserData, value: Self.replayMarker)
        event.post(tap: .cghidEventTap)
    }

    /// Edge-detect a trigger going down/up and report it.
    private func setHeld(_ trigger: Trigger, _ down: Bool) {
        if down {
            guard held.insert(trigger).inserted else { return }
            report(.down(trigger))
        } else {
            guard held.remove(trigger) != nil else { return }
            report(.up(trigger))
        }
    }

    private func resetHeld() {
        held.removeAll()
        modifierToggleDown = false
        mouseDown.removeAll()
        deferred.removeAll()
        swallowed.removeAll()
        report(.releasedAll)
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
