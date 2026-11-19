import Testing
import Foundation
import CoreGraphics
import PDFKit
import UIKit
import RedactionEngine
@testable import ResectaApp

// The page bar's whole-page control: one tap marks the visible page as a
// region through the ordinary add path, so it behaves like a drawn
// region in every respect — one undo step, the same counter, no term
// captured from it, no nearby-match nudge from it — and the next tap
// unmarks it. The control shows on the bar of a multi-page document in
// the editing phase and is never disabled: a page it can show is a page
// it can mark or unmark.

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
        PageNavigationBar.toggleWholePage(
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

    // MARK: - The counter

    @Test("The bar's counter reads '1 region' after the tap, '0 regions' before it, and pluralises beyond one")
    func counterReadsOneRegion() {
        let (documentState, redactionState) = Self.makeStates(currentPage: 0)
        let countBefore = redactionState.regions[0]?.count ?? 0
        #expect(PageNavigationBar.regionCountLabel(countBefore) == "0 regions")
        Self.mark(documentState, redactionState)
        let count = redactionState.regions[documentState.currentPageIndex]?.count ?? 0
        #expect(PageNavigationBar.regionCountLabel(count) == "1 region")
        #expect(PageNavigationBar.regionCountLabel(2) == "2 regions")
    }

    // MARK: - Undo

    @Test("Undo removes the region in one step named Mark Whole Page")
    func undoRemovesTheRegion() {
        let (documentState, redactionState) = Self.makeStates(currentPage: 2)
        let undoManager = UndoManager()
        Self.mark(documentState, redactionState, undoManager: undoManager)
        #expect(undoManager.canUndo)
        #expect(undoManager.undoActionName == "Mark Whole Page")
        undoManager.undo()
        #expect((redactionState.regions[2] ?? []).isEmpty)
        #expect(!undoManager.canUndo)
        #expect(undoManager.canRedo)
        undoManager.redo()
        #expect(redactionState.regions[2]?.count == 1)
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

    // MARK: - The toggle

    private static func toggle(_ documentState: DocumentState, _ redactionState: RedactionState,
                               undoManager: UndoManager?) {
        undoManager?.beginUndoGrouping()
        PageNavigationBar.toggleWholePage(
            redactionState: redactionState, documentState: documentState, undoManager: undoManager)
        undoManager?.endUndoGrouping()
    }

    private static func box() -> RedactionRegion {
        RedactionRegion(id: UUID(), normalizedRect: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.05),
                        source: .manual)
    }

    @Test("A page reads as marked only while it holds the whole-page region")
    func markedReadsTheWholePageRegion() {
        let (documentState, redactionState) = Self.makeStates(currentPage: 1)
        #expect(!PageNavigationBar.isWholePageMarked(page: 1, in: redactionState))
        redactionState.addRegion(Self.box(), page: 1, undoManager: nil)
        #expect(!PageNavigationBar.isWholePageMarked(page: 1, in: redactionState),
                "a drawn box is not the whole-page region")
        Self.mark(documentState, redactionState)
        #expect(PageNavigationBar.isWholePageMarked(page: 1, in: redactionState))
        #expect(!PageNavigationBar.isWholePageMarked(page: 0, in: redactionState))
    }

    @Test("The toggle marks, then unmarks: one undo step each way, named for it; Undo after Unmark marks the page again")
    func toggleTwiceIsTwoNamedSteps() {
        let (documentState, redactionState) = Self.makeStates(currentPage: 0)
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        Self.toggle(documentState, redactionState, undoManager: undoManager)
        #expect(redactionState.regions[0]?.count == 1)
        #expect(undoManager.undoActionName == "Mark Whole Page")
        Self.toggle(documentState, redactionState, undoManager: undoManager)
        #expect((redactionState.regions[0] ?? []).isEmpty)
        #expect(undoManager.undoActionName == "Unmark Whole Page")
        undoManager.undo()
        #expect(PageNavigationBar.isWholePageMarked(page: 0, in: redactionState))
        #expect(undoManager.redoActionName == "Unmark Whole Page")
        undoManager.undo()
        #expect((redactionState.regions[0] ?? []).isEmpty)
    }

    @Test("Unmark removes the whole-page region only: the page's drawn boxes stay")
    func unmarkKeepsTheOtherRegions() {
        let (documentState, redactionState) = Self.makeStates(currentPage: 2)
        let drawn = Self.box()
        redactionState.addRegion(drawn, page: 2, undoManager: nil)
        Self.toggle(documentState, redactionState, undoManager: nil)
        #expect(redactionState.regions[2]?.count == 2)
        Self.toggle(documentState, redactionState, undoManager: nil)
        #expect(redactionState.regions[2]?.map(\.id) == [drawn.id])
    }

    @Test("The control's words follow the page: Mark Whole Page, then Unmark Whole Page")
    func labelFollowsThePage() {
        #expect(PageNavigationBar.wholePageActionLabel(marked: false) == "Mark Whole Page")
        #expect(PageNavigationBar.wholePageActionLabel(marked: true) == "Unmark Whole Page")
    }

    // MARK: - The zero arm and the one-page bar

    @Test("An empty page's counter reads '0 regions', drawn and spoken")
    func counterZeroArm() {
        #expect(PageNavigationBar.regionCountLabel(0) == "0 regions")
        #expect(PageNavigationBar.pageAccessibilityLabel(page: 1, pageCount: 3, regionCount: 0)
                == "Page 1 of 3, 0 regions")
    }

    @Test("A one-page document's bar keeps the count and drops the page arrows and the whole-page control")
    func onePageBarDropsArrowsAndControl() {
        #expect(!PageNavigationBar.showsChevrons(pageCount: 1))
        #expect(!PageNavigationBar.showsMarkControl(pageCount: 1))
        #expect(PageNavigationBar.showsChevrons(pageCount: 3))
        #expect(PageNavigationBar.showsMarkControl(pageCount: 3))
    }

    @Test("At accessibility sizes the counter stacks its position over its count, each on one line")
    func counterStacksAtAccessibilitySizes() {
        #expect(PageNavigationBar.counterStacks(dynamicTypeSize: .accessibility1))
        #expect(PageNavigationBar.counterStacks(dynamicTypeSize: .accessibility5))
        #expect(!PageNavigationBar.counterStacks(dynamicTypeSize: .xxxLarge))
        #expect(!PageNavigationBar.counterStacks(dynamicTypeSize: .large))
    }

    // MARK: - The bar's source

    @Test("The bar carries the control with its state's label and identifier, floored to the shared touch target, and no disabled modifier of its own")
    func barSourcePins() throws {
        let source = try Self.repoFile("Sources/ResectaApp/Views/PageNavigationBar.swift")
        #expect(source.contains("accessibilityLabel(PageNavigationBar.wholePageActionLabel(marked: marked))"))
        #expect(source.contains("accessibilityIdentifier(\"pageNavMarkWholePage\")"))
        #expect(source.contains("@Environment(\\.undoManager)"))
        #expect(source.contains("PageNavigationBar.toggleWholePage("))
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

    @Test("The bar's control carries its ceiling and its large-content view")
    func controlCarriesItsCeilingAndLargeContentView() throws {
        let source = try Self.repoFile("Sources/ResectaApp/Views/PageNavigationBar.swift")
        #expect(source.contains(".dynamicTypeSize(...PageNavigationBar.wholePageGlyphCeiling)"))
        #expect(source.contains("accessibilityShowsLargeContentViewer"))
        #expect(source.contains("Label(PageNavigationBar.wholePageActionLabel(marked: marked), systemImage: \"rectangle.inset.filled\")"))
    }

    @Test("The bar draws the whole-page control first, then its divider, Previous, the counter and Next")
    func barDrawsTheControlFirst() throws {
        let source = try Self.repoFile("Sources/ResectaApp/Views/PageNavigationBar.swift")
        func at(_ needle: String) throws -> String.Index {
            try #require(source.range(of: needle)?.lowerBound, "the bar's source holds \(needle)")
        }
        let control = try at("accessibilityIdentifier(\"pageNavMarkWholePage\")")
        let divider = try at("PageNavigationBar.wholePageDividerHeight(")
        let previous = try at("accessibilityIdentifier(\"pageNavPrevious\")")
        let counter = try at("\"pageNavCounter\"")
        let next = try at("\"pageNavNext\"")
        #expect(control < divider && divider < previous && previous < counter && counter < next,
                "the control, its divider, Previous, the counter, Next, in that order")
        // The divider is an overlay of the control, inside the control's
        // own `if` and before the Previous block's.
        let controlIf = try at("if PageNavigationBar.showsMarkControl(")
        let previousIf = try at("if PageNavigationBar.showsChevrons(")
        #expect(controlIf < divider && divider < previousIf, "the divider sits inside the control's block")
        let overlay = try #require(source[..<divider].range(of: ".overlay(", options: .backwards)?.lowerBound,
                                   "the divider is drawn in an overlay")
        #expect(control < overlay, "the overlay is the control's")
    }

    @Test("The count is drawn in the support grey at every number; the orange token is gone")
    func countTakesTheSupportGrey() throws {
        let bar = try Self.repoFile("Sources/ResectaApp/Views/PageNavigationBar.swift")
        #expect(bar.contains("ResectaTokens.SemanticColor.supportText"))
        #expect(!bar.contains("regionCountAccent"))
        #expect(!bar.contains(".tertiary"))
        #expect(!bar.contains(".orange"), "no number of regions draws the count orange")
        let tokens = try Self.repoFile("Sources/ResectaApp/Design/ResectaTokens.swift")
        #expect(!tokens.contains("regionCountAccent"))
        let sidebar = try Self.repoFile("Sources/ResectaApp/Views/PageThumbnailList.swift")
        #expect(sidebar.contains("supportText"))
        #expect(!sidebar.contains(".foregroundStyle(.orange)"))
    }

    @Test("The divider is 28 pt, and 44 pt at the accessibility sizes")
    func dividerFollowsTheTextSize() {
        #expect(PageNavigationBar.wholePageDividerHeight(dynamicTypeSize: .large) == 28)
        #expect(PageNavigationBar.wholePageDividerHeight(dynamicTypeSize: .xxxLarge) == 28)
        #expect(PageNavigationBar.wholePageDividerHeight(dynamicTypeSize: .accessibility1) == 44)
        #expect(PageNavigationBar.wholePageDividerHeight(dynamicTypeSize: .accessibility5) == 44)
    }

    // MARK: - The symbol at large text sizes

    // The control's symbol at the default text size ("Large", body 17 pt),
    // measured on a screenshot of the shipped build (402 x 874 pt screen,
    // 3 px per pt).
    private static let measuredSymbolWidthAtLarge: CGFloat = 19.3
    private static let measuredSymbolHeightAtLarge: CGFloat = 15.3

    @Test("The symbol's ceiling is the largest text size at which the symbol keeps 4 pt of its disc")
    func symbolCeilingKeepsItsDisc() {
        #expect(PageNavigationBar.wholePageGlyphCeiling == .xxxLarge)
        func body(_ category: UIContentSizeCategory) -> CGFloat {
            UIFont.preferredFont(forTextStyle: .body,
                                 compatibleWith: UITraitCollection(preferredContentSizeCategory: category)).pointSize
        }
        // The symbol grows in step with the body size; its half diagonal
        // plus the margin must stay within half the disc.
        let halfDiagonalAtLarge = hypot(Self.measuredSymbolWidthAtLarge, Self.measuredSymbolHeightAtLarge) / 2
        func reach(_ category: UIContentSizeCategory) -> CGFloat {
            halfDiagonalAtLarge * body(category) / body(.large) + PageNavigationBar.wholePageGlyphMargin
        }
        let halfDisc = PageNavigationBar.markedDiscDiameter / 2
        #expect(reach(.extraExtraExtraLarge) <= halfDisc, "at the ceiling the symbol keeps its margin of disc")
        #expect(reach(.accessibilityMedium) > halfDisc, "at the next size it would not")
    }

    @Test("The capture rule's comment names the action as the bar does")
    func captureRuleCommentNamesTheAction() throws {
        let source = try Self.repoFile("Sources/ResectaApp/State/PipelineRunSupport+ManualTerms.swift")
        #expect(source.contains("\"Mark Whole Page\""))
        #expect(!source.contains("\"Redact Whole Page\""))
    }
}
