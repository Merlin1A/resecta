import XCTest

/// The Findings group on the seeded needs-review report with the most in it
/// (`searchableAttentionFull`), over the bundled multi-page fixture with a
/// copy of it standing in for the redacted PDF (`--seedOutput`), so page
/// chips show and open the Preview. The first row exists; a tap opens it;
/// its first page chip opens the Preview; and a tap 21 pt above that chip's
/// centre, inside its 46-pt hit frame but above its drawn 26-pt shape, opens
/// the Preview too. (XCUITest lists the closed row's chips under its one
/// button element; VoiceOver reaches only the button, so the case reads the
/// button's label, not the count of what lies under it.)
///
/// nonisolated because an XCUITest drives a separate process and touches
/// no @MainActor app state (SE-0466; see `ShareRiskSheetUITests`).
nonisolated final class FindingRowUITests: XCTestCase {

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

    func testFirstRowOpensAndItsChipOpensThePreview() {
        app.launchArguments = ["--uitesting", "--multipageDoc", "--seedVerifiedReport=searchableAttentionFull",
                               "--seedOutput"]
        app.launch()
        XCTAssertTrue(element("verificationResults").waitForExistence(timeout: 30),
                      "The seeded results screen never appeared.")

        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'finding_'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "The Findings group has no row.")
        // Closed, the row is one button: its main line and its pages, and
        // none of the document's words (the seeded words are Delia and Marco).
        let main = row.buttons.firstMatch
        XCTAssertTrue(main.waitForExistence(timeout: 5), "The closed row is not a button.")
        XCTAssertTrue(main.label.hasSuffix("Pages 2 and 3."), "The closed row's label is \"\(main.label)\".")
        XCTAssertFalse(main.label.contains("Delia") || main.label.contains("Marco"),
                       "The closed row's spoken label carries the document's words.")

        // Open the row on its main line, 22 pt under the row's top. Measured
        // on iOS 26.4: a tap at the closed row's centre, on its words' line
        // 11 pt above the second chip's 46-pt hit frame, opens the Preview.
        main.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0)).withOffset(CGVector(dx: 0, dy: 22)).tap()
        let chips = row.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Go to page'"))
        let chip = chips.firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 5), "The opened row shows no page chip.")
        let page = chip.label

        // The chip itself.
        chip.tap()
        assertPreviewOpens(after: "a tap on \(page)")
        goBack()

        // 21 pt above the chip's centre: 8 pt above its drawn top edge, 2 pt
        // inside its hit frame. The first line of chips only.
        let again = row.buttons.matching(NSPredicate(format: "label == %@", page)).firstMatch
        XCTAssertTrue(again.waitForExistence(timeout: 10), "The opened row lost its chip after the Preview.")
        again.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).withOffset(CGVector(dx: 0, dy: -21)).tap()
        assertPreviewOpens(after: "a tap 21 pt above \(page)")
    }

    // MARK: - Helpers

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func assertPreviewOpens(after what: String) {
        let preview = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier IN %@", ["redactedPreview", "redactedPreviewLoading"])).firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 10), "The Preview did not open after \(what).")
    }

    private func goBack() {
        let back = app.navigationBars.buttons.firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 5), "No back button on the Preview.")
        back.tap()
        XCTAssertTrue(element("verificationResults").waitForExistence(timeout: 10), "The results screen did not return.")
    }
}
