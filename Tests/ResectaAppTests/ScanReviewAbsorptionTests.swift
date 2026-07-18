import Testing
import Foundation
import CoreGraphics
@testable import ResectaApp
@testable import RedactionEngine

// The absorbed review surface's arrival + derivation contracts:
//
// - review-first arrival: staged detections arrive with NOTHING
//   selected, and an ABSENT selection id reads as NOT accepted in the
//   one apply path — display state and apply state agree with no
//   producer entries and no normalization belt (both retired with the
//   old absent-reads-accepted fallback).
// - The seed route (`--seedTriage`) stages the same all-deselected
//   shape the pipeline does.
// - The review list/group derivation helpers (filter, order, prune
//   visibility) are pure and pinned here.

@Suite("Scan review absorption — arrival + derivations")
@MainActor
struct ScanReviewAbsorptionTests {

    private func makeDetection(
        page: Int = 0,
        kind: DetectionResult.Kind = .pii(.ssn),
        confidence: Double = 0.9,
        matchedText: String? = "123-45-6789"
    ) -> DetectionResult {
        DetectionResult(
            normalizedRect: CGRect(
                x: 0.1, y: 0.1 + Double(page) * 0.05, width: 0.3, height: 0.03
            ),
            kind: kind,
            confidence: confidence,
            matchedText: matchedText
        )
    }

    // MARK: - review-first arrival selections

    @Test("An absent selection id never applies — arrival needs no entries")
    func absentIdsAreNotAccepted() async {
        let state = RedactionState()
        let a = makeDetection(page: 0)
        let b = makeDetection(page: 0, kind: .pii(.email), matchedText: "j@x.com")
        let c = makeDetection(page: 2, kind: .face, matchedText: nil)
        state.pendingTriage = [0: [a, b], 2: [c]]
        // The arrival shape: an EMPTY selection map.
        state.triageSelections = [:]

        let outcome = await state.applyFindings(.stagedDetections, undoManager: nil)

        #expect(outcome?.applied == 0,
                "no detection may become a region without an explicit true entry")
        #expect(state.regions.values.flatMap { $0 }.isEmpty)
        #expect(state.pendingTriage == nil, "apply still resolves the review")
    }

    @Test("Seed route stages all-deselected (empty selection map) and a staged record")
    func seedRouteArrivalShape() {
        let state = RedactionState()
        state.seedDebugTriage()

        guard let pending = state.pendingTriage else {
            Issue.record("seed must stage detections")
            return
        }
        let ids = pending.values.flatMap { $0 }.map(\.id)
        #expect(!ids.isEmpty)
        #expect(state.triageSelections.isEmpty,
                "seeded detections arrive all-deselected — the empty map IS the arrival shape")
        #expect(state.lastDetectionRun?.outcome == .staged)
        #expect(state.lastDetectionRun?.scanSummary == nil,
                "seeded record is pipeline-origin shaped (banner derives counts from pendingTriage)")
    }

    @Test("Accepted count over explicit-true entries matches what the apply promotes")
    func acceptedCountMatchesApply() async {
        let state = RedactionState()
        let a = makeDetection(page: 0)
        let b = makeDetection(page: 0, kind: .pii(.email), matchedText: "j@x.com")
        let c = makeDetection(page: 1, kind: .pii(.phone), matchedText: "(555) 010-2934")
        state.pendingTriage = [0: [a, b], 1: [c]]
        // Arrival shape (empty), then the user selects two.
        state.triageSelections = [:]
        state.triageSelections[a.id] = true
        state.triageSelections[c.id] = true

        // The toolbar's "Apply N" reads explicit-true entries.
        let acceptedCount = state.triageSelections.values.count { $0 }
        #expect(acceptedCount == 2)

        let created = await state.applyFindings(
            .stagedDetections, undoManager: nil)?.applied
        #expect(created == acceptedCount,
                "the displayed Apply count and the applied-region count must agree")
        #expect(state.pendingTriage == nil,
                "apply resolves the review")
    }

    // MARK: - Derivation helpers

    @Test("flattenedFindings orders by page and flattens the map")
    func flattenOrder() {
        let a = makeDetection(page: 3)
        let b = makeDetection(page: 0, kind: .pii(.email), matchedText: "j@x.com")
        let flat = ScanReviewSection.flattenedFindings([3: [a], 0: [b]])
        #expect(flat.count == 2)
        #expect(flat[0].detection.id == b.id, "page 0 precedes page 3")
        #expect(flat[1].detection.id == a.id)
        #expect(ScanReviewSection.flattenedFindings(nil).isEmpty)
    }

    @Test("filteredFindings — kind filter narrows; confidence order sorts descending")
    func filterAndOrder() {
        let ssn = makeDetection(page: 0, confidence: 0.5)
        let email = makeDetection(page: 1, kind: .pii(.email), confidence: 0.9, matchedText: "j@x.com")
        let flat = ScanReviewSection.flattenedFindings([0: [ssn], 1: [email]])

        let onlySSN = ScanReviewSection.filteredFindings(
            flat, filterKind: .pii(.ssn), viewMode: .byPage
        )
        #expect(onlySSN.count == 1)
        #expect(onlySSN[0].detection.id == ssn.id)

        let byConfidence = ScanReviewSection.filteredFindings(
            flat, filterKind: nil, viewMode: .byConfidence
        )
        #expect(byConfidence[0].detection.id == email.id, "0.9 sorts before 0.5")
    }

    @Test("kindsWithCounts aggregates by kind in display order")
    func kindCounts() {
        let a = makeDetection(page: 0)
        let b = makeDetection(page: 1)
        let c = makeDetection(page: 1, kind: .pii(.email), matchedText: "j@x.com")
        let counts = ScanReviewSection.kindsWithCounts(
            in: ScanReviewSection.flattenedFindings([0: [a], 1: [b, c]])
        )
        #expect(counts.count == 2)
        #expect(counts[0].kind == .pii(.ssn), "ssn sorts before email in display order")
        #expect(counts[0].count == 2)
        #expect(counts[1].kind == .pii(.email))
        #expect(counts[1].count == 1)
    }

    @Test("filteredGroups hides fully-promoted groups (UXF-29) and honors the kind filter")
    func groupVisibility() {
        let a = makeDetection(page: 0, kind: .pii(.name), matchedText: "Jordan Avery")
        let b = makeDetection(page: 2, kind: .pii(.name), matchedText: "Jordan Avery")
        let pending: [Int: [DetectionResult]] = [0: [a], 2: [b]]
        let groups = CrossPageEntityGroup.clusters(from: pending)
        #expect(!groups.isEmpty, "precondition: the duplicate name forms a group")

        // Visible while members are pending.
        #expect(ScanReviewSection.filteredGroups(
            groups, pending: pending, filterKind: nil
        ).count == groups.count)

        // Kind filter: matching category keeps it; another hides it.
        #expect(ScanReviewSection.filteredGroups(
            groups, pending: pending, filterKind: .pii(.name)
        ).count == groups.count)
        #expect(ScanReviewSection.filteredGroups(
            groups, pending: pending, filterKind: .pii(.ssn)
        ).isEmpty)

        // All members promoted/pruned → the group row leaves the screen.
        #expect(ScanReviewSection.filteredGroups(
            groups, pending: [:], filterKind: nil
        ).isEmpty)
    }

    @Test("selections(where:) writes an explicit verdict per detection (predicate selection)")
    func predicateSelectionExplicit() {
        let high = makeDetection(page: 0, confidence: 0.95)
        let low = makeDetection(page: 0, kind: .pii(.email), confidence: 0.6, matchedText: "j@x.com")
        let flat = ScanReviewSection.flattenedFindings([0: [high, low]])
        let selections = ScanReviewSection.selections(
            where: { $0.confidence >= 0.9 }, in: flat
        )
        #expect(selections[high.id] == true)
        #expect(selections[low.id] == false,
                "non-matching findings get an EXPLICIT false, not a missing entry")
    }
}
