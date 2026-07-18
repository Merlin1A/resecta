import Testing
import Foundation
import CoreGraphics
@testable import ResectaApp
@testable import RedactionEngine

// The absorbed review surface's arrival + derivation contracts:
//
// - review-first producers: every staged detection arrives with an EXPLICIT
//   `false` selection entry (`reviewArrivalSelections`), because
//   `applyTriagedResults` still reads ABSENT ids as accepted (`?? true`,
//   its re-guard rides the apply-path unification) — an entry-less
//   detection would display deselected but apply selected.
// - The normalize belt closes that gap for any producer that missed it.
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

    @Test("reviewArrivalSelections writes an explicit false entry per detection")
    func arrivalSelectionsAreExplicitFalse() {
        let a = makeDetection(page: 0)
        let b = makeDetection(page: 0, kind: .pii(.email), matchedText: "j@x.com")
        let c = makeDetection(page: 2, kind: .face, matchedText: nil)
        let selections = RedactionState.reviewArrivalSelections(
            for: [0: [a, b], 2: [c]]
        )
        #expect(selections.count == 3)
        for det in [a, b, c] {
            #expect(selections[det.id] == false,
                    "every detection needs an EXPLICIT false — the apply fallback reads absent as accepted")
        }
    }

    @Test("normalizeReviewSelections fills missing entries with false, preserves existing")
    func normalizeBeltFillsGaps() {
        let state = RedactionState()
        let a = makeDetection(page: 0)
        let b = makeDetection(page: 0, kind: .pii(.email), matchedText: "j@x.com")
        state.pendingTriage = [0: [a, b]]
        // Producer "forgot" b; the user selected a.
        state.triageSelections = [a.id: true]

        state.normalizeReviewSelections()

        #expect(state.triageSelections[a.id] == true,
                "existing entries must be preserved")
        #expect(state.triageSelections[b.id] == false,
                "missing entries must become explicit false")
    }

    @Test("Seed route stages all-deselected with explicit entries and a staged record")
    func seedRouteArrivalShape() {
        let state = RedactionState()
        state.seedDebugTriage()

        guard let pending = state.pendingTriage else {
            Issue.record("seed must stage findings")
            return
        }
        let ids = pending.values.flatMap { $0 }.map(\.id)
        #expect(!ids.isEmpty)
        for id in ids {
            #expect(state.triageSelections[id] == false,
                    "seeded findings arrive all-deselected with explicit entries (review-first arrival)")
        }
        #expect(state.lastDetectionRun?.outcome == .staged)
        #expect(state.lastDetectionRun?.scanSummary == nil,
                "seeded record is pipeline-origin shaped (banner derives counts from pendingTriage)")
    }

    @Test("Accepted count over explicit entries matches what applyTriagedResults will apply")
    func acceptedCountMatchesApply() {
        let state = RedactionState()
        let a = makeDetection(page: 0)
        let b = makeDetection(page: 0, kind: .pii(.email), matchedText: "j@x.com")
        let c = makeDetection(page: 1, kind: .pii(.phone), matchedText: "(555) 010-2934")
        state.pendingTriage = [0: [a, b], 1: [c]]
        state.triageSelections = RedactionState.reviewArrivalSelections(
            for: [0: [a, b], 1: [c]]
        )
        // User selects two.
        state.triageSelections[a.id] = true
        state.triageSelections[c.id] = true

        // The toolbar's "Apply N" reads explicit-true entries.
        let acceptedCount = state.triageSelections.values.count { $0 }
        #expect(acceptedCount == 2)

        let created = state.applyTriagedResults(undoManager: nil)
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
