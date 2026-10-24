import XCTest

/// The canvas's regions in the accessibility tree. The overlay builds one
/// element per region ("Redaction region N", with a hint to select or
/// delete it), but the page view PDFKit hosts the overlay in served none of
/// them, so VoiceOver could not reach a region, the whole-page cover or its
/// Delete. With a whole-page region and a drawn box on the page, both must
/// be in the tree, on the page.
///
/// nonisolated: an XCUITest drives a separate process and touches no
/// @MainActor state.
nonisolated final class CanvasRegionAccessibilityUITests: XCTestCase {

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

    func testRegionsAreInTheAccessibilityTree() {
        let mark = app.buttons["pageNavMarkWholePage"]
        XCTAssertTrue(mark.waitForExistence(timeout: 10))
        mark.tap()
        XCTAssertTrue(waitForRegionCount(1), "Mark Whole Page added a region")

        let tool = app.buttons["drawTool"]
        tool.tap()
        XCTAssertTrue(waitForValue(tool, "Drawing mode active"))
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.30, dy: 0.40))
            .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.60, dy: 0.47)),
                   withVelocity: .slow, thenHoldForDuration: 0.2)
        tool.tap()
        XCTAssertTrue(waitForValue(tool, "Tap to enter drawing mode"))
        XCTAssertTrue(waitForRegionCount(2), "the box drew")

        let regions = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Redaction region'"))
        XCTAssertTrue(regions.firstMatch.waitForExistence(timeout: 10), "the regions are in the accessibility tree")
        XCTAssertEqual(regions.count, 2, "one element per region")
        let page = window.frame
        for element in regions.allElementsBoundByIndex {
            XCTAssertTrue(page.intersects(element.frame), "\(element.label) lies on screen: \(element.frame)")
        }
    }
}

private extension CanvasRegionAccessibilityUITests {

    nonisolated func waitForValue(_ element: XCUIElement, _ value: String, timeout: TimeInterval = 6) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if (element.value as? String) == value { return true }
            usleep(250_000)
        }
        return false
    }

    nonisolated func waitForRegionCount(_ n: Int, timeout: TimeInterval = 8) -> Bool {
        let counter = app.descendants(matching: .any).matching(identifier: "pageNavCounter").firstMatch
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if counter.exists, let match = counter.label.range(of: #"(\d+) regions?"#, options: .regularExpression),
               Int(counter.label[match].split(separator: " ").first ?? "") == n { return true }
            usleep(250_000)
        }
        return false
    }
}
