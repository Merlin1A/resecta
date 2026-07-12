import XCTest

/// UI tests for the q17 (UXF-08) first-launch-gate document links.
///
/// The gate ("Before You Begin") offers view-only access to the bundled EULA
/// and Privacy Policy via two link buttons; each opens `LegalDocumentView`
/// read-only and dismissing lands back on the still-un-accepted gate. These
/// tests pin the C-7 property that matters: viewing a document is NOT a path
/// past the gate — after opening and closing both documents the gate still
/// blocks, and only "I Agree" clears it.
///
/// Launch uses the DEBUG `--resetEULA` hook (the inverse of `--uitesting`),
/// which clears `disclaimerAccepted_v1` before the scene body reads it, so
/// each test starts from a virgin gate regardless of what earlier suites did
/// to the shared simulator app container.
// nonisolated: XCUITest driving a separate process, no @MainActor app state —
// same s04 SE-0466 posture as DetectionTriageDismissUITests.
nonisolated final class EULAGateLinksUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--resetEULA"]
        app.launch()
    }

    override func tearDown() {
        app = nil
        super.tearDown()
    }

    /// Open a document from the gate, close it, and require the gate to
    /// still be blocking (accept button present, viewer gone).
    private func openAndDismissDocument(linkIdentifier: String) {
        let accept = app.buttons["eulaAccept"]
        XCTAssertTrue(
            accept.waitForExistence(timeout: 30),
            "EULA gate never presented under --resetEULA — check the launch hook."
        )

        let link = app.buttons[linkIdentifier]
        XCTAssertTrue(
            link.waitForExistence(timeout: 5),
            "Gate document link '\(linkIdentifier)' missing."
        )
        link.tap()

        let done = app.buttons["legalDocumentDone"]
        XCTAssertTrue(
            done.waitForExistence(timeout: 10),
            "LegalDocumentView never presented from '\(linkIdentifier)'."
        )
        done.tap()

        XCTAssertTrue(
            accept.waitForExistence(timeout: 10),
            "Gate did not survive viewing '\(linkIdentifier)' — dismissing the document must land on the un-accepted gate."
        )
        XCTAssertFalse(
            done.exists,
            "LegalDocumentView still on screen after Done."
        )
    }

    func testViewEULAOpensAndReturnsToUnacceptedGate() {
        openAndDismissDocument(linkIdentifier: "eulaViewEULA")
    }

    func testViewPrivacyPolicyOpensAndReturnsToUnacceptedGate() {
        openAndDismissDocument(linkIdentifier: "eulaViewPrivacy")
    }

    /// The full C-7 sequence: view BOTH documents, assert the gate still
    /// blocks, then accept and require the gate to clear — viewing neither
    /// substitutes for nor breaks acceptance.
    func testViewingBothDocumentsDoesNotAcceptAndAgreeStillWorks() {
        openAndDismissDocument(linkIdentifier: "eulaViewEULA")
        openAndDismissDocument(linkIdentifier: "eulaViewPrivacy")

        let accept = app.buttons["eulaAccept"]
        XCTAssertTrue(
            accept.exists,
            "Gate must still require acceptance after viewing both documents."
        )
        accept.tap()

        // Acceptance dismisses the gate view entirely.
        XCTAssertTrue(
            waitForDisappearance(of: accept, timeout: 10),
            "Tapping 'I Agree' no longer clears the gate."
        )
    }

    private func waitForDisappearance(
        of element: XCUIElement, timeout: TimeInterval
    ) -> Bool {
        let predicate = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(
            predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }
}
