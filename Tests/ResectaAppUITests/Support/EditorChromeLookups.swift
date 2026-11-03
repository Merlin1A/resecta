import XCTest

// Lookups for editor chrome that iOS 27 serves differently in the
// accessibility tree. Each accepts the iOS 26 form unchanged.

extension XCUIApplication {

    /// The editor toolbar's "…" button: the editor's own menu
    /// ("editorMoreMenu"), or the system's where a bar still uses it, which
    /// UIKit names "OverflowBarButtonItem" on iOS 26 and
    /// "TopOverflowBarButtonItem" on iOS 27.
    nonisolated var editorOverflowButton: XCUIElement {
        descendants(matching: .any)
            .matching(NSPredicate(format: "identifier IN %@",
                                  ["editorMoreMenu", "OverflowBarButtonItem", "TopOverflowBarButtonItem"]))
            .firstMatch
    }
}

extension XCUIElement {

    /// Whether the Rectangle tool reads `expected`, its accessibility value
    /// ("Drawing mode active" or "Tap to enter drawing mode"). iOS 27
    /// serves no value for a toolbar button: there the label carries the
    /// on state ("Rectangle, Drawing mode active"), and the glyph's brand
    /// teal is the fallback.
    nonisolated func drawToolReads(_ expected: String) -> Bool {
        if let value = value as? String, !value.isEmpty { return value == expected }
        let active: Bool
        if label.hasSuffix("Drawing mode active") {
            active = true
        } else {
            let shot = XCUIScreen.main.screenshot()
            guard exists, let probe = CanvasPixelProbe(shot, windowSize: shot.image.size) else { return false }
            active = probe.tintBounds(.teal, in: frame) != nil
        }
        return active == (expected == "Drawing mode active")
    }
}
