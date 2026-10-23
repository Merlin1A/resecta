import Testing
import Foundation
import CoreGraphics
import PDFKit
import RedactionEngine
@testable import ResectaApp

// The page bar's whole-page action: one tap marks the visible page as a
// region through the ordinary add path, so it behaves like a drawn
// region in every respect — one undo step with the drawn region's name,
// the same counter, no term captured from it, no nearby-match nudge
// from it. The bar itself is shown only at the compact width of a
// multi-page document in the editing phase, so the action is never
// disabled: a page the bar can show is a page it can mark.

@MainActor
@Suite("Page bar whole-page action")
struct PageBarWholePageTests {

    private static let unit = CGRect(x: 0, y: 0, width: 1, height: 1)

    private static func makeStates(pages: Int = 3, currentPage: Int = 1) -> (DocumentState, RedactionState) {
        let documentState = DocumentState()
        documentState.sourceDocument = makeMultiPagePDFDocument(pages: pages)
        documentState.currentPageIndex = currentPage
        return (documentState, RedactionState())
    }

    private static func mark(_ documentState: DocumentState, _ redactionState: RedactionState,
                             undoManager: UndoManager? = nil) {
        PageNavigationBar.markWholePage(
            redactionState: redactionState, documentState: documentState, undoManager: undoManager)
    }

    /// A repository file read relative to this test's own path.
    private static func repoFile(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    // MARK: - The region

    @Test("The region is the page's unit rectangle, manual")
    func regionIsTheUnitRectangle() {
        let region = PageNavigationBar.wholePageRegion()
        #expect(region.normalizedRect == Self.unit)
        #expect(region.source == .manual)
        #expect(region.normalizedRect.width * region.normalizedRect.height
                >= PipelineCoordinator.wholePageRegionArea,
                "the region is a whole-page region by the capture rule's own threshold")
    }

    // MARK: - The add path

    @Test("One tap adds exactly one region on the current page and on no other page")
    func addsOneRegionOnTheCurrentPage() throws {
        let (documentState, redactionState) = Self.makeStates(currentPage: 1)
        let versionBefore = redactionState.regionVersion
        Self.mark(documentState, redactionState)
        let added = try #require(redactionState.regions[1])
        #expect(added.count == 1)
        #expect(added.first?.normalizedRect == Self.unit)
        #expect(added.first?.source == .manual)
        #expect((redactionState.regions[0] ?? []).isEmpty)
        #expect((redactionState.regions[2] ?? []).isEmpty)
        #expect(redactionState.regionVersion == versionBefore + 1,
                "the add bumps the region version the overlay refreshes on")
        #expect(redactionState.regionsModifiedSinceVerification)
    }

    @Test("The tap follows the current page: page 3 of 3 gets the region, not page 1")
    func followsTheCurrentPage() {
        let (documentState, redactionState) = Self.makeStates(pages: 3, currentPage: 2)
        Self.mark(documentState, redactionState)
        #expect(redactionState.regions[2]?.count == 1)
        #expect((redactionState.regions[0] ?? []).isEmpty)
    }

    @Test("A repeated tap adds another region on the same page")
    func repeatedTapAddsAnotherRegion() {
        let (documentState, redactionState) = Self.makeStates(currentPage: 0)
        Self.mark(documentState, redactionState)
        Self.mark(documentState, redactionState)
        #expect(redactionState.regions[0]?.count == 2)
    }

    // MARK: - The counter

    @Test("The bar's counter reads '1 region' after the tap, nothing before it, and pluralises beyond one")
    func counterReadsOneRegion() {
        let (documentState, redactionState) = Self.makeStates(currentPage: 0)
        let countBefore = redactionState.regions[0]?.count ?? 0
        #expect(PageNavigationBar.regionCountLabel(countBefore) == nil)
        Self.mark(documentState, redactionState)
        let count = redactionState.regions[documentState.currentPageIndex]?.count ?? 0
        #expect(PageNavigationBar.regionCountLabel(count) == "1 region")
        #expect(PageNavigationBar.regionCountLabel(2) == "2 regions")
    }

    // MARK: - Undo

    @Test("Undo removes the region in one step that carries the drawn region's name")
    func undoRemovesTheRegion() {
        let (documentState, redactionState) = Self.makeStates(currentPage: 2)
        let undoManager = UndoManager()
        Self.mark(documentState, redactionState, undoManager: undoManager)
        #expect(undoManager.canUndo)
        #expect(undoManager.undoActionName == "Add Redaction")
        undoManager.undo()
        #expect((redactionState.regions[2] ?? []).isEmpty)
        #expect(!undoManager.canUndo)
        #expect(undoManager.canRedo)
        undoManager.redo()
        #expect(redactionState.regions[2]?.count == 1)
    }

    @Test("Two taps are two undo steps; each undo removes one region")
    func eachTapIsItsOwnUndoStep() {
        let (documentState, redactionState) = Self.makeStates(currentPage: 0)
        // Two taps arrive as two run-loop events, each its own undo
        // group; a test runs both synchronously, so the groups are
        // opened and closed by hand with event grouping off.
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        for _ in 0..<2 {
            undoManager.beginUndoGrouping()
            Self.mark(documentState, redactionState, undoManager: undoManager)
            undoManager.endUndoGrouping()
        }
        #expect(redactionState.regions[0]?.count == 2)
        undoManager.undo()
        #expect(redactionState.regions[0]?.count == 1)
        undoManager.undo()
        #expect((redactionState.regions[0] ?? []).isEmpty)
    }

    // MARK: - The run's inputs

    @Test("The run's term set gains no term from the whole-page region on a page with a rich text layer")
    func noTermIsCapturedFromTheRegion() {
        let document = makeTextPDFDocument(text: "Account 4111 1111 1111 1111 for Jane Doe")
        let documentState = DocumentState()
        documentState.sourceDocument = document
        documentState.currentPageIndex = 0
        let redactionState = RedactionState()
        Self.mark(documentState, redactionState)
        let set = PipelineCoordinator.sensitiveTermSet(
            applied: [], manualRegions: redactionState.regions, in: document, textLayerStatus: [0: .rich])
        #expect(set.terms.isEmpty, "a whole-page region names no term: \(set.terms.map(\.text))")
        #expect(set.manualRegionsWithoutText == 1, "and it is counted with the regions the string search could not capture")
    }

    @Test("A live search result on the page raises no nearby-match nudge: the region covers it rather than neighbouring it")
    func noNudgeWithAnActiveSearch() {
        let (documentState, redactionState) = Self.makeStates(currentPage: 0)
        let search = SearchState()
        search.results = [
            SearchResult(
                pageIndex: 0,
                normalizedRect: CGRect(x: 0.2, y: 0.5, width: 0.3, height: 0.04),
                matchedText: "123-45-6789",
                contextSnippet: "…123-45-6789…",
                source: .textLayer,
                term: "PII Scan",
                isSelected: true,
                piiCategory: .ssn,
                piiConfidence: 0.91,
                rationale: nil),
        ]
        redactionState.activeSearch = search
        Self.mark(documentState, redactionState)
        #expect(redactionState.regions[0]?.count == 1)
        #expect(redactionState.pendingManualDrawNudge == nil)
    }

    // MARK: - The bar's source

    @Test("The bar carries the action with its label and identifier, floored to the shared touch target, and no disabled modifier of its own")
    func barSourcePins() throws {
        let source = try Self.repoFile("Sources/ResectaApp/Views/PageNavigationBar.swift")
        #expect(source.contains("accessibilityLabel(\"Mark Whole Page\")"))
        #expect(source.contains("accessibilityIdentifier(\"pageNavMarkWholePage\")"))
        #expect(source.contains("@Environment(\\.undoManager)"))
        #expect(source.contains("PageNavigationBar.markWholePage("))
        #expect(source.contains("PageNavigationBar.regionCountLabel("))
        // The two chevrons are the only disabled controls: the action
        // is enabled whenever the bar is shown.
        #expect(source.components(separatedBy: ".disabled(").count - 1 == 2)
        // Three floored controls, each framed to the token and given a
        // rectangular content shape.
        #expect(source.components(separatedBy: "ResectaTokens.TouchTarget.minimum").count - 1 == 6)
        #expect(source.components(separatedBy: ".contentShape(Rectangle())").count - 1 == 3)
        // The chevrons' identifiers are untouched.
        #expect(source.contains("accessibilityIdentifier(\"pageNavPrevious\")"))
        #expect(source.contains("accessibilityIdentifier(\"pageNavNext\")"))
    }

    @Test("The capture rule's comment names the action as the bar does")
    func captureRuleCommentNamesTheAction() throws {
        let source = try Self.repoFile("Sources/ResectaApp/State/PipelineRunSupport+ManualTerms.swift")
        #expect(source.contains("\"Mark Whole Page\""))
        #expect(!source.contains("\"Redact Whole Page\""))
    }
}
