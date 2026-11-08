// A mouse button used as a dictation trigger (push-to-talk or toggle),
// optionally combined with held keyboard modifiers.
//
// Stored as the raw button number macOS reports for "other" mouse buttons
// (`CGEvent` `.mouseEventButtonNumber` / `NSEvent.buttonNumber`): 2 is the
// middle button, 3 and 4 are the usual back/forward side buttons. The primary
// (0) and secondary (1) buttons are never valid — the consuming tap would
// swallow every click.
//
// With modifiers (e.g. ⌥ + Back) the trigger only fires while exactly those
// ⌘⌥⌃⇧ are held, so the bare button keeps its normal job (back/forward).

import Foundation

public struct MouseButton: Sendable, Hashable, Codable {
    public var number: Int
    /// Keyboard modifiers that must be held with the button; empty = bare.
    public var modifiers: KeyModifiers

    public init(number: Int, modifiers: KeyModifiers = []) {
        self.number = number
        self.modifiers = modifiers
    }

    /// Lowest usable button number (middle click); 0/1 are left/right click.
    public static let firstAssignable = 2

    /// Whether this button can be bound without breaking normal clicking.
    public var isAssignable: Bool { number >= Self.firstAssignable }

    /// Whether pressing one would also fire the other: same button and the
    /// same ⌘⌥⌃⇧ (`fn` doesn't separate them — the tap matches ⌘⌥⌃⇧ exactly but
    /// only requires `fn` when it's part of the binding).
    public func conflicts(with other: MouseButton?) -> Bool {
        guard let other else { return false }
        let chord: KeyModifiers = [.command, .option, .control, .shift]
        return number == other.number
            && modifiers.intersection(chord) == other.modifiers.intersection(chord)
    }

    /// Human-readable name of the button alone, e.g. "Back (Button 4)".
    public var buttonName: String {
        switch number {
        case 2: return "Middle button"
        case 3: return "Back (Button 4)"
        case 4: return "Forward (Button 5)"
        default: return "Button \(number + 1)"
        }
    }

    /// Full binding, e.g. "⌥Back (Button 4)".
    public var displayName: String { modifiers.displayString + buttonName }

    /// Badge tokens: modifier glyphs (canonical order) then the button name.
    public var badgeComponents: [String] { modifiers.components + [buttonName] }

    // Older settings files stored only `number` — decode a missing modifier
    // set as "bare button".
    private enum CodingKeys: String, CodingKey { case number, modifiers }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        number = try c.decode(Int.self, forKey: .number)
        modifiers = try c.decodeIfPresent(KeyModifiers.self, forKey: .modifiers) ?? []
    }
}
