import XCTest

/// The result rows' layout: a typed match is the circle, two lines of
/// text and the arrow, 64 pt from the next row; applying a row does not
/// move it; each page's header keeps the page's name as its own text.
///
/// nonisolated: XCUITest driving a separate process, no @MainActor app state.
nonisolated final class SearchRowLayoutUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--loadTestDocument", "--multipageDoc"]
        app.launch()
    }

    override func tearDown() {
        app = nil
        super.tearDown()
    }

    /// Opens Search from the toolbar, types the query, and waits for the
    /// results' footer. Return puts the keyboard away so rows can be tapped.
    private func search(_ query: String) {
        let open = app.buttons["searchRedact"]
        XCTAssertTrue(open.waitForExistence(timeout: 40), "Editor toolbar never appeared.")
        open.tap()
        let field = app.textFields["Search text"]
        XCTAssertTrue(field.waitForExistence(timeout: 15), "Search field never appeared.")
        field.tap()
        field.typeText(query + "\n")
        XCTAssertTrue(app.buttons["footerSelectAllButton"].waitForExistence(timeout: 20),
                      "No results for \(query).")
        sleep(1)
    }

    /// The listed rows, in screen order from the top.
    private func rows() -> [XCUIElement] {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'searchResultRow-'"))
            .allElementsBoundByIndex
            .filter { $0.exists && !$0.frame.isEmpty }
            .sorted { $0.frame.minY < $1.frame.minY }
    }

    func testTypedRows_pitchIsSixtyFour() {
        search("Amount")
        let listed = rows()
        XCTAssertGreaterThanOrEqual(listed.count, 3, "Fewer than three rows are listed.")
        let tops = listed.prefix(3).map { $0.frame.minY }
        for i in 1..<tops.count {
            XCTAssertEqual(tops[i] - tops[i - 1], 64, accuracy: 1,
                           "Rows \(i) and \(i + 1) are \(tops[i] - tops[i - 1]) pt apart.")
        }
    }

    func testApplyingARow_doesNotMoveIt() {
        search("Amount")
        guard let first = rows().first else { return XCTFail("No row is listed.") }
        let identifier = first.identifier
        let before = first.frame.minX
        // The circle is the row's leading 46 pt.
        first.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5))
            .withOffset(CGVector(dx: 23, dy: 0))
            .tap()
        let apply = app.buttons["searchApplyButton"]
        XCTAssertTrue(apply.waitForExistence(timeout: 5), "Apply never appeared.")
        let ticked = apply.label
        XCTAssertNotEqual(ticked, "Apply 0", "The tap on the circle ticked nothing.")
        apply.tap()
        // Apply's count is the ticked rows, and an applied row stays
        // ticked, so the mark's own notice says the apply happened.
        let marked = app.staticTexts.matching(NSPredicate(format: #"label BEGINSWITH "Marked""#)).firstMatch
        XCTAssertTrue(marked.waitForExistence(timeout: 10), "The apply posted no Marked notice.")
        sleep(1)
        let row = app.descendants(matching: .any)[identifier]
        XCTAssertTrue(row.waitForExistence(timeout: 5), "The applied row is no longer listed.")
        XCTAssertEqual(row.frame.minX, before, accuracy: 0.5, "Applying the row moved it sideways.")
    }

    func testPageHeader_keepsItsNameAsItsOwnText() {
        search("Amount")
        let name = app.staticTexts["Page 1"]
        XCTAssertTrue(name.waitForExistence(timeout: 10), "The page header's name is not its own text.")
        XCTAssertTrue(name.isHittable, "The page header's name is not on screen.")
    }
}
