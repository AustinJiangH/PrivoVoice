// A mouse dictation trigger (push-to-talk or toggle): one mouse button, or a
// chord of several pressed together (e.g. Back + Middle).
//
// Buttons are the raw numbers macOS reports for "other" mouse buttons
// (`CGEvent` `.mouseEventButtonNumber` / `NSEvent.buttonNumber`): 2 is the
// middle button, 3 and 4 are the usual back/forward side buttons. The primary
// (0) and secondary (1) buttons are never valid — the consuming tap would
// swallow every click.
//
// A single-button trigger takes that button over. In a chord, each button on
// its own keeps its normal job: the event tap holds a chord button's click
// until it knows whether the rest of the chord follows, and replays it if not.

import Foundation

public struct MouseChord: Sendable, Hashable, Codable {
    /// The buttons that must all be held, sorted ascending (canonical, so two
    /// chords pressed in a different order compare equal).
    public private(set) var buttons: [Int]

    public init(buttons: some Sequence<Int>) {
        self.buttons = Array(Set(buttons)).sorted()
    }

    public init(button: Int) { self.init(buttons: [button]) }

    /// Lowest usable button number (middle click); 0/1 are left/right click.
    public static let firstAssignable = 2

    /// Non-empty, and no left/right click in it.
    public var isAssignable: Bool {
        !buttons.isEmpty && buttons.allSatisfy { $0 >= Self.firstAssignable }
    }

    /// More than one button — its buttons keep their normal action alone.
    public var isChord: Bool { buttons.count > 1 }

    /// Whether pressing one would also fire the other: identical chords, or
    /// one chord contained in the other (pressing Back + Middle passes through
    /// "Back held", which would fire a Back-only trigger first).
    public func conflicts(with other: MouseChord?) -> Bool {
        guard let other else { return false }
        let a = Set(buttons), b = Set(other.buttons)
        return a.isSubset(of: b) || b.isSubset(of: a)
    }

    /// Name of one button, e.g. "Back (Button 4)" — longer form for a lone
    /// button, short form ("Back") inside a chord.
    public static func name(of button: Int, short: Bool = false) -> String {
        switch button {
        case 2: return short ? "Middle" : "Middle button"
        case 3: return short ? "Back" : "Back (Button 4)"
        case 4: return short ? "Forward" : "Forward (Button 5)"
        default: return "Button \(button + 1)"
        }
    }

    /// Badge tokens, one per button, e.g. ["Back", "Middle"].
    public var badgeComponents: [String] {
        buttons.map { Self.name(of: $0, short: isChord) }
    }

    /// e.g. "Back (Button 4)" or "Back + Middle".
    public var displayName: String { badgeComponents.joined(separator: " + ") }

    // Older settings stored a single `{"number": n}` — decode it as a
    // one-button chord.
    private enum CodingKeys: String, CodingKey { case buttons, number }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let buttons = try c.decodeIfPresent([Int].self, forKey: .buttons) {
            self.init(buttons: buttons)
        } else {
            self.init(button: try c.decode(Int.self, forKey: .number))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(buttons, forKey: .buttons)
    }
}
