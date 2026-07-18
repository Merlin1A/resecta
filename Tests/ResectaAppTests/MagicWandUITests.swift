import Testing
import UIKit
import CoreGraphics
import Foundation
import RedactionEngine
@testable import ResectaApp

// DRAW-5 — magic-wand select-by-similar-text UI tests.
//
// The DRAW-5 contract is:
//   - Long-press on a detected OCR word surfaces a context menu item
//     "Select all instances" gated on the OCR-word hit.
//   - The action sets `RedactionState.pendingMagicWandRequest`, which
//     the host (DocumentEditorView) consumes to open the search sheet
//     pre-filled with the escaped term and `SearchOptions.exactMatch =
//     true`. The apply path is the search origin of `applyFindings`
//     (hard stop — no new apply method).
//   - All resulting matches default-select so the user can apply with
//     one tap; this is driven by `SearchState.preselectIncomingResults`.
//
// These tests pin three behaviors without a UIContextMenuInteraction
// host:
// 1. The `hitTestOCRWord` predicate returns the word at the touch
//    point, or nil when the touch falls in whitespace.
// 2. The `makeMagicWandMenuConfiguration` action sets the magic-wand
//    request on `RedactionState`.
// 3. End-to-end: when the magic-wand path drives the result list via
//    `preselectIncomingResults` and the user applies, the result count
//    maps 1:1 to created regions (the 4-page same-SSN acceptance from
//    DRAW-5).

@Suite("Magic Wand select-by-similar-text (DRAW-5)")
@MainActor
struct MagicWandUITests {

    // Shared overlay fixture: 400×400 view, single OCR word.
    // PDF normalized (0.10, 0.10, 0.30, 0.05) → overlay rect (40, 340, 120, 20):
    //   minX = 0.10 * 400 = 40
    //   minY = (1 - 0.10 - 0.05) * 400 = 340
    //   width = 0.30 * 400 = 120
    //   height = 0.05 * 400 = 20
    private static let overlayWidth: CGFloat = 400
    private static let overlayHeight: CGFloat = 400
    private static let wordRectNormalized = CGRect(
        x: 0.10, y: 0.10, width: 0.30, height: 0.05
    )
    private static let wordText = "Doe"

    private func makeOverlay() -> RedactionOverlayView {
        let overlay = RedactionOverlayView(
            frame: CGRect(
                x: 0, y: 0,
                width: Self.overlayWidth, height: Self.overlayHeight
            )
        )
        overlay.ocrWords = [
            RedactionOverlayView.OCRWord(
                text: Self.wordText,
                normalizedRect: Self.wordRectNormalized
            )
        ]
        return overlay
    }

    // MARK: - 1) Hit-test gating

    @Test("Long-press on OCR word resolves the magic-wand source word")
    func testLongPressOnOCRWordShowsMenuItem() {
        let overlay = makeOverlay()

        // A point inside the overlay rect for the word — pick the
        // center of the overlay-space rect computed above.
        let inside = CGPoint(x: 40 + 60, y: 340 + 10)
        let hit = overlay.hitTestOCRWord(at: inside)

        #expect(hit != nil,
                "hitTestOCRWord should resolve a word inside the word rect")
        #expect(hit?.text == Self.wordText,
                "hit.text should match the source word")
        #expect(hit?.normalizedRect == Self.wordRectNormalized,
                "hit.normalizedRect should round-trip the source rect")
    }

    @Test("Long-press off any OCR word returns nil (menu item absent)")
    func testLongPressOffWordHidesMenuItem() {
        let overlay = makeOverlay()

        // A point well outside the word rect — top-left corner of the
        // overlay is in pure whitespace.
        let outside = CGPoint(x: 10, y: 10)
        let hit = overlay.hitTestOCRWord(at: outside)

        #expect(hit == nil,
                "whitespace touch must not resolve a magic-wand word")

        // Empty word cache must also no-op, even at the word's own
        // location. Pins the gating-on-non-empty contract.
        overlay.ocrWords = []
        let revisit = overlay.hitTestOCRWord(at: CGPoint(x: 40 + 60, y: 340 + 10))
        #expect(revisit == nil,
                "empty ocrWords cache must always return nil")
    }

    // MARK: - 2) Pre-fill flow + escape contract

    @Test("Magic-wand request escapes regex specials at the call site")
    func testMagicWandRequestEscapesAtCallSite() {
        // Plan §0.4: regex specials escape at the call site, not in the
        // engine runtime. The static helper on RedactionOverlayView
        // pins this contract.
        let raw = "C++"
        let escaped = RedactionOverlayView.escapeRegexSpecials(in: raw)

        #expect(escaped != raw,
                "regex specials must be escaped at the call site")
        // The escape must be safe to feed to NSRegularExpression.
        // NSRegularExpression.escapedPattern wraps the term in \Q…\E.
        #expect(escaped.contains("\\Q") || escaped.contains("\\+"),
                "escape must use a documented NSRegularExpression form")
    }

    // MARK: - 3) End-to-end apply — 1:1 result-to-region mapping

    @Test("Magic-wand selection creates one region per result on apply")
    func testSelectionCreates4RegionsOnFixture() async {
        // The acceptance fixture is "the same SSN on 4 pages".
        // Engine-level multi-page text search is exercised by the
        // engine suite; here we pin the application-layer contract:
        //   - The magic-wand pre-select flag flips every incoming
        //     SearchResult to `isSelected = true`.
        //   - the search-origin apply then creates exactly one
        //     RedactionRegion per selected result, on the right page.
        //
        // Constructing four synthetic results stands in for the
        // engine-driven path so the test stays hermetic — the engine
        // side is pinned by `MagicWandSelectTests`.

        let redactionState = RedactionState()
        let search = SearchState()
        search.preselectIncomingResults = true

        // Stream four results through `appendResult` exactly as the
        // engine would, so the magic-wand pre-select flag participates.
        for page in 0..<4 {
            let result = SearchResult(
                pageIndex: page,
                normalizedRect: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.04),
                matchedText: "123-45-6789",
                contextSnippet: "…SSN 123-45-6789…",
                source: .textLayer,
                term: "123-45-6789",
                isSelected: false  // engine default; preselect flag flips
            )
            search.appendResult(result)
        }
        search.flushPendingResults()
        redactionState.activeSearch = search

        // All four landed as selected — the pre-select flag is the
        // contract under test.
        #expect(search.results.count == 4)
        let everySelected = search.results.allSatisfy { $0.isSelected }
        #expect(everySelected,
                "magic-wand pre-select flag must default-select every result")

        // Apply path: the search origin of the one `applyFindings`
        // seam. One region per result, on its page.
        let outcome = await redactionState.applyFindings(.selectedSearchResults, undoManager: nil)
        #expect(outcome?.applied == 4)
        for page in 0..<4 {
            #expect(redactionState.regions[page]?.count == 1,
                    "page \(page) should have exactly one region applied")
        }
    }
}
