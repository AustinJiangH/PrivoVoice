// Global push-to-talk via Carbon's RegisterEventHotKey — the same mechanism
// Handy (Tauri's global-shortcut) uses.
//
// Why not a CGEventTap: a keyboard event tap sniffs the entire key stream and so
// REQUIRES Input Monitoring permission. RegisterEventHotKey instead registers a
// single system hotkey — no Input Monitoring, no Accessibility for the hotkey
// itself — and the system delivers only that chord's press/release to us (and
// consumes it, so the trigger key doesn't type). Accessibility is still needed,
// but only to synthesize the ⌘V paste.
//
// Tradeoff: the hotkey must be a key + optional ⌘⌥⌃⇧ modifiers. Modifier-only
// triggers (a bare `fn`) can't be registered this way.

import AppKit
import Carbon.HIToolbox
import VoixfulKit

@MainActor
final class HotkeyMonitor {
    var onPress: (@MainActor () -> Void)?
    var onRelease: (@MainActor () -> Void)?
    /// Fired when registration / paste-permission state changes.
    var onPermissionChange: (@MainActor () -> Void)?

    private let settings: AppSettings
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var registeredCombo: KeyCombo?

    /// The hotkey is registered with the system.
    private(set) var isActive = false
    /// Accessibility granted — needed only to post the paste keystroke.
    private(set) var canPaste = false

    init(settings: AppSettings) {
        self.settings = settings
    }

    /// Install the Carbon handler, register the hotkey, and prompt for
    /// Accessibility (used only for the paste).
    func start() {
        installHandler()
        register()
        canPaste = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        onPermissionChange?()
    }

    /// Re-register if the shortcut changed, and re-check paste permission. Call
    /// when the shortcut setting changes or the app regains focus.
    func refresh() {
        if registeredCombo != settings.hotkey { register() }
        let paste = AXIsProcessTrusted()
        if paste != canPaste { canPaste = paste; onPermissionChange?() }
    }

    func stop() {
        unregister()
        if let handlerRef { RemoveEventHandler(handlerRef) }
        handlerRef = nil
    }

    // MARK: Carbon

    private func installHandler() {
        guard handlerRef == nil else { return }
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
                // Carbon events are delivered on the main run loop.
                MainActor.assumeIsolated { monitor.handle(kind: kind) }
                return noErr
            },
            2, &types, userData, &handlerRef)
    }

    private func handle(kind: UInt32) {
        if kind == UInt32(kEventHotKeyPressed) {
            onPress?()
        } else if kind == UInt32(kEventHotKeyReleased) {
            onRelease?()
        }
    }

    private func register() {
        unregister()
        let combo = settings.hotkey
        // Carbon needs a key code; modifier-only chords can't be registered.
        guard let keyCode = combo.keyCode else {
            isActive = false
            onPermissionChange?()
            return
        }
        let hotKeyID = EventHotKeyID(signature: OSType(0x564F4958 /* 'VOIX' */), id: 1)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(keyCode), carbonModifiers(combo.modifiers), hotKeyID,
            GetApplicationEventTarget(), 0, &ref)
        if status == noErr {
            hotKeyRef = ref
            registeredCombo = combo
            isActive = true
        } else {
            isActive = false
        }
        onPermissionChange?()
    }

    private func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        registeredCombo = nil
        isActive = false
    }

    /// Map our modifiers to Carbon's mask (⌘⌥⌃⇧). `fn` has no Carbon equivalent
    /// and is dropped — hence modifier-only `fn` triggers aren't supported here.
    private func carbonModifiers(_ mods: KeyModifiers) -> UInt32 {
        var flags: UInt32 = 0
        if mods.contains(.command) { flags |= UInt32(cmdKey) }
        if mods.contains(.option) { flags |= UInt32(optionKey) }
        if mods.contains(.control) { flags |= UInt32(controlKey) }
        if mods.contains(.shift) { flags |= UInt32(shiftKey) }
        return flags
    }
}
