// A mouse button used as a dictation trigger (push-to-talk or toggle).
//
// Stored as the raw button number macOS reports for "other" mouse buttons
// (`CGEvent` `.mouseEventButtonNumber` / `NSEvent.buttonNumber`): 2 is the
// middle button, 3 and 4 are the usual back/forward side buttons. The primary
// (0) and secondary (1) buttons are never valid — the consuming tap would
// swallow every click.

import Foundation

public struct MouseButton: Sendable, Hashable, Codable {
    public var number: Int

    public init(number: Int) { self.number = number }

    /// Lowest usable button number (middle click); 0/1 are left/right click.
    public static let firstAssignable = 2

    /// Whether this button can be bound without breaking normal clicking.
    public var isAssignable: Bool { number >= Self.firstAssignable }

    /// Human-readable name, e.g. "Back (Button 4)".
    public var displayName: String {
        switch number {
        case 2: return "Middle button"
        case 3: return "Back (Button 4)"
        case 4: return "Forward (Button 5)"
        default: return "Button \(number + 1)"
        }
    }
}
