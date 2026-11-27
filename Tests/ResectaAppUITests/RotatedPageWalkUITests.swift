import XCTest

/// The result walk on a turned page: the clear-page fixture shown a quarter
/// turned (`--clearPageTurnedDoc`, UITestFixtures/uitest_clear_page_turned.pdf,
/// 684 × 540 as displayed, its crop box offset), whose one word "Wrenlowe" sits
/// off the centre on both axes, at the share (0.35, 0.65): there a wrong map of
/// a turned page and the right one disagree. One step of the walk frames the
/// match readably and puts it where the framing's own rule puts it.
///
/// nonisolated for the same reason as `ResultWalkUITests`.
nonisolated final class RotatedPageWalkUITests: XCTestCase {

    private var app: XCUIApplication!

    /// The page as displayed, in points.
    static let page = CGSize(width: 684, height: 540)
    /// The word's centre as displayed, from the page's left and top edges.
    static let word = CGPoint(x: 239, y: 540 - 351)
    /// The word's box width in page points: Helvetica's advances for
    /// "Wrenlowe" at 12 pt (4,445 / 1000 × 12), as `UITestClearPageFixtureTests`
    /// pins it to within half a point.
    static let wordWidth: CGFloat = 53.34
    /// The ring is the match's box outset 3 points each side and stroked 2
    /// wide, in screen points at every zoom (`searchMarkStrokes`), so its
    /// outer edge lies 4 screen points outside the box on each side.
    static let ringPad: CGFloat = 8

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = [
            "--uitesting", "--loadTestDocument", "--clearPageTurnedDoc",
            "--openSearchSheet", "--searchQuery=Wrenlowe", "--searchDetent=compact",
        ]
    }

    override func tearDown() {
        app = nil
        super.tearDown()
    }

    /// Where the framing puts the word on one axis, in screen points: the
    /// visible area's leading edge is the word's centre less half the band ÷
    /// s, held to 0 … page − band ÷ s (`centeringDestinationPoint`).
    static func expectedOnScreen(centre c: CGFloat, page p: CGFloat, bandStart: CGFloat, bandLength: CGFloat,
                                 scale s: CGFloat) -> CGFloat {
        let seen = bandLength / s
        let leading = min(max(c - seen / 2, 0), max(0, p - seen))
        return bandStart + (c - leading) * s
    }

    func testNextFramesTheMatchOnTheTurnedPage() throws {
        app.launch()
        let next = app.buttons["resultNavNext"]
        XCTAssertTrue(next.waitForExistence(timeout: 30),
                      "The seeded query returned nothing or the sheet never presented — check the --clearPageTurnedDoc launch hook.")
        next.tap()
        XCTAssertTrue(RingCentre.compactStrip(app).waitForExistence(timeout: 10), "The next arrow did not park the sheet.")

        var scale: CGFloat = 0
        let ring = try RingCentre.assertRingCentred(app, step: "1 (the one match, turned page)") { band, window, ring in
            // s from the ring's width: the word's width × s + the ring's pad.
            let s = (ring.width - Self.ringPad) / Self.wordWidth
            scale = s
            return CGPoint(
                x: Self.expectedOnScreen(centre: Self.word.x, page: Self.page.width, bandStart: window.minX,
                                         bandLength: window.width, scale: s),
                y: Self.expectedOnScreen(centre: Self.word.y, page: Self.page.height, bandStart: band.lowerBound,
                                         bandLength: band.upperBound - band.lowerBound, scale: s))
        }
        let box = try XCTUnwrap(ring, "No ring to measure.")
        let band = RingCentre.canvasBand(app)
        let window = app.windows.firstMatch.frame
        XCTAssertTrue(box.minY >= band.lowerBound && box.maxY <= band.upperBound
                        && box.minX >= window.minX && box.maxX <= window.maxX,
                      "The outlined match \(box) is not inside the visible canvas (band \(band)).")
        let matchHeight = box.height - Self.ringPad
        XCTAssertGreaterThanOrEqual(matchHeight, 15, "The match is \(matchHeight) pt tall on screen (s = \(scale)): not framed readably.")
        attachScreenshot(named: "rpw-turned-page-framed")
    }
}
