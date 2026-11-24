import AppKit
import KopiCore
import XCTest
@testable import Kopi

/// The Ditto-style gesture with the default ⌃Q shortcut.
final class HoldGestureTests: XCTestCase {
    private var gesture = HoldGesture()

    func testQuickTapOpensWithoutPasting() {
        XCTAssertTrue(gesture.begin(held: .control, shortcut: .control, at: 0))
        XCTAssertEqual(gesture.update(current: .control, at: 0.05), .stillHeld)
        XCTAssertEqual(gesture.update(current: [], at: 0.2), .released(paste: false))
        // Once released, ⌃Q closes the popup instead of moving.
        XCTAssertFalse(gesture.shortcutPressedAgain())
    }

    func testPressingAgainWhileHoldingMovesThenReleasePastes() {
        gesture.begin(held: .control, shortcut: .control, at: 0)
        XCTAssertTrue(gesture.shortcutPressedAgain())
        XCTAssertTrue(gesture.shortcutPressedAgain())
        XCTAssertEqual(gesture.update(current: .control, at: 0.3), .stillHeld)
        XCTAssertEqual(gesture.update(current: [], at: 0.35), .released(paste: true))
        XCTAssertFalse(gesture.isActive)
    }

    func testHoldingLongerThanASecondPastesTheFirstClip() {
        gesture.begin(held: .control, shortcut: .control, at: 10)
        XCTAssertEqual(gesture.update(current: .control, at: 10.9), .stillHeld)
        XCTAssertEqual(gesture.update(current: [], at: 11.1), .released(paste: true))
    }

    func testAlreadyReleasedWhenTheShortcutFiredMeansNoGesture() {
        XCTAssertFalse(gesture.begin(held: [], shortcut: .control, at: 0))
        XCTAssertFalse(gesture.shortcutPressedAgain())
    }

    func testOnlyTheShortcutsModifiersCount() {
        // Shift happens to be down too; letting go of ⌃ is what matters.
        gesture.begin(held: [.control, .shift], shortcut: .control, at: 0)
        XCTAssertEqual(gesture.heldModifiers, .control)
        XCTAssertTrue(gesture.shortcutPressedAgain())
        XCTAssertEqual(gesture.update(current: .shift, at: 0.2), .released(paste: true))
    }

    func testEveryModifierMustBeReleased() {
        // With a ⌃⌥ shortcut, letting go of ⌥ alone keeps the gesture going.
        gesture.begin(held: [.control, .option], shortcut: [.control, .option], at: 0)
        XCTAssertTrue(gesture.shortcutPressedAgain())
        XCTAssertEqual(gesture.update(current: .control, at: 0.2), .stillHeld)
        XCTAssertEqual(gesture.update(current: [], at: 0.3), .released(paste: true))
    }

    func testCancel() {
        gesture.begin(held: .control, shortcut: .control, at: 0)
        _ = gesture.shortcutPressedAgain()
        gesture.cancel()
        XCTAssertFalse(gesture.isActive)
        XCTAssertEqual(gesture.update(current: [], at: 5), .released(paste: false))
    }
}

@MainActor
final class SelectionWrapTests: XCTestCase {
    func testWrapsAroundForTheHoldGesture() throws {
        let store = try KopiCore.ClipStore(path: ":memory:")
        let start = Date(timeIntervalSince1970: 1_000)
        for index in 0..<3 {
            try store.insert(KopiCore.ClipContent(text: "clip \(index)"), now: start.addingTimeInterval(Double(index)))
        }
        let model = PopupModel(store: store)
        model.prepareForShow()
        XCTAssertEqual(model.selectedClip?.title, "clip 2")

        model.moveSelection(by: 1, wrap: true)
        model.moveSelection(by: 1, wrap: true)
        XCTAssertEqual(model.selectedClip?.title, "clip 0")
        model.moveSelection(by: 1, wrap: true)
        XCTAssertEqual(model.selectedClip?.title, "clip 2", "past the last clip it starts over")

        model.moveSelection(by: -1)
        XCTAssertEqual(model.selectedClip?.title, "clip 2", "arrow keys stop at the ends")
    }
}
