import XCTest

/// The home screen as VoiceOver and a finger meet it: every entry speaks
/// its title and description under its identifier, the gear has its own
/// identifier, the trust words are one line, and at the largest
/// accessibility size the first entry is whole on the first screen with
/// no scroll; the three entries are one card size. Black-box XCUITest, no `@testable import`.
///
/// nonisolated for the same reason as the sibling suites: an XCUITest
/// drives a separate process and touches no @MainActor app state.
nonisolated final class HomeScreenUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDown() {
        app = nil
        super.tearDown()
    }

    /// Each entry's identifier resolves to a button whose label is the copy
    /// of record's title and description; the gear has its identifier; the
    /// trust words read as one static text.
    func testHomeEntriesSpeakTheirLabels() {
        app.launchArguments = ["--uitesting"]
        app.launch()

        let expected: [(id: String, label: String)] = [
            ("homeOpenDocument", "Open a Document, Import a PDF or an image from Files. Nothing is uploaded."),
            ("homeImportPhotos", "Import Photos, Choose up to 20 photos, one page each. Nothing is uploaded."),
            ("homeTrySample", "Try the Sample, A bundled 3-page bank statement."),
        ]
        for entry in expected {
            let button = app.buttons[entry.id]
            XCTAssertTrue(button.waitForExistence(timeout: 10), "\(entry.id) is on Home")
            XCTAssertEqual(button.label, entry.label, "\(entry.id) speaks the copy of record")
        }
        XCTAssertTrue(app.buttons["homeSettingsButton"].exists, "the gear has its identifier")
        XCTAssertTrue(app.staticTexts["On-device, No tracking, Open source"].exists,
                      "the trust words are one spoken line")
    }

    /// At the largest accessibility size the first entry is hittable with
    /// no scroll: a door on the first screen.
    func testOpenDocumentOnFirstScreenAtAX5() {
        app.launchArguments = ["--uitesting",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()

        let open = app.buttons["homeOpenDocument"]
        XCTAssertTrue(open.waitForExistence(timeout: 10), "the first entry exists")
        XCTAssertTrue(open.isHittable, "the first entry is whole on the first screen at the largest size")
        let window = app.windows.firstMatch.frame
        XCTAssertLessThanOrEqual(open.frame.maxY, window.maxY, "the first entry ends above the screen's bottom")
    }

    /// The three entries are one card: the same leading edge and width,
    /// and at the default size the same height (each description reserves
    /// two lines, so the one-line sample matches the two-line peers).
    func testEntriesShareOneCardSize() {
        app.launchArguments = ["--uitesting"]
        app.launch()
        let frames = entryFrames()
        guard frames.count == 3 else { return }
        for (id, frame) in frames.dropFirst() {
            XCTAssertEqual(frame.minX, frames[0].frame.minX, accuracy: 1, "\(id) starts on the first card's edge")
            XCTAssertEqual(frame.width, frames[0].frame.width, accuracy: 1, "\(id) is as wide as the first card")
            XCTAssertEqual(frame.height, frames[0].frame.height, accuracy: 1, "\(id) is as tall as the first card")
        }
    }

    /// At the largest accessibility size the entries restack (tile above
    /// the text) and keep one edge and one width; their heights follow
    /// their own wrapped copy.
    func testEntriesShareOneCardWidthAtAX5() {
        app.launchArguments = ["--uitesting",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        let frames = entryFrames()
        guard frames.count == 3 else { return }
        for (id, frame) in frames.dropFirst() {
            XCTAssertEqual(frame.minX, frames[0].frame.minX, accuracy: 1, "\(id) starts on the first card's edge at AX5")
            XCTAssertEqual(frame.width, frames[0].frame.width, accuracy: 1, "\(id) is as wide as the first card at AX5")
        }
    }

    /// The entries' frames in screen order, or a failure when one is missing.
    private func entryFrames() -> [(id: String, frame: CGRect)] {
        var frames: [(id: String, frame: CGRect)] = []
        for id in ["homeOpenDocument", "homeImportPhotos", "homeTrySample"] {
            let button = app.buttons[id]
            guard button.waitForExistence(timeout: 10) else {
                XCTFail("\(id) is on Home")
                return []
            }
            frames.append((id, button.frame))
        }
        return frames
    }
}
