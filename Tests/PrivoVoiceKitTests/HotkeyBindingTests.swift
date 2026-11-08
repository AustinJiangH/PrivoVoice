// The four dictation triggers: keyboard chord conflict rules, mouse-button
// validity, and persistence / load-time healing of the optional bindings.

import XCTest
import Foundation
@testable import PrivoVoiceKit

private func tempStore() -> URL {
    FileManager.default.temporaryDirectory
        .appending(path: "voix-\(UUID().uuidString)/settings.json")
}

final class KeyComboConflictTests: XCTestCase {
    private let fn = KeyCombo(keyCode: nil, modifiers: [.function])
    private let optSpace = KeyCombo(keyCode: 49, keyLabel: "Space", modifiers: [.option])
    private let f5 = KeyCombo(keyCode: 96, keyLabel: "F5", modifiers: [])

    func testIdenticalChordsConflict() {
        XCTAssertTrue(optSpace.conflicts(with: optSpace))
        XCTAssertTrue(fn.conflicts(with: fn))
    }

    func testEmptyNeverConflicts() {
        XCTAssertFalse(KeyCombo.unset.conflicts(with: fn))
        XCTAssertFalse(fn.conflicts(with: .unset))
        XCTAssertFalse(KeyCombo.unset.conflicts(with: .unset))
    }

    func testDistinctChordsDoNotConflict() {
        XCTAssertFalse(optSpace.conflicts(with: f5))
        XCTAssertFalse(fn.conflicts(with: optSpace))
        XCTAssertFalse(optSpace.conflicts(with: KeyCombo(keyCode: 49, keyLabel: "Space", modifiers: [.control])))
    }

    func testFnDoesNotSeparateSameKey() {
        // A bare F5 still matches while fn is held, so fn+F5 collides with it.
        let fnF5 = KeyCombo(keyCode: 96, keyLabel: "F5", modifiers: [.function])
        XCTAssertTrue(f5.conflicts(with: fnF5))
        XCTAssertTrue(fnF5.conflicts(with: f5))
    }

    func testModifierOnlyConflictsWithChordHoldingIt() {
        // Holding fn+Space engages a modifier-only fn trigger.
        let fnSpace = KeyCombo(keyCode: 49, keyLabel: "Space", modifiers: [.function])
        XCTAssertTrue(fn.conflicts(with: fnSpace))
        XCTAssertTrue(fnSpace.conflicts(with: fn))
        // ⌃⌥ (modifier-only) vs ⌃⌥⇧ (modifier-only): holding the latter engages the former.
        let ctrlOpt = KeyCombo(keyCode: nil, modifiers: [.control, .option])
        let ctrlOptShift = KeyCombo(keyCode: nil, modifiers: [.control, .option, .shift])
        XCTAssertTrue(ctrlOpt.conflicts(with: ctrlOptShift))
        XCTAssertTrue(ctrlOptShift.conflicts(with: ctrlOpt))
        XCTAssertFalse(ctrlOpt.conflicts(with: fn))
    }
}

final class MouseChordTests: XCTestCase {
    func testOnlyExtraButtonsAreAssignable() {
        XCTAssertFalse(MouseChord(button: 0).isAssignable)
        XCTAssertFalse(MouseChord(button: 1).isAssignable)
        XCTAssertTrue(MouseChord(button: 2).isAssignable)
        XCTAssertTrue(MouseChord(buttons: [3, 2]).isAssignable)
        XCTAssertFalse(MouseChord(buttons: [3, 1]).isAssignable, "a chord can't include right-click")
        XCTAssertFalse(MouseChord(buttons: []).isAssignable)
    }

    func testChordIsOrderIndependent() {
        XCTAssertEqual(MouseChord(buttons: [3, 2]), MouseChord(buttons: [2, 3, 3]))
        XCTAssertTrue(MouseChord(buttons: [2, 3]).isChord)
        XCTAssertFalse(MouseChord(button: 3).isChord)
    }

    func testConflictsWhenOneContainsTheOther() {
        let back = MouseChord(button: 3)
        let backMiddle = MouseChord(buttons: [3, 2])
        let backForward = MouseChord(buttons: [3, 4])
        // Pressing Back + Middle passes through "Back held".
        XCTAssertTrue(back.conflicts(with: backMiddle))
        XCTAssertTrue(backMiddle.conflicts(with: back))
        XCTAssertTrue(backMiddle.conflicts(with: MouseChord(buttons: [2, 3])))
        // Sharing a button is fine as long as neither contains the other.
        XCTAssertFalse(backMiddle.conflicts(with: backForward))
        XCTAssertFalse(back.conflicts(with: MouseChord(button: 4)))
        XCTAssertFalse(back.conflicts(with: nil))
    }

    func testDisplayNames() {
        XCTAssertEqual(MouseChord(button: 3).displayName, "Back (Button 4)")
        XCTAssertEqual(MouseChord(button: 4).displayName, "Forward (Button 5)")
        XCTAssertEqual(MouseChord(button: 7).displayName, "Button 8")
        XCTAssertEqual(MouseChord(buttons: [3, 2]).displayName, "Middle + Back")
        XCTAssertEqual(MouseChord(buttons: [3, 2]).badgeComponents, ["Middle", "Back"])
    }

    func testDecodesLegacySingleButton() throws {
        let legacy = try JSONDecoder().decode(MouseChord.self, from: Data(#"{"number":4}"#.utf8))
        XCTAssertEqual(legacy, MouseChord(button: 4))
        let roundTrip = try JSONDecoder().decode(
            MouseChord.self, from: JSONEncoder().encode(MouseChord(buttons: [2, 3])))
        XCTAssertEqual(roundTrip, MouseChord(buttons: [2, 3]))
    }
}

final class HotkeySettingsTests: XCTestCase {
    @MainActor
    func testDefaultsLeaveOptionalBindingsUnset() {
        let s = AppSettings(storeURL: tempStore())
        XCTAssertEqual(s.hotkey, .defaultCombo)
        XCTAssertTrue(s.toggleHotkey.isEmpty)
        XCTAssertNil(s.mousePushToTalkButton)
        XCTAssertNil(s.mouseToggleButton)
    }

    @MainActor
    func testAllBindingsPersist() {
        let store = tempStore()
        let a = AppSettings(storeURL: store)
        a.toggleHotkey = KeyCombo(keyCode: 49, keyLabel: "Space", modifiers: [.option])
        a.mousePushToTalkButton = MouseChord(button: 3)
        a.mouseToggleButton = MouseChord(buttons: [3, 4])
        a.saveNow()

        let b = AppSettings(storeURL: store)
        XCTAssertEqual(b.toggleHotkey, KeyCombo(keyCode: 49, keyLabel: "Space", modifiers: [.option]))
        XCTAssertEqual(b.mousePushToTalkButton, MouseChord(button: 3))
        XCTAssertNil(b.mouseToggleButton, "Back + Forward contains Back — healed away")
    }

    @MainActor
    func testTranscriptPositionPersists() {
        let store = tempStore()
        let a = AppSettings(storeURL: store)
        XCTAssertEqual(a.transcriptPosition, .top)
        a.transcriptPosition = .bottom
        a.saveNow()
        XCTAssertEqual(AppSettings(storeURL: store).transcriptPosition, .bottom)
    }

    @MainActor
    func testClearedPushToTalkStaysCleared() {
        let store = tempStore()
        let a = AppSettings(storeURL: store)
        a.hotkey = .unset
        a.toggleHotkey = KeyCombo(keyCode: nil, modifiers: [.function])
        a.saveNow()

        let b = AppSettings(storeURL: store)
        XCTAssertTrue(b.hotkey.isEmpty, "an unset push-to-talk is a choice, not corruption")
        XCTAssertEqual(b.toggleHotkey, KeyCombo(keyCode: nil, modifiers: [.function]))
    }

    @MainActor
    func testNoTriggersAtAllRestoresDefaultPushToTalk() {
        let store = tempStore()
        let a = AppSettings(storeURL: store)
        a.hotkey = .unset   // e.g. cleared during onboarding
        XCTAssertFalse(a.hasAnyTrigger)
        a.saveNow()

        XCTAssertEqual(AppSettings(storeURL: store).hotkey, .defaultCombo)
    }

    @MainActor
    func testConflictingAndInvalidBindingsHealOnLoad() {
        let store = tempStore()
        let a = AppSettings(storeURL: store)
        a.toggleHotkey = a.hotkey                       // same chord as push-to-talk
        a.mousePushToTalkButton = MouseChord(button: 0) // left click
        a.mouseToggleButton = MouseChord(button: 3)
        a.saveNow()

        let b = AppSettings(storeURL: store)
        XCTAssertTrue(b.toggleHotkey.isEmpty)
        XCTAssertNil(b.mousePushToTalkButton)
        XCTAssertEqual(b.mouseToggleButton, MouseChord(button: 3))

        // Chords that share a button but don't contain each other: both kept.
        b.mousePushToTalkButton = MouseChord(buttons: [2, 4])
        b.mouseToggleButton = MouseChord(buttons: [3, 4])
        b.saveNow()
        XCTAssertEqual(AppSettings(storeURL: store).mouseToggleButton, MouseChord(buttons: [3, 4]))

        // Both mouse actions on one button: the toggle is dropped.
        b.mousePushToTalkButton = MouseChord(button: 3)
        b.mouseToggleButton = MouseChord(button: 3)
        b.saveNow()
        let c = AppSettings(storeURL: store)
        XCTAssertEqual(c.mousePushToTalkButton, MouseChord(button: 3))
        XCTAssertNil(c.mouseToggleButton)
        // …and the healing was persisted.
        XCTAssertNil(AppSettings(storeURL: store).mouseToggleButton)
    }
}
