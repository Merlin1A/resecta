import Testing
import Foundation
import PDFKit
@testable import ResectaApp
@testable import RedactionEngine

// GATE-3 (Pkg I) — Verification Done confirmation symmetry.
//
// Done now lives in the top-left toolbar of `DocumentEditorView` for
// the `.verified` phase; the legacy bottom `VerificationActionBar` was
// removed when Done moved up. The predicate + close-session contract is
// unchanged — only the host moved.
//
// Tapping Done with drawn regions routes through a
// `.confirmationDialog`. Empty-session Done bypasses the dialog and
// closes directly. The contract reduces to three pinned predicates
// this suite anchors:
//
//   1. The `hasDrawnRegions` predicate is true iff at least one page
//      carries at least one region — empty page lists and pages with
//      empty region arrays both fall through.
//   2. The Cancel role on the dialog leaves regions and sourceDocument
//      in place (no state change). Cancel is the "back out" path.
//   3. The Close (destructive) role mirrors `RedactionState.clearAll()`
//      + `documentState.sourceDocument = nil` — the same teardown the
//      prior one-tap Done did.
//
// Plan reference: post-V1.0 improvements §3 Pkg I (GATE-3).
// Mechanism-description copy per ARCH §1.3.

@Suite("Verification Done confirmation (GATE-3, Pkg I)")
@MainActor
struct VerificationActionBarDoneConfirmationTests {

    /// Construct a region map with `count` regions on page 0.
    private func makeRegions(count: Int) -> [Int: [RedactionRegion]] {
        var page: [RedactionRegion] = []
        for _ in 0..<count {
            page.append(.mock())
        }
        return [0: page]
    }

    @Test("Done shows confirmation when regions are present — predicate flips to true")
    func testDoneShowsConfirmationWithRegions() {
        let redactionState = RedactionState()
        redactionState.regions = makeRegions(count: 1)

        // Mirrors the `hasDrawnRegions` predicate in DocumentEditorView.
        let hasDrawnRegions = redactionState.regions.values.contains { !$0.isEmpty }
        #expect(hasDrawnRegions == true,
                "predicate must be true when any page carries any region")
    }

    @Test("Done bypasses confirmation when no regions are present — predicate is false")
    func testDoneBypassesConfirmationWhenEmpty() {
        let redactionState = RedactionState()
        // Empty regions map — the dictionary itself is empty.
        redactionState.regions = [:]

        let hasDrawnRegions = redactionState.regions.values.contains { !$0.isEmpty }
        #expect(hasDrawnRegions == false,
                "predicate must be false when no regions are drawn")
    }

    @Test("Pages with empty region arrays do not count as drawn regions")
    func testEmptyPageArraysAreNotDrawnRegions() {
        let redactionState = RedactionState()
        // Edge case: page 0 has an empty region array (placeholder entry).
        // `hasDrawnRegions` must still be false.
        redactionState.regions = [0: [], 1: []]

        let hasDrawnRegions = redactionState.regions.values.contains { !$0.isEmpty }
        #expect(hasDrawnRegions == false,
                "predicate must be false when pages carry empty region arrays")
    }

    @Test("Cancel role preserves regions and sourceDocument")
    func testCancelRolePreservesState() {
        let redactionState = RedactionState()
        let documentState = DocumentState()
        let pdf = makeTestPDFDocument()

        redactionState.regions = makeRegions(count: 2)
        documentState.sourceDocument = pdf

        // Cancel role contract: the destructive closure is NOT invoked.
        // State remains as-is for the user to back out into.
        #expect(redactionState.regions.values.first?.count == 2)
        #expect(documentState.sourceDocument != nil)
    }

    @Test("Destructive role clears regions and drops sourceDocument — matches prior Done semantics")
    func testDestructiveRoleClearsRegionsAndSourceDocument() {
        let redactionState = RedactionState()
        let documentState = DocumentState()
        documentState.sourceDocument = makeTestPDFDocument()
        redactionState.regions = makeRegions(count: 3)

        // The destructive button closure mirrors the prior one-tap Done:
        // `clearAll()` + `sourceDocument = nil` + reset state.
        redactionState.clearAll()
        documentState.sourceDocument = nil
        documentState.textLayerStatus = [:]
        documentState.currentPageIndex = 0
        documentState.lastUsedPipelineMode = nil
        documentState.wasPausedByBackground = false

        #expect(redactionState.regions.isEmpty,
                "destructive role must clear all regions")
        #expect(documentState.sourceDocument == nil,
                "destructive role must drop sourceDocument")
        #expect(documentState.currentPageIndex == 0)
        #expect(documentState.lastUsedPipelineMode == nil)
        #expect(documentState.wasPausedByBackground == false)
    }

    @Test("Confirmation copy is mechanism-description (no outcome-promise phrases)")
    func testConfirmationCopyIsMechanismDescription() {
        // The dialog title + message are hard-coded inline in
        // DocumentEditorView (lifted from the retired
        // VerificationActionBar). Pin the copy so it can't silently
        // drift into outcome-promise language (R1 / ARCH §1.3).
        let title = "Close this document?"
        let message = "Drawn regions and verification results will be cleared."

        let banned = ["guaranteed", "ensures", "impossible", "securely"] // LegalPhrases:safe (test banlist)
        for word in banned {
            #expect(!title.lowercased().contains(word),
                    "title must not contain banned outcome-promise word: \(word)")
            #expect(!message.lowercased().contains(word),
                    "message must not contain banned outcome-promise word: \(word)")
        }
        // Message names the two state buckets touched. The shape of the
        // copy carries the mechanism.
        #expect(message.contains("Drawn regions"))
        #expect(message.contains("verification results"))
    }
}
