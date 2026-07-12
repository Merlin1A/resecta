import Testing
import Foundation
import CoreGraphics
import RedactionEngine
@testable import ResectaApp

// DRAW-4 — Cross-page entity linking. Tests the locked normalize-and-
// exact-match clustering across all PII categories and the atomic
// "accept group" undo behavior in `RedactionState.applyEntityGroup`.
//
// Decision references:
//   - plan.md §4 DRAW-4
//   - decisions.md Batch 7 Q2 (normalize-and-exact-match over fuzzy)
//
// Hard stops these tests pin:
//   - Clustering is **within the same PII category only** — same canonical
//     text across categories does not merge.
//   - Group accept is atomic in the undo manager: one undo() removes
//     every region the group apply created.
//   - The triage sheet exposes a "Grouped" view mode peer to byPage /
//     byType / byConfidence (four view modes total).

@Suite("Cross-page entity linking (DRAW-4)")
@MainActor
struct CrossPageEntityLinkingTests {

    // MARK: - Test fixtures

    /// Build a `DetectionResult` with the given matched text on `page` for
    /// the given PII kind. Confidence defaults to 0.9 so the confidence
    /// slider in tests does not silently exclude the result.
    private func makeDetection(
        page: Int,
        kind: RedactionRegion.PIIKind,
        matchedText: String,
        confidence: Double = 0.9
    ) -> DetectionResult {
        DetectionResult(
            normalizedRect: CGRect(
                x: 0.1,
                y: 0.1 + Double(page) * 0.05,
                width: 0.3,
                height: 0.03
            ),
            kind: .pii(kind),
            confidence: confidence,
            matchedText: matchedText,
            recognitionLevel: .accurate
        )
    }

    /// Seed `pendingTriage` from a list of (page, kind, matchedText)
    /// triples. Returns the detection IDs in insertion order so tests
    /// can correlate clusters back to the source detections.
    @discardableResult
    private func seedPending(
        _ state: RedactionState,
        items: [(page: Int, kind: RedactionRegion.PIIKind, text: String)]
    ) -> [UUID] {
        var pending: [Int: [DetectionResult]] = [:]
        var ids: [UUID] = []
        for item in items {
            let detection = makeDetection(
                page: item.page, kind: item.kind, matchedText: item.text
            )
            pending[item.page, default: []].append(detection)
            ids.append(detection.id)
        }
        state.pendingTriage = pending
        // Mirror PipelineCoordinator's post-detection write: triage
        // defaults to "accepted" so the applyEntityGroup path can be
        // exercised without further setup.
        for id in ids { state.triageSelections[id] = true }
        return ids
    }

    // MARK: - 1. Same entity across pages clusters into one group

    @Test("Same name on pages 1, 3, 5 clusters into exactly one group with 3 IDs")
    func testSameEntityAcrossPagesClustered() {
        let state = RedactionState()
        seedPending(state, items: [
            (page: 1, kind: .name, text: "John Doe"),
            (page: 3, kind: .name, text: "John Doe"),
            (page: 5, kind: .name, text: "John Doe"),
            // A second, distinct name so the group filter is exercised.
            (page: 2, kind: .name, text: "Jane Smith")
        ])

        let groups = CrossPageEntityGroup.clusters(from: state.pendingTriage ?? [:])

        // Exactly one cluster for "John Doe" — Jane Smith is a singleton
        // and singletons are intentionally omitted from the Grouped view.
        #expect(groups.count == 1)
        guard let group = groups.first else {
            Issue.record("Expected at least one group")
            return
        }
        #expect(group.canonicalText == "johndoe")
        #expect(group.category == .name)
        #expect(group.pages == [1, 3, 5])
        #expect(group.detectionIDs.count == 3)
    }

    // MARK: - 2. Normalization collapses whitespace and case

    @Test("'John   Doe', 'john doe', 'JOHN DOE!' all cluster into one group")
    func testNormalizationCollapsesWhitespaceAndCase() {
        let state = RedactionState()
        seedPending(state, items: [
            (page: 0, kind: .name, text: "John   Doe"),
            (page: 1, kind: .name, text: "john doe"),
            (page: 2, kind: .name, text: "JOHN DOE!")
        ])

        let groups = CrossPageEntityGroup.clusters(from: state.pendingTriage ?? [:])

        #expect(groups.count == 1)
        guard let group = groups.first else {
            Issue.record("Expected at least one group")
            return
        }
        #expect(group.canonicalText == "johndoe")
        #expect(group.detectionIDs.count == 3)
        #expect(group.pages == [0, 1, 2])
    }

    // MARK: - 3. Group accept is one atomic undo step

    @Test("Group accept creates regions; a single undo() removes every one")
    func testGroupAcceptCreatesAtomicUndoStep() {
        let state = RedactionState()
        let undoManager = UndoManager()
        seedPending(state, items: [
            (page: 1, kind: .name, text: "John Doe"),
            (page: 3, kind: .name, text: "John Doe"),
            (page: 5, kind: .name, text: "John Doe")
        ])
        let groups = CrossPageEntityGroup.clusters(from: state.pendingTriage ?? [:])
        guard let group = groups.first else {
            Issue.record("Expected at least one group")
            return
        }

        // Pre-condition: no regions yet.
        #expect(state.regions.values.flatMap { $0 }.count == 0)

        let applied = state.applyEntityGroup(group, undoManager: undoManager)

        // Three regions, one per page in the group.
        #expect(applied == 3)
        #expect(state.regions[1]?.count == 1)
        #expect(state.regions[3]?.count == 1)
        #expect(state.regions[5]?.count == 1)
        #expect(state.regionsModifiedSinceVerification == true)

        // One undo() removes all three regions atomically.
        undoManager.undo()
        let remaining = state.regions.values.flatMap { $0 }.count
        #expect(remaining == 0)

        // Redo restores the same three regions (two-leg register/re-register
        // pattern parity with applySearchResults).
        undoManager.redo()
        #expect(state.regions[1]?.count == 1)
        #expect(state.regions[3]?.count == 1)
        #expect(state.regions[5]?.count == 1)
    }

    // MARK: - 4. Triage sheet exposes four view modes

    @Test("Triage sheet SortOrder has exactly 4 view modes including Grouped")
    func testGroupedViewModeAvailable() {
        let cases = DetectionTriageSheet.SortOrder.allCases
        #expect(cases.count == 4)
        #expect(cases.contains(.byPage))
        #expect(cases.contains(.byType))
        #expect(cases.contains(.byConfidence))
        #expect(cases.contains(.grouped))
        // Confirm the rawValue surfaces as the user-visible "Grouped" label
        // the Picker renders in the filter bar.
        #expect(DetectionTriageSheet.SortOrder.grouped.rawValue == "Grouped")
    }

    // MARK: - 5. Cross-category clustering preserves category

    @Test("Same canonical text in different PII categories does NOT cluster")
    func testCrossCategoryClusteringPreservesCategory() {
        // "John Doe" appears once as a name and once as an address line.
        // Singletons normally drop out, so we duplicate each category so
        // both yield real groups; the test asserts they remain SEPARATE.
        let state = RedactionState()
        seedPending(state, items: [
            (page: 0, kind: .name, text: "John Doe"),
            (page: 1, kind: .name, text: "JOHN DOE"),
            (page: 0, kind: .address, text: "John Doe"),
            (page: 2, kind: .address, text: "john doe")
        ])

        let groups = CrossPageEntityGroup.clusters(from: state.pendingTriage ?? [:])

        // Expect two groups — one per category — not a single merged
        // cluster. Hard stop in DRAW-4: clustering is within-category only.
        #expect(groups.count == 2)
        let categories = Set(groups.map(\.category))
        #expect(categories == Set([.name, .address]))

        // Each group has exactly two members (the two same-category hits).
        for group in groups {
            #expect(group.detectionIDs.count == 2)
            #expect(group.canonicalText == "johndoe")
        }
    }

    // MARK: - 6. UXF-29 — Apply Group then Apply N must not double-create

    @Test("Apply Group followed by Apply N creates one region per accepted detection (UXF-29)")
    func testGroupApplyThenTriageApplyCreatesEachDetectionOnce() {
        let state = RedactionState()
        seedPending(state, items: [
            (page: 1, kind: .name, text: "John Doe"),
            (page: 3, kind: .name, text: "John Doe"),
            // A non-group detection that only the sheet-level "Apply N"
            // promotes — pins that group apply leaves the rest of the
            // triage flow intact.
            (page: 2, kind: .email, text: "jdoe@example.com")
        ])
        let groups = CrossPageEntityGroup.clusters(from: state.pendingTriage ?? [:])
        guard let group = groups.first else {
            Issue.record("Expected the John Doe cluster")
            return
        }

        // User taps "Apply Group" in the Grouped view…
        let applied = state.applyEntityGroup(group, undoManager: nil)
        #expect(applied == 2)

        // The promoted members are pruned: only the email stays pending,
        // and the members' selection entries are gone so the toolbar
        // "Apply N" count reflects the remaining work only.
        #expect(state.pendingTriage?.values.flatMap { $0 }.count == 1)
        for id in group.detectionIDs {
            #expect(state.triageSelections[id] == nil)
        }

        // …then taps "Apply N" on the sheet toolbar.
        state.applyTriagedResults(undoManager: nil)

        // 3 unique accepted detections → exactly 3 regions, one each.
        let total = state.regions.values.flatMap { $0 }.count
        #expect(total == 3)
        #expect(state.regions[1]?.count == 1)
        #expect(state.regions[3]?.count == 1)
        #expect(state.regions[2]?.count == 1)
    }

    // MARK: - 7. UXF-29 — repeated Apply Group taps must not re-create

    @Test("A second Apply Group tap creates no additional regions (UXF-29)")
    func testRepeatedGroupApplyIsIdempotent() {
        let state = RedactionState()
        seedPending(state, items: [
            (page: 1, kind: .name, text: "John Doe"),
            (page: 3, kind: .name, text: "John Doe")
        ])
        let groups = CrossPageEntityGroup.clusters(from: state.pendingTriage ?? [:])
        guard let group = groups.first else {
            Issue.record("Expected the John Doe cluster")
            return
        }

        #expect(state.applyEntityGroup(group, undoManager: nil) == 2)
        // The group row stays on screen after the first tap; a second tap
        // must be a no-op, not a duplicate promotion.
        #expect(state.applyEntityGroup(group, undoManager: nil) == 0)
        #expect(state.regions.values.flatMap { $0 }.count == 2)
    }
}
