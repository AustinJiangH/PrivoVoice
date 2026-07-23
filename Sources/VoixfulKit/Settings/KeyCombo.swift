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

    /// Rendered chord, e.g. "⌥⌘Space" or "fn".
    public var displayString: String {
        if isEmpty { return "Not set" }
        return modifiers.displayString + (keyLabel ?? "")
    }

    /// The default: hold ⌥Space to talk. A key+modifier chord (not a bare
    /// modifier) because the global hotkey is registered via Carbon's
    /// `RegisterEventHotKey`, which needs a key code and can't bind `fn` alone —
    /// the upside is it needs no Input Monitoring permission and the chord is
    /// consumed (so Space doesn't type while you dictate).
    public static let defaultCombo = KeyCombo(keyCode: 49, keyLabel: "Space", modifiers: [.option])
}
