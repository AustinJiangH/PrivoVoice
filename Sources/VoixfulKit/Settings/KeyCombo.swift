// A platform-neutral representation of the push-to-talk hotkey.
//
// Stored as a virtual key code plus a modifier set so it round-trips through
// settings JSON without depending on AppKit. The macOS app layer maps this to
// `CGEvent` / `NSEvent` flags; a future iOS app can interpret it differently (or
// ignore the key code and use a modifier-only chord).

import Foundation

/// Cross-platform modifier flags. Raw values are stable (persisted).
public struct KeyModifiers: OptionSet, Sendable, Hashable, Codable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let command = KeyModifiers(rawValue: 1 << 0)
    public static let option  = KeyModifiers(rawValue: 1 << 1)
    public static let control = KeyModifiers(rawValue: 1 << 2)
    public static let shift   = KeyModifiers(rawValue: 1 << 3)
    /// The `fn` / globe key — usable as a modifier-only push-to-talk trigger.
    public static let function = KeyModifiers(rawValue: 1 << 4)

    /// Symbol glyphs in canonical order (⌃⌥⇧⌘), plus `fn` spelled out.
    public var displayString: String {
        var s = ""
        if contains(.function) { s += "fn " }
        if contains(.control) { s += "⌃" }
        if contains(.option) { s += "⌥" }
        if contains(.shift) { s += "⇧" }
        if contains(.command) { s += "⌘" }
        return s
    }
}

/// A key chord: an optional virtual key code plus modifiers.
///
/// - A chord with a `keyCode` fires on that key's press/release (with the
///   modifiers held).
/// - A chord with `keyCode == nil` is *modifier-only* (e.g. hold `fn`, or hold
///   right-Option): it fires on the modifier engaging/disengaging.
public struct KeyCombo: Sendable, Hashable, Codable {
    /// Virtual key code (macOS `CGKeyCode`), or `nil` for a modifier-only chord.
    public var keyCode: UInt16?
    /// Human-readable key label captured at record time (e.g. "F5", "Space").
    public var keyLabel: String?
    public var modifiers: KeyModifiers

    public init(keyCode: UInt16?, keyLabel: String? = nil, modifiers: KeyModifiers = []) {
        self.keyCode = keyCode
        self.keyLabel = keyLabel
        self.modifiers = modifiers
    }

    /// `true` when there is no key and no modifier — an unset/invalid chord.
    public var isEmpty: Bool { keyCode == nil && modifiers.isEmpty }

    /// `true` when the chord is triggered purely by modifiers (no key code).
    public var isModifierOnly: Bool { keyCode == nil && !modifiers.isEmpty }

    /// Virtual key codes for F1–F20 — the only keys safe to use as a global
    /// hotkey with no modifier (they don't collide with normal typing).
    public static let functionKeyCodes: Set<UInt16> = [
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111,   // F1–F12
        105, 107, 113, 106, 64, 79, 80, 90,                       // F13–F20
    ]

    /// Whether this is a safe global push-to-talk shortcut. The consuming tap
    /// swallows the trigger, so a *bare* printable key would make that key
    /// untypeable everywhere and toggle dictation on every press — reject those.
    /// Valid: a key + any modifier (incl `fn`), a function key on its own, `fn`
    /// alone, or a multi-modifier chord. Invalid: a bare non-function key, or a
    /// single common modifier (⌘/⌥/⌃/⇧) alone (pressed constantly while typing).
    public var isValidGlobalShortcut: Bool {
        if let keyCode {
            return !modifiers.isEmpty || KeyCombo.functionKeyCodes.contains(keyCode)
        }
        guard !modifiers.isEmpty else { return false }
        return modifiers.contains(.function) || modifiers.rawValue.nonzeroBitCount >= 2
    }

    /// Rendered chord, e.g. "⌥⌘Space" or "fn".
    public var displayString: String {
        if isEmpty { return "Not set" }
        return modifiers.displayString + (keyLabel ?? "")
    }

    /// The default: hold the `fn` (Globe) key to talk — a modifier-only chord, so
    /// nothing types while you dictate. Like every shortcut it fires from the
    /// consuming `CGEventTap`, which needs only Accessibility (the same grant used
    /// to paste) — never Input Monitoring.
    public static let defaultCombo = KeyCombo(keyCode: nil, keyLabel: nil, modifiers: [.function])
}
