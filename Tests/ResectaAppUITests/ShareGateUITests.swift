import XCTest

/// The share confirm completes only on purpose: the slide, or the
/// accessibility action VoiceOver and Switch Control offer. A tap on the
/// confirm's blank space never opens the share sheet.
///
/// Black-box (no `@testable import`). The seeded results screen
/// (`--seedVerifiedReport=secureSkippedOff --seedOutput`) routes Share
/// through the SKIPPED family's confirm with a live output behind it.
///
/// nonisolated because an XCUITest drives a separate process and touches no
/// @MainActor app state (see `ShareRiskSheetUITests`).
nonisolated final class ShareGateUITests: XCTestCase {

    private var app: XCUIApplication!

    private static let skippedTitle = "Share without verification?"

    /// Blank points of the confirm, as offsets from the bottom-leading
    /// corner of its "Go back" pill: below it and to its left, where the
    /// card has no control. Measured on a 402-pt iPhone (Go back at
    /// x 159, y 777, 84 × 33), a single tap anywhere in x 22–86 × y 800–856
    /// opened the share sheet.
    private static let blankOffsets: [CGVector] = [
        CGVector(dx: -128, dy: 0),
        CGVector(dx: -105, dy: 22),
        CGVector(dx: -137, dy: -10),
        CGVector(dx: -73, dy: 46),
    ]

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDown() {
        app = nil
        super.tearDown()
    }

    func testBlankAreaTapLeavesTheConfirmUp() {
        for offset in Self.blankOffsets {
            openSkippedConfirm()
            let goBack = app.buttons["shareRiskConfirmGoBack"].frame
            app.tapAtScreenPoint(CGPoint(x: goBack.minX + offset.dx, y: goBack.maxY + offset.dy))
            XCTAssertFalse(
                app.shareStarted(within: 3),
                "A tap \(offset) from Go back's bottom-leading corner started a share.")
            XCTAssertTrue(
                app.staticTexts[Self.skippedTitle].exists,
                "The confirm must stay up after a tap \(offset) from Go back.")
        }
    }

    func testSlideShares() {
        openSkippedConfirm()
        app.slideToShare(confirmIdentifier: "shareSkippedConfirm")
        XCTAssertTrue(app.shareStarted(within: 10), "The slide must open the share sheet.")
        attachScreenshot(named: "after-slide")
    }

    // MARK: - Route

    private func openSkippedConfirm() {
        app.terminate()
        app.launchArguments = ["--uitesting", "--seedVerifiedReport=secureSkippedOff", "--seedOutput"]
        app.launch()
        let share = app.buttons
            .matching(NSPredicate(format: "label BEGINSWITH 'Share Document'"))
            .firstMatch
        XCTAssertTrue(share.waitForExistence(timeout: 30), "Share card not found on the seeded results.")
        share.tap()
        XCTAssertTrue(
            app.staticTexts[Self.skippedTitle].waitForExistence(timeout: 10),
            "The skipped confirm never presented.")
        XCTAssertTrue(
            app.buttons["shareRiskConfirmGoBack"].waitForExistence(timeout: 5),
            "Go back never appeared on the confirm.")
    }
}

extension XCUIApplication {
    /// Drag the confirm's slide from its knob to the far end of its track,
    /// the touch path that completes the confirm. The slide is the element
    /// carrying the confirm family's identifier.
    nonisolated func slideToShare(confirmIdentifier: String) {
        let slide = descendants(matching: .any).matching(identifier: confirmIdentifier).firstMatch
        XCTAssertTrue(slide.waitForExistence(timeout: 10), "The slide \(confirmIdentifier) never appeared.")
        let frame = slide.frame
        let knobCentre = frame.minX + frame.height / 2
        let origin = coordinate(withNormalizedOffset: .zero)
        let start = origin.withOffset(CGVector(dx: knobCentre, dy: frame.midY))
        let end = origin.withOffset(CGVector(dx: frame.maxX - 2, dy: frame.midY))
        start.press(forDuration: 0.2, thenDragTo: end)
    }

    /// One tap at a point in screen coordinates.
    nonisolated func tapAtScreenPoint(_ point: CGPoint) {
        coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: point.x, dy: point.y))
            .tap()
    }

    /// Whether a share started within `timeout` seconds: the exporting
    /// card's Cancel or the system share sheet appeared.
    nonisolated func shareStarted(within timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if buttons["cancelExport"].exists
                || otherElements["ActivityListView"].exists
                || cells["Copy"].exists {
                return true
            }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < deadline
        return false
    }
}
