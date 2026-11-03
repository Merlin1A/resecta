import XCTest

/// The iPhone editor's trailing controls (Undo · Redact · …) are three
/// separate circles in every state. On iOS 27 the system's … shared one
/// capsule with Redact while Redact was disabled (no regions), and every
/// control moved when the first region arrived. The pin: each control's
/// frame is the same with no regions and with one, the gaps between
/// neighbours match, and Redact stays disabled until there is a region.
///
/// nonisolated: an XCUITest drives a separate process and touches no
/// @MainActor state.
nonisolated final class EditorTrailingControlsUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--loadTestDocument", "--multipageDoc"]
        app.launch()
        XCTAssertTrue(app.buttons["drawTool"].waitForExistence(timeout: 60), "the editor never appeared")
    }

    override func tearDown() {
        app = nil
        super.tearDown()
    }

    func testUndoRedactAndMoreAreThreeSeparateControlsInEveryState() {
        sleep(2)
        let empty = trailingFrames()
        XCTAssertFalse(app.buttons["redactButton"].isEnabled, "with no regions Redact is not available")
        assertSeparate(empty, state: "no regions")

        let mark = app.buttons["pageNavMarkWholePage"]
        XCTAssertTrue(mark.waitForExistence(timeout: 10))
        mark.tap()
        XCTAssertTrue(app.buttons["redactButton"].waitForEnabled(timeout: 10), "a region makes Redact available")
        sleep(2)
        let marked = trailingFrames()
        assertSeparate(marked, state: "one region")

        for (name, before, after) in zip3(["Undo", "Redact", "More"], empty, marked) {
            XCTAssertEqual(before.minX, after.minX, accuracy: 1, "\(name) moved when the first region arrived: \(before) → \(after)")
            XCTAssertEqual(before.width, after.width, accuracy: 1, "\(name) changed width when the first region arrived: \(before) → \(after)")
        }
    }

    /// The … is the app's own menu on iOS 27 only; earlier iOS keeps the
    /// system's overflow button as shipped. The other lookups accept either,
    /// so this pins which one each iOS gets.
    func testTheMoreMenuIsTheAppsOwnOnlyOnIOS27() {
        let own = app.buttons["editorMoreMenu"]
        let system = app.buttons
            .matching(NSPredicate(format: "identifier IN %@", ["OverflowBarButtonItem", "TopOverflowBarButtonItem"]))
            .firstMatch
        if #available(iOS 27, *) {
            XCTAssertTrue(own.waitForExistence(timeout: 10), "on iOS 27 the … is the app's own menu")
            XCTAssertFalse(system.exists, "on iOS 27 the system's … must not show as well")
        } else {
            XCTAssertTrue(system.waitForExistence(timeout: 10), "before iOS 27 the … is the system's, as shipped")
            XCTAssertFalse(own.exists, "before iOS 27 the app's own … menu must not show")
        }
    }

    // MARK: - Helpers

    private func trailingFrames() -> [CGRect] {
        let undo = app.buttons["undoButton"]
        let redact = app.buttons["redactButton"]
        let more = app.editorOverflowButton
        XCTAssertTrue(undo.exists && redact.exists && more.waitForExistence(timeout: 5), "a trailing control is missing")
        return [undo.frame, redact.frame, more.frame]
    }

    /// Undo, Redact and More in order, apart, with matching gaps.
    private func assertSeparate(_ f: [CGRect], state: String, file: StaticString = #filePath, line: UInt = #line) {
        let first = f[1].minX - f[0].maxX, second = f[2].minX - f[1].maxX
        XCTAssertGreaterThan(first, 4, "\(state): Undo and Redact touch (\(f))", file: file, line: line)
        XCTAssertGreaterThan(second, 4, "\(state): Redact and More touch (\(f))", file: file, line: line)
        XCTAssertEqual(first, second, accuracy: 2, "\(state): the gaps differ, so two controls share a capsule (\(f))", file: file, line: line)
    }

    private func zip3<A, B, C>(_ a: [A], _ b: [B], _ c: [C]) -> [(A, B, C)] {
        (0..<min(a.count, b.count, c.count)).map { (a[$0], b[$0], c[$0]) }
    }
}

private extension XCUIElement {
    nonisolated func waitForEnabled(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if exists && isEnabled { return true }
            usleep(250_000)
        }
        return false
    }
}
