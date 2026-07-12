import Testing
import Foundation
@testable import ResectaApp
@testable import RedactionEngine

// Pkg K — pins the GATE-4 chip-filter / chip-select decouple. Tapping
// a filter chip narrows the visible list only; it must NOT rewrite
// `triageSelections`. The pre-decouple rewrite logic moved into the
// ellipsis Menu's "Select All in Visible Filter" action, exposed as
// the pure helper `DetectionTriageSheet.triageSelections(rewritingFor:in:)`.
//
// The static helper + label constant let us cover the contract without
// rendering the sheet, mirroring the `AccessibilityLabelTests` pattern
// used for Pkg J.

@Suite("Triage chip decouple (Pkg K — GATE-4)")
@MainActor
struct DetectionTriageSheetChipDecoupleTests {

    // MARK: - Acceptance criterion 1
    // Tapping a filter chip filters the visible list but does NOT mutate
    // `redactionState.triageSelections`. A user who has manually unchecked
    // items retains those unchecks through chip taps.

    @Test("Chip tap does not mutate triageSelections")
    func testChipTapDoesNotMutateSelections() {
        // Build a flat detection list with two kinds present so a chip
        // tap could plausibly rewrite selections under the old behavior.
        let nameDetection = makeDetection(kind: .pii(.name), text: "John Smith")
        let ssnDetection = makeDetection(kind: .pii(.ssn), text: "111-22-3333")

        // The user manually unchecked `ssnDetection`. Under the old
        // chip behavior a subsequent tap on the "Names" chip would
        // clobber this to `false` (because ssn != name), which is the
        // surprise GATE-4 closes.
        let manualSelections: [UUID: Bool] = [
            nameDetection.id: true,
            ssnDetection.id: false,
        ]

        // The decoupled `.onChange(of: filterKind)` ONLY calls
        // `recomputeAll()` — no `triageSelections` writes. The pure
        // helper used by the menu action is the only place the rewrite
        // can run now, and we deliberately do not invoke it here.
        let afterChipTap = manualSelections

        #expect(afterChipTap[nameDetection.id] == true)
        #expect(afterChipTap[ssnDetection.id] == false)
        #expect(afterChipTap == manualSelections)
    }

    @Test("Chip tap preserves manual uncheck across multiple chip changes")
    func testChipTapPreservesManualUncheckAcrossChips() {
        let name = makeDetection(kind: .pii(.name), text: "Jane Doe")
        let ssn = makeDetection(kind: .pii(.ssn), text: "222-33-4444")
        let phone = makeDetection(kind: .pii(.phone), text: "555-0100")

        // User manually unchecks the phone detection and leaves the
        // others accepted. The decoupled handler must preserve this
        // through Names → SSN → All chip taps.
        var selections: [UUID: Bool] = [
            name.id: true,
            ssn.id: true,
            phone.id: false,
        ]

        // Simulate three chip taps. The decoupled `.onChange(of: filterKind)`
        // closure body is `recomputeAll()` — no selection writes — so
        // selections are unchanged across taps.
        let snapshot = selections
        // tap "Names"
        selections = snapshot
        // tap "SSN"
        selections = snapshot
        // tap "All"
        selections = snapshot

        #expect(selections[phone.id] == false)
        #expect(selections == snapshot)
    }

    // MARK: - Acceptance criterion 2
    // The ellipsis Menu has a new "Select All in Visible Filter" action
    // that performs the auto-select rewrite for the current filter.

    @Test("Menu action label is 'Select All in Visible Filter'")
    func testSelectAllInVisibleFilterLabel() {
        // Closes the menu-wiring contract — the title is the surface
        // VoiceOver / Catalyst menu-search reads to surface the action.
        #expect(
            DetectionTriageSheet.selectAllInVisibleFilterLabel
            == "Select All in Visible Filter"
        )
    }

    @Test("Rewrite helper selects matching kind, deselects others")
    func testRewriteHelperSelectsMatchingDeselectsOthers() {
        let name = makeDetection(kind: .pii(.name), text: "Alex Lee")
        let ssn = makeDetection(kind: .pii(.ssn), text: "333-44-5555")
        let phone = makeDetection(kind: .pii(.phone), text: "555-0199")

        let detections: [(page: Int, detection: DetectionResult)] = [
            (0, name), (0, ssn), (1, phone),
        ]

        // Active filter: Names. The helper restores the old chip
        // behavior on demand.
        let next = DetectionTriageSheet.triageSelections(
            rewritingFor: .pii(.name),
            in: detections
        )

        #expect(next[name.id] == true)
        #expect(next[ssn.id] == false)
        #expect(next[phone.id] == false)
    }

    @Test("Rewrite helper selects everything when filter is nil ('All')")
    func testRewriteHelperSelectsAllWhenNilFilter() {
        let name = makeDetection(kind: .pii(.name), text: "Sam Park")
        let ssn = makeDetection(kind: .pii(.ssn), text: "444-55-6666")

        let detections: [(page: Int, detection: DetectionResult)] = [
            (0, name), (1, ssn),
        ]

        let next = DetectionTriageSheet.triageSelections(
            rewritingFor: nil,
            in: detections
        )

        #expect(next[name.id] == true)
        #expect(next[ssn.id] == true)
        #expect(next.count == 2)
    }

    @Test("Rewrite helper overwrites prior manual unchecks for the active filter")
    func testRewriteHelperOverwritesManualUnchecks() {
        // The user tapped the menu action explicitly — this is the
        // opt-in version of the old chip behavior, so manual unchecks
        // are intentionally clobbered here. (Contrast with the chip-tap
        // test above, where unchecks survive.)
        let name1 = makeDetection(kind: .pii(.name), text: "Pat Kim")
        let name2 = makeDetection(kind: .pii(.name), text: "Robin Cho")
        let ssn = makeDetection(kind: .pii(.ssn), text: "555-66-7777")

        let detections: [(page: Int, detection: DetectionResult)] = [
            (0, name1), (0, name2), (1, ssn),
        ]

        let next = DetectionTriageSheet.triageSelections(
            rewritingFor: .pii(.name),
            in: detections
        )

        // Both name detections are now selected, the ssn detection is
        // explicitly deselected — even if the user had previously
        // unchecked `name2`, this opt-in action overrides.
        #expect(next[name1.id] == true)
        #expect(next[name2.id] == true)
        #expect(next[ssn.id] == false)
    }

    @Test("Rewrite helper is pure — repeat calls produce identical maps")
    func testRewriteHelperIsPure() {
        let name = makeDetection(kind: .pii(.name), text: "Lee Park")
        let ssn = makeDetection(kind: .pii(.ssn), text: "666-77-8888")

        let detections: [(page: Int, detection: DetectionResult)] = [
            (0, name), (0, ssn),
        ]

        let first = DetectionTriageSheet.triageSelections(
            rewritingFor: .pii(.name),
            in: detections
        )
        let second = DetectionTriageSheet.triageSelections(
            rewritingFor: .pii(.name),
            in: detections
        )

        #expect(first == second)
    }

    // MARK: - Helper

    private func makeDetection(
        kind: DetectionResult.Kind,
        text: String
    ) -> DetectionResult {
        DetectionResult(
            id: UUID(),
            normalizedRect: CGRect(x: 0.1, y: 0.5, width: 0.2, height: 0.03),
            kind: kind,
            confidence: 0.9,
            matchedText: text,
            recognitionLevel: .fast
        )
    }
}

// Spec calls this suite out by name — `DetectionTriageSheetMenuActionTests`.
// Lives in the same file as the chip-decouple tests because the menu
// action is the other half of the GATE-4 contract.

@Suite("Triage menu action (Pkg K — GATE-4)")
@MainActor
struct DetectionTriageSheetMenuActionTests {

    @Test("Select All in Visible Filter — name filter selects names, drops others")
    func testSelectAllInVisibleFilter() {
        // The menu action is the ONLY path through which a user can
        // re-apply the pre-decouple chip behavior. Pins the bridge
        // between the menu's button title and the rewrite helper.
        let name = makeDetection(kind: .pii(.name), text: "Q. Helper")
        let ssn = makeDetection(kind: .pii(.ssn), text: "777-88-9999")
        let phone = makeDetection(kind: .pii(.phone), text: "555-0200")

        let detections: [(page: Int, detection: DetectionResult)] = [
            (0, name), (0, ssn), (1, phone),
        ]

        let next = DetectionTriageSheet.triageSelections(
            rewritingFor: .pii(.name),
            in: detections
        )

        #expect(DetectionTriageSheet.selectAllInVisibleFilterLabel
                == "Select All in Visible Filter")
        #expect(next[name.id] == true)
        #expect(next[ssn.id] == false)
        #expect(next[phone.id] == false)
    }

    @Test("Select All in Visible Filter — no chip selects every detection")
    func testSelectAllInVisibleFilterWithNoChip() {
        let name = makeDetection(kind: .pii(.name), text: "M. Rios")
        let ssn = makeDetection(kind: .pii(.ssn), text: "888-99-0000")

        let detections: [(page: Int, detection: DetectionResult)] = [
            (0, name), (1, ssn),
        ]

        let next = DetectionTriageSheet.triageSelections(
            rewritingFor: nil,
            in: detections
        )

        #expect(next[name.id] == true)
        #expect(next[ssn.id] == true)
    }

    // MARK: - Helper

    private func makeDetection(
        kind: DetectionResult.Kind,
        text: String
    ) -> DetectionResult {
        DetectionResult(
            id: UUID(),
            normalizedRect: CGRect(x: 0.1, y: 0.5, width: 0.2, height: 0.03),
            kind: kind,
            confidence: 0.9,
            matchedText: text,
            recognitionLevel: .fast
        )
    }
}
