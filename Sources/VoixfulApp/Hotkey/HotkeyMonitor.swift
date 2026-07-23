// Global push-to-talk — hybrid, so ANY shortcut works without ever needing
// Input Monitoring:
//
//   • Registerable chords (a key + ⌘⌥⌃⇧, or a function key) → Carbon
//     RegisterEventHotKey. Zero permissions, and the chord is CONSUMED (the
//     trigger key doesn't type).
//   • fn / modifier-only / bare-key chords → NSEvent global monitor, which needs
//     only ACCESSIBILITY (the same grant we already use to paste — the way Wispr
//     Flow does its default `fn` push-to-talk). Not Input Monitoring.
//
// The NSEvent path is listen-only (can't consume), so a *printable* trigger key
// also types. `fn` alone types nothing, which is why it's the recommended chord.

import AppKit
import Carbon.HIToolbox
import VoixfulKit

@MainActor
final class HotkeyMonitor {
    var onPress: (@MainActor () -> Void)?
    var onRelease: (@MainActor () -> Void)?
    var onPermissionChange: (@MainActor () -> Void)?

    private let settings: AppSettings

    // Carbon backend
    private var hotKeyRef: EventHotKeyRef?
    private var carbonHandler: EventHandlerRef?
    // NSEvent backend
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var isDown = false

    private var activeCombo: KeyCombo?
    private enum Backend { case none, carbon, monitor }
    private var backend: Backend = .none

    /// The shortcut is armed and will fire.
    private(set) var isActive = false
    /// Accessibility granted — needed to paste, and for the NSEvent (fn/bare-key)
    /// hotkey path.
    private(set) var canPaste = false

    init(settings: AppSettings) {
        self.settings = settings
    }

    func start() {
        installCarbonHandler()
        canPaste = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        apply()
        onPermissionChange?()
    }

    /// Re-arm on shortcut change or after the user grants Accessibility.
    func refresh() {
        let paste = AXIsProcessTrusted()
        let permChanged = paste != canPaste
        canPaste = paste
        // Re-apply if the shortcut changed, or if permission changed and we're on
        // the (Accessibility-dependent) monitor path.
        if activeCombo != settings.hotkey || (permChanged && backend == .monitor) {
            apply()
        }
        if permChanged { onPermissionChange?() }
    }

    func stop() {
        teardownActive()
        if let carbonHandler { RemoveEventHandler(carbonHandler) }
        carbonHandler = nil
    }

    // MARK: Backend selection

    private func apply() {
        teardownActive()
        let combo = settings.hotkey
        activeCombo = combo
        isDown = false
        guard !combo.isEmpty else { isActive = false; onPermissionChange?(); return }

        if combo.isRegisterableHotkey {
            registerCarbon(combo)
        } else {
            installMonitor(combo)
        }
        onPermissionChange?()
    }

    private func teardownActive() {
        unregisterCarbon()
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        backend = .none
        isActive = false
    }

    // MARK: Carbon (consumes; no permission)

    private func installCarbonHandler() {
        guard carbonHandler == nil else { return }
        var types = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let userData = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return noErr }
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userData).takeUnretainedValue()
                let kind = GetEventKind(event)
                MainActor.assumeIsolated {
                    if kind == UInt32(kEventHotKeyPressed) { monitor.onPress?() }
                    else if kind == UInt32(kEventHotKeyReleased) { monitor.onRelease?() }
                }
                return noErr
            },
            2, &types, userData, &carbonHandler)
    }

    private func registerCarbon(_ combo: KeyCombo) {
        guard let keyCode = combo.keyCode else { isActive = false; return }
        let hotKeyID = EventHotKeyID(signature: OSType(0x564F4958 /* 'VOIX' */), id: 1)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(keyCode), carbonModifiers(combo.modifiers), hotKeyID,
            GetApplicationEventTarget(), 0, &ref)
        if status == noErr {
            hotKeyRef = ref
            backend = .carbon
            isActive = true
        } else {
            isActive = false
        }
    }

    private func unregisterCarbon() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
    }

    private func carbonModifiers(_ mods: KeyModifiers) -> UInt32 {
        var flags: UInt32 = 0
        if mods.contains(.command) { flags |= UInt32(cmdKey) }
        if mods.contains(.option) { flags |= UInt32(optionKey) }
        if mods.contains(.control) { flags |= UInt32(controlKey) }
        if mods.contains(.shift) { flags |= UInt32(shiftKey) }
        return flags
    }

    // MARK: NSEvent monitor (fn / modifier-only / bare keys; Accessibility)

    private func installMonitor(_ combo: KeyCombo) {
        backend = .monitor
        // The global monitor only delivers events with Accessibility granted.
        guard canPaste else { isActive = false; return }

        let handler: (NSEvent) -> Void = { [weak self] event in
            MainActor.assumeIsolated { self?.handleMonitorEvent(event) }
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.keyDown, .keyUp, .flagsChanged], handler: handler)
        // Also fire when Voixful's own window is focused (returns the event so it
        // isn't swallowed).
        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
                MainActor.assumeIsolated { self?.handleMonitorEvent(event) }
                return event
            }
        isActive = true
    }

    private func handleMonitorEvent(_ event: NSEvent) {
        guard let combo = activeCombo else { return }
        let held = Self.keyModifiers(event.modifierFlags)

        if combo.isModifierOnly {
            // fn / other modifier-only: engaged when the required modifiers are held.
            if event.type == .flagsChanged {
                transition(to: combo.modifiers.isSubset(of: held))
            }
            return
        }

        guard let keyCode = combo.keyCode else { return }
        switch event.type {
        case .keyDown where event.keyCode == keyCode:
            if combo.modifiers.isSubset(of: held) { transition(to: true) }
        case .keyUp where event.keyCode == keyCode:
            transition(to: false)
        default:
            break
        }
    }

    private func transition(to engaged: Bool) {
        if engaged, !isDown { isDown = true; onPress?() }
        else if !engaged, isDown { isDown = false; onRelease?() }
    }

    private static func keyModifiers(_ flags: NSEvent.ModifierFlags) -> KeyModifiers {
        var m: KeyModifiers = []
        if flags.contains(.command) { m.insert(.command) }
        if flags.contains(.option) { m.insert(.option) }
        if flags.contains(.control) { m.insert(.control) }
        if flags.contains(.shift) { m.insert(.shift) }
        if flags.contains(.function) { m.insert(.function) }
        return m
    }
}
