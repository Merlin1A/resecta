import Testing
import Foundation
@testable import ResectaApp

// WU-38 — iPhone "Select More" toolbar toggle. The toggle
// flag layers on top of the existing iPad Shift+tap selection model:
// when EITHER input route signals "add to selection", the touchesBegan
// branch routes through `coordinator?.toggleRegionSelection(_:)`. Tests
// pin the predicate's OR shape + the label's count-surfacing shape so
// future refactors that drift either contract surface as a test break.

@Suite("Canvas Select More toggle (WU-38)")
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
        // Invariant from WU-38: iPad Shift+tap continues to work — no
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

    // MARK: - Toggle label (selection count surfacing)

    @Test("Label hides the count when nothing is selected")
    func labelHidesZeroCount() {
        #expect(RedactionOverlayView.selectMoreToggleLabel(selectedCount: 0)
                == "Add to Selection")
    }

    @Test("Label surfaces the running count in lock-step with selection size")
    func labelSurfacesRunningCount() {
        #expect(RedactionOverlayView.selectMoreToggleLabel(selectedCount: 1)
                == "Add to Selection (1)")
        #expect(RedactionOverlayView.selectMoreToggleLabel(selectedCount: 7)
                == "Add to Selection (7)")
        #expect(RedactionOverlayView.selectMoreToggleLabel(selectedCount: 42)
                == "Add to Selection (42)")
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
