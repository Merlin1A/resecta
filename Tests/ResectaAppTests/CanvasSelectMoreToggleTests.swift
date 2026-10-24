import Testing
import Foundation
@testable import ResectaApp

// iPhone "Select More" toolbar toggle. The toggle
// flag layers on top of the existing iPad Shift+tap selection model:
// when EITHER input route signals "add to selection", the touchesBegan
// branch routes through `coordinator?.toggleRegionSelection(_:)`. Tests
// pin the predicate's OR shape + the label's count-surfacing shape so
// future refactors that drift either contract surface as a test break.

@Suite("Canvas Select More toggle")
@MainActor
struct CanvasSelectMoreToggleTests {

    // MARK: - Toggle predicate (touchesBegan branch)

    @Test("Off + no Shift → tap follows the replace-selection path")
    func neitherInputRoutesThroughReplace() {
        #expect(RedactionOverlayView.shouldToggleSelection(
            isMultiSelectActive: false, shiftHeld: false
        ) == false)
    }

    @Test("iPad Shift+tap survives whether the toggle is off or on")
    func shiftHoldAlwaysRoutesThroughToggle() {
        // Invariant: iPad Shift+tap continues to work — no
        // parallel code path. The toggle layers on top, not in place of.
        #expect(RedactionOverlayView.shouldToggleSelection(
            isMultiSelectActive: false, shiftHeld: true
        ) == true)
        #expect(RedactionOverlayView.shouldToggleSelection(
            isMultiSelectActive: true, shiftHeld: true
        ) == true)
    }

    @Test("iPhone toggle on routes a no-shift tap through the toggle branch")
    func toggleAloneRoutesThroughToggle() {
        // The iPhone parity path — the toolbar toggle stands in for the
        // Shift modifier that iPad keyboard users have access to.
        #expect(RedactionOverlayView.shouldToggleSelection(
            isMultiSelectActive: true, shiftHeld: false
        ) == true)
    }

    // MARK: - Toggle label

    @Test("The toggle row reads its bare name; the On/Off state carries the rest")
    func toggleRowReadsItsBareName() {
        #expect(RedactionOverlayView.selectMoreToggleTitle == "Add to Selection")
    }

    // MARK: - Default state

    @Test("Overlay's multi-select flag defaults to off so the legacy path is the default")
    func overlayDefaultsOff() {
        let overlay = RedactionOverlayView()
        #expect(overlay.isMultiSelectActive == false)
    }

    @Test("Setting the flag on the overlay is read back in lock-step")
    func overlayFlagRoundTrips() {
        let overlay = RedactionOverlayView()
        overlay.isMultiSelectActive = true
        #expect(overlay.isMultiSelectActive == true)
        overlay.isMultiSelectActive = false
        #expect(overlay.isMultiSelectActive == false)
    }
}
