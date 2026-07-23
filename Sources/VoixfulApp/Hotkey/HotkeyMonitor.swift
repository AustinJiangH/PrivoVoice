// Global push-to-talk via a CGEventTap.
//
// Watches key + modifier events session-wide (listen-only, so it never swallows
// the key — printable trigger keys will still type, which is why the default is
// the modifier-only `fn` chord). Fires `onPress` when the configured chord
// engages and `onRelease` when it disengages. Both callbacks run on the main
// actor (the tap is installed on the main run loop).
//
// Requires Accessibility / Input Monitoring permission; without it `tapCreate`
// returns nil and `isTrusted` is false.

import AppKit
import CoreGraphics
import VoixfulKit

@MainActor
final class HotkeyMonitor {
    var onPress: (@MainActor () -> Void)?
    var onRelease: (@MainActor () -> Void)?

    private let settings: AppSettings
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var isDown = false

    /// Whether the process is allowed to observe global input.
    private(set) var isTrusted = false

    init(settings: AppSettings) {
        self.settings = settings
    }

    func start() {
        // Prompt for Accessibility trust if not already granted. The option key
        // is referenced by its literal value to avoid touching the non-Sendable
        // global `kAXTrustedCheckOptionPrompt` under Swift 6 concurrency checking.
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        isTrusted = AXIsProcessTrustedWithOptions(opts)

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
            isTrusted = false
            return
        }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        isTrusted = true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }

    // MARK: Matching

    private func handle(type: CGEventType, event: CGEvent) {
        let combo = settings.hotkey
        guard !combo.isEmpty else { return }
        let flags = event.flags

        let required = requiredFlags(combo.modifiers)

        if combo.isModifierOnly {
            // Engaged when every required modifier is held.
            transition(to: flags.contains(required))
            return
        }

        // Key-code chord: match on keyDown / keyUp of the exact key.
        guard let keyCode = combo.keyCode else { return }
        let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        switch type {
        case .keyDown where code == keyCode:
            if flags.contains(required) { transition(to: true) }
        case .keyUp where code == keyCode:
            transition(to: false)
        default:
            break
        }
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
