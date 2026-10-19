import XCTest

// One screenshot attachment helper for the UI test classes. Each class used
// to carry its own private copy of this function; the copies were identical.
// The helper screenshots the test's target application through a fresh
// `XCUIApplication()` proxy, which addresses the same app the class launched,
// so a class keeps its `app` property private and its call sites unchanged.
extension XCTestCase {
    /// Attach a screenshot of the target app to the running test, kept in
    /// the result bundle regardless of the test's outcome.
    nonisolated func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIApplication().screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
