import XCTest

/// UI tests for the result walk's chrome on the parked Search sheet:
/// the page bar steps aside while a walk is live at the compact float
/// and returns on expand; each step centres the current match's ring
/// in the visible canvas (pixel-measured — the ring is not served
/// through AX); and the parked strip's controls meet the 44-pt
/// effective floor inside the attached sheet. All three drive the
/// multipage fixture with the seeded "Amount" query at the medium
/// detent (an arrival raise may lift it to large — either is a valid
/// start for the first chevron tap).
///
/// nonisolated for the same reason as `SearchDetentLayoutUITests`: an
/// XCUITest drives a separate process and touches no @MainActor state.
nonisolated final class ResultWalkUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = [
            "--uitesting", "--loadTestDocument", "--multipageDoc",
            "--openSearchSheet", "--searchQuery=Amount", "--searchDetent=medium",
        ]
    }

    override func tearDown() {
        app = nil
        super.tearDown()
    }

    // MARK: - The page bar steps aside

    func testWalkStep_hidesPageBarAtCompactAndRestoresOnExpand() {
        app.launch()
        let next = app.buttons["resultNavNext"]
        XCTAssertTrue(next.waitForExistence(timeout: 30), "The seeded query returned nothing or the sheet never presented.")
        let pageBar = app.descendants(matching: .any).matching(identifier: "pageNav").firstMatch
        XCTAssertTrue(pageBar.waitForExistence(timeout: 10), "The page bar must be mounted on the multipage fixture before the walk parks the sheet.")

        next.tap()
        XCTAssertTrue(compactStrip.waitForExistence(timeout: 10), "The first chevron tap did not park the sheet at the compact float.")
        XCTAssertTrue(
            pageBar.waitForNonExistence(timeout: 10),
            "The page bar must step aside while the walk is live at the compact float."
        )
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Result 1 of ")).firstMatch.exists,
            "The walk did not land on result 1."
        )
        attachScreenshot(named: "rw-page-bar-hidden")

        expandCompactStripToMedium()
        XCTAssertTrue(
            pageBar.waitForExistence(timeout: 10),
            "The page bar must return once the sheet leaves the compact float."
        )
        attachScreenshot(named: "rw-page-bar-restored")
    }

    // MARK: - The match is centred

    /// Three steps including a page crossing (▲ from result 1 wraps to
    /// the last result on the last page): the ring's centre sits within
    /// 12 pt of the visible canvas's centre every time. The ring is
    /// pixel-measured on a screenshot: the brand-teal stroke is the only
    /// teal inside the canvas band (black-on-white fixture text).
    func testWalkStep_centresTheRingInTheVisibleCanvas() throws {
        app.launch()
        let next = app.buttons["resultNavNext"]
        XCTAssertTrue(next.waitForExistence(timeout: 30), "The seeded query returned nothing or the sheet never presented.")
        next.tap()
        XCTAssertTrue(compactStrip.waitForExistence(timeout: 10), "The first chevron tap did not park the sheet.")
        let prev = app.buttons["resultNavPrevious"]
        let compactNext = app.buttons["resultNavNext"]
        XCTAssertTrue(prev.waitForExistence(timeout: 5) && compactNext.exists, "The parked strip's chevrons are missing.")

        try assertRingCentred(step: "1 (result 1, page 1)")
        compactNext.tap()
        try assertRingCentred(step: "2 (result 2, page 1)")
        prev.tap()
        prev.tap()
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Result 644 of ")).firstMatch.waitForExistence(timeout: 10),
            "The second ▲ did not wrap the walk to the last result."
        )
        try assertRingCentred(step: "3 (result 644, page 23 — a page crossing)")
        attachScreenshot(named: "rw-centred-page-crossing")
    }

    // MARK: - The effective floor

    /// The parked strip's controls are measured in screen points, so
    /// the sheet's render scale is already applied.
    func testCompactStrip_controlsMeetTheEffectiveFloor() {
        app.launch()
        let next = app.buttons["resultNavNext"]
        XCTAssertTrue(next.waitForExistence(timeout: 30), "The seeded query returned nothing or the sheet never presented.")
        next.tap()
        XCTAssertTrue(compactStrip.waitForExistence(timeout: 10), "The first chevron tap did not park the sheet.")
        let apply = app.buttons["applyCurrentResultButton"]
        let prev = app.buttons["resultNavPrevious"]
        let compactNext = app.buttons["resultNavNext"]
        XCTAssertTrue(apply.waitForExistence(timeout: 5) && prev.exists && compactNext.exists, "The parked strip's controls are missing.")
        let line = app.descendants(matching: .any).matching(identifier: "walkMatchLine").firstMatch
        XCTAssertTrue(line.waitForExistence(timeout: 5), "The match line is missing from the parked strip.")
        for (name, element) in [("Apply", apply), ("previous chevron", prev), ("next chevron", compactNext)] {
            XCTAssertGreaterThanOrEqual(element.frame.height, 44, "\(name) height \(element.frame.height) is under the 44-pt effective floor.")
            XCTAssertGreaterThanOrEqual(element.frame.width, 44, "\(name) width \(element.frame.width) is under the 44-pt effective floor.")
        }
        attachScreenshot(named: "rw-strip-floor")
    }

    // MARK: - Helpers

    private var compactStrip: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "compactFloatStrip").firstMatch
    }

    /// Grabber drag from the parked strip up to the medium detent —
    /// `SearchDetentLayoutUITests`' idiom.
    private func expandCompactStripToMedium() {
        let window = app.windows.firstMatch
        for _ in 0..<3 {
            let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95))
            let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
            start.press(forDuration: 0.1, thenDragTo: end)
            let dismiss = app.buttons["searchDismissButton"].firstMatch
            if dismiss.waitForExistence(timeout: 3) {
                let headerY = dismiss.frame.minY
                if headerY > window.frame.height * 0.3 && headerY < window.frame.height * 0.7 { return }
                if headerY <= window.frame.height * 0.3 { return }
            }
        }
        XCTFail("The grabber drag did not leave the compact float.")
    }

    /// The visible canvas band: from the toolbar's bottom edge to the
    /// parked sheet's top (the strip's frame less the grabber inset).
    private func canvasBand() -> ClosedRange<CGFloat> {
        let navBar = app.navigationBars.firstMatch
        let top: CGFloat = navBar.exists ? navBar.frame.maxY : 116
        let bottom = compactStrip.frame.minY - 14
        return top...bottom
    }

    private func assertRingCentred(step: String, file: StaticString = #filePath, line: UInt = #line) throws {
        sleep(2)
        let band = canvasBand()
        let window = app.windows.firstMatch
        guard let ring = try ringCentre(in: band, windowWidth: window.frame.width) else {
            XCTFail("Step \(step): no teal ring found in the canvas band \(band).", file: file, line: line)
            return
        }
        let expected = CGPoint(x: window.frame.midX, y: (band.lowerBound + band.upperBound) / 2)
        XCTAssertLessThanOrEqual(abs(ring.y - expected.y), 12, "Step \(step): ring centre y \(ring.y) is off the visible-canvas centre \(expected.y).", file: file, line: line)
        XCTAssertLessThanOrEqual(abs(ring.x - expected.x), 12, "Step \(step): ring centre x \(ring.x) is off the visible-canvas centre \(expected.x).", file: file, line: line)
    }

    /// The bounding-box centre (screen points) of brand-teal pixels
    /// inside the band, or nil when none.
    private func ringCentre(in band: ClosedRange<CGFloat>, windowWidth: CGFloat) throws -> CGPoint? {
        let image = XCUIScreen.main.screenshot().image
        guard let cg = image.cgImage, let provider = cg.dataProvider, let data = provider.data,
              let bytes = CFDataGetBytePtr(data) else { return nil }
        let scale = CGFloat(cg.width) / windowWidth
        let bytesPerRow = cg.bytesPerRow, bytesPerPixel = cg.bitsPerPixel / 8
        let alphaFirst = cg.alphaInfo == .premultipliedFirst || cg.alphaInfo == .first || cg.alphaInfo == .noneSkipFirst
        let littleEndian = cg.bitmapInfo.contains(.byteOrder32Little)
        // BGRA (little-endian, alpha first) vs RGBA (big-endian, alpha last).
        let rOffset = (littleEndian && alphaFirst) ? 2 : 0
        let bOffset = (littleEndian && alphaFirst) ? 0 : 2
        let y0 = max(0, Int(band.lowerBound * scale)), y1 = min(cg.height, Int(band.upperBound * scale))
        var minX = Int.max, maxX = -1, minY = Int.max, maxY = -1
        var y = y0
        while y < y1 {
            var x = 0
            while x < cg.width {
                let p = y * bytesPerRow + x * bytesPerPixel
                let r = Int(bytes[p + rOffset]), g = Int(bytes[p + 1]), b = Int(bytes[p + bOffset])
                if b - r > 50 && g - r > 50 && r < 90 && g >= 70 && g <= 175 && b >= 80 && b <= 190 {
                    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                }
                x += 2
            }
            y += 2
        }
        guard maxX >= 0 else { return nil }
        return CGPoint(x: CGFloat(minX + maxX) / 2 / scale, y: CGFloat(minY + maxY) / 2 / scale)
    }

    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
