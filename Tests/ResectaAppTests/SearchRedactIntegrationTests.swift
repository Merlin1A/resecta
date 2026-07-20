import Testing
import Foundation
import RedactionEngine
@testable import ResectaApp

@Suite("Search-Redact Integration", .tags(.search))
@MainActor
struct SearchRedactIntegrationTests {

    @Test("Search-origin apply creates regions with .searchMatch source")
    func applyCreatesRegions() async {
        let redactionState = RedactionState()
        let search = SearchState()
        search.results = [
            makeResult(pageIndex: 0, term: "secret"),
            makeResult(pageIndex: 1, term: "secret")
        ]
        redactionState.activeSearch = search

        await redactionState.applyFindings(.selectedSearchResults, undoManager: nil)

        // Regions created on both pages
        #expect(redactionState.regions[0]?.count == 1)
        #expect(redactionState.regions[1]?.count == 1)

        // Source is .searchMatch
        if let region = redactionState.regions[0]?.first {
            if case .searchMatch(let term, _) = region.source {
                #expect(term == "secret")
            } else {
                Issue.record("Expected .searchMatch source")
            }
        }

        // Caller is responsible for clearing activeSearch after showing feedback (B6).
        #expect(redactionState.activeSearch != nil)
        redactionState.activeSearch = nil
    }

    @Test("Search-origin apply sets regionsModifiedSinceVerification")
    func applySetsStaleFlag() async {
        let redactionState = RedactionState()
        let search = SearchState()
        search.results = [makeResult(pageIndex: 0, term: "test")]
        redactionState.activeSearch = search

        await redactionState.applyFindings(.selectedSearchResults, undoManager: nil)

        #expect(redactionState.regionsModifiedSinceVerification == true)
    }

    @Test("Search-origin apply populates regionMetadata")
    func applyPopulatesMetadata() async {
        let redactionState = RedactionState()
        let search = SearchState()
        search.results = [makeResult(pageIndex: 0, term: "SSN")]
        redactionState.activeSearch = search

        await redactionState.applyFindings(.selectedSearchResults, undoManager: nil)

        guard let region = redactionState.regions[0]?.first else {
            Issue.record("No region created")
            return
        }
        let metadata = redactionState.regionMetadata[region.id]
        #expect(metadata != nil)
        #expect(metadata?.kindLabel == "Find")
        #expect(metadata?.matchedText == "test")
    }

    @Test("Search-origin apply with no selected results does nothing")
    func applyWithNoSelectionDoesNothing() async {
        let redactionState = RedactionState()
        let search = SearchState()
        search.results = [makeResult(pageIndex: 0, term: "test", isSelected: false)]
        redactionState.activeSearch = search

        await redactionState.applyFindings(.selectedSearchResults, undoManager: nil)

        #expect(redactionState.regions.isEmpty)
        // activeSearch should still be set since no apply happened
        #expect(redactionState.activeSearch != nil)
    }

    @Test("Undo removes search-originated regions")
    func undoRemovesRegions() async {
        let redactionState = RedactionState()
        let undoManager = UndoManager()
        let search = SearchState()
        search.results = [
            makeResult(pageIndex: 0, term: "test"),
            makeResult(pageIndex: 0, term: "test")
        ]
        redactionState.activeSearch = search

        await redactionState.applyFindings(.selectedSearchResults, undoManager: undoManager)
        #expect(redactionState.regions[0]?.count == 2)

        undoManager.undo()
        #expect(redactionState.regions[0]?.isEmpty ?? true)
    }

    @Test("Redo restores search-originated regions")
    func redoRestoresRegions() async {
        let redactionState = RedactionState()
        let undoManager = UndoManager()
        let search = SearchState()
        search.results = [makeResult(pageIndex: 0, term: "test")]
        redactionState.activeSearch = search

        await redactionState.applyFindings(.selectedSearchResults, undoManager: undoManager)
        undoManager.undo()
        #expect(redactionState.regions[0]?.isEmpty ?? true)

        undoManager.redo()
        #expect(redactionState.regions[0]?.count == 1)
    }

    // MARK: - QW-1 (D06-F3) applied-badge honesty

    @Test("Overlap-skipped result is excluded from appliedResultIDs")
    func applyReturnsSurvivorIDsOnly() async {
        let redactionState = RedactionState()
        // Existing region fully covering result A's rect (>80% overlap →
        // the prepare step skips A). Result B sits elsewhere on the page.
        let rectA = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.04)
        let existing = RedactionRegion(
            id: UUID(),
            normalizedRect: rectA,
            source: .manual
        )
        redactionState.regions[0] = [existing]

        let resultA = makeResult(term: "secret", normalizedRect: rectA)
        let resultB = makeResult(
            term: "secret",
            normalizedRect: CGRect(x: 0.5, y: 0.6, width: 0.3, height: 0.04)
        )
        let search = SearchState()
        search.results = [resultA, resultB]
        redactionState.activeSearch = search

        let outcome = await redactionState.applyFindings(.selectedSearchResults, undoManager: nil)

        #expect(outcome?.applied == 1)
        #expect(outcome?.skippedOverlaps == 1)
        // The surviving subset carries B only — the skipped A must not
        // be reported as applied (it got no region and no audit entry).
        #expect(outcome?.appliedResultIDs == [resultB.id])
        #expect(redactionState.appliedMatchAudit.values.map(\.resultID) == [resultB.id])
    }

    @Test("Sheet-side union path marks only survivors as applied")
    func sheetUnionPathMarksSurvivorsOnly() async {
        // Replicates the SearchAndRedactSheet apply flow: capture the full
        // selection, apply, then union the RETURNED survivor subset into
        // `appliedResultIDs` — the badge state must match the audit-backed
        // set, not the selection.
        let redactionState = RedactionState()
        let rectA = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.04)
        let existing = RedactionRegion(
            id: UUID(),
            normalizedRect: rectA,
            source: .manual
        )
        redactionState.regions[0] = [existing]

        let resultA = makeResult(term: "secret", normalizedRect: rectA)
        let resultB = makeResult(
            term: "secret",
            normalizedRect: CGRect(x: 0.5, y: 0.6, width: 0.3, height: 0.04)
        )
        let search = SearchState()
        search.results = [resultA, resultB]
        redactionState.activeSearch = search

        let selectedIDs = Set(search.results.filter(\.isSelected).map(\.id))
        #expect(selectedIDs == [resultA.id, resultB.id])

        guard let outcome = await redactionState.applyFindings(.selectedSearchResults, undoManager: nil) else {
            Issue.record("apply returned nil")
            return
        }
        search.appliedResultIDs.formUnion(outcome.appliedResultIDs)

        #expect(search.appliedResultIDs == [resultB.id])
        #expect(!search.appliedResultIDs.contains(resultA.id))
    }

    @Test("Fully covered selection grays Apply after one round-trip (BH-A-03)")
    func coveredSelectionGraysApply() async {
        // A selection whose members are ALL dedup-covered by existing
        // regions used to keep Apply enabled forever: skipped IDs never
        // entered `appliedResultIDs`, so `selectionFullyApplied` could
        // not engage and every press re-ran a "Marked 0 … already
        // covered" no-op.
        let redactionState = RedactionState()
        let rectA = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.04)
        redactionState.regions[0] = [RedactionRegion(
            id: UUID(), normalizedRect: rectA, source: .manual)]

        let resultA = makeResult(term: "secret", normalizedRect: rectA)
        let search = SearchState()
        search.results = [resultA]
        redactionState.activeSearch = search
        #expect(!search.selectionFullyApplied,
                "precondition: gate disengaged before the apply")

        guard let outcome = await redactionState.applyFindings(
            .selectedSearchResults, undoManager: nil) else {
            Issue.record("apply returned nil")
            return
        }
        #expect(outcome.applied == 0)
        #expect(outcome.skippedOverlaps == 1)
        #expect(outcome.coveredResultIDs == [resultA.id])
        // Sheet flow: union both ledgers.
        search.appliedResultIDs.formUnion(outcome.appliedResultIDs)
        search.coveredResultIDs.formUnion(outcome.coveredResultIDs)

        // QW-1 intact: no badge for the covered row …
        #expect(!search.appliedResultIDs.contains(resultA.id))
        // … but the graying gate engages, killing the dead round-trip.
        #expect(search.selectionFullyApplied,
                "fully covered selection must gray Apply")
        // clearResults drops the ledger with its sibling.
        search.clearResults()
        #expect(search.coveredResultIDs.isEmpty)
    }

    // MARK: - Helpers

    private func makeResult(
        pageIndex: Int = 0,
        term: String = "test",
        isSelected: Bool = true,
        normalizedRect: CGRect = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.04),
        piiCategory: PIICategory? = nil
    ) -> SearchResult {
        SearchResult(
            pageIndex: pageIndex,
            normalizedRect: normalizedRect,
            matchedText: "test",
            contextSnippet: "…some test text…",
            source: .textLayer,
            term: term,
            isSelected: isSelected,
            piiCategory: piiCategory
        )
    }

    // MARK: - PD-3/PD-13 piiKind stamping

    @Test("prepareApply stamps a piiScan result's category; typed results keep searchMatch")
    func applyStampsPIICategory() {
        let prepared = prepareApply(
            selected: [
                makeResult(term: "Name", piiCategory: .name),
                makeResult(term: "wrenfield"),
            ],
            existingRectsByPage: [:],
            appliedAt: Date())

        let kinds = prepared.createdMetadata.values.map(\.piiKind)
        #expect(kinds.contains(.pii(.name)),
                "piiScan result must stamp its detected category")
        #expect(kinds.contains(.searchMatch(term: "wrenfield")),
                "typed result keeps the search-match kind")
    }

    @Test("Stamped piiScan metadata renders category labels; typed keeps the generic label")  // LegalPhrases:safe (UI label constant)
    func stampedMetadataLabels() {
        let prepared = prepareApply(
            selected: [
                makeResult(term: "Phone", piiCategory: .phone),
                makeResult(term: "wrenfield"),
            ],
            existingRectsByPage: [:],
            appliedAt: Date())

        let labels = Set(prepared.createdMetadata.values.map(\.kindLabel))
        #expect(labels == ["Phone", "Find"],  // LegalPhrases:safe (UI label constant)
                "piiScan region surfaces its category label; typed region stays generic")
    }

    @Test("acceptManualDrawNudge mirrors the category stamp")
    func nudgeStampsCategory() {
        let redactionState = RedactionState()
        redactionState.activeSearch = SearchState()
        let nudge = makeResult(term: "Phone", piiCategory: .phone)

        let region = redactionState.acceptManualDrawNudge(nudge, undoManager: nil)

        guard let region else {
            Issue.record("Nudge accept must create a region while a search is active")
            return
        }
        #expect(redactionState.regionMetadata[region.id]?.piiKind == .pii(.phone))
    }

    @Test("Search-origin apply threads the category stamp end to end")
    func applyThreadsCategoryStamp() async {
        let redactionState = RedactionState()
        let search = SearchState()
        search.results = [makeResult(pageIndex: 0, term: "Name", piiCategory: .name)]
        redactionState.activeSearch = search

        await redactionState.applyFindings(.selectedSearchResults, undoManager: nil)

        guard let region = redactionState.regions[0]?.first else {
            Issue.record("No region created")
            return
        }
        #expect(redactionState.regionMetadata[region.id]?.piiKind == .pii(.name))
        // The region's Source keeps the search-match shape (rationale
        // continuity, audit surfaces) regardless of the metadata stamp.
        if case .searchMatch(let term, _) = region.source {
            #expect(term == "Name")
        } else {
            Issue.record("Expected .searchMatch source")
        }
    }
}
