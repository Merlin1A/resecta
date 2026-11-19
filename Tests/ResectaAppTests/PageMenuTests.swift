import Testing
import Foundation
import CoreGraphics
import RedactionEngine
@testable import ResectaApp

// The page counter's menu: the next and the previous page that holds a box,
// the total of boxes and pages, the typed page of Go to Page, and the menu's
// place on a document of two or more pages only.

@MainActor
@Suite("Page menu")
struct PageMenuTests {

    private static func region() -> RedactionRegion {
        RedactionRegion(id: UUID(), normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.05), source: .manual)
    }

    private static func regions(_ countsByPage: [Int: Int]) -> [Int: [RedactionRegion]] {
        countsByPage.mapValues { n in (0..<n).map { _ in region() } }
    }

    /// A repository file read relative to this test's own path.
    private static func repoFile(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    @Test("The next page with a box is the nearest later page that holds one, and none after the last")
    func nextPageWithABox() {
        let none: [Int: [RedactionRegion]] = [:]
        for page in 0..<23 { #expect(RedactionState.nextPageWithRegions(after: page, in: none, pageCount: 23) == nil) }
        // Boxes on pages 3 and 7 (index 2 and 6).
        let two = Self.regions([2: 1, 6: 2])
        #expect(RedactionState.nextPageWithRegions(after: 0, in: two, pageCount: 23) == 2)
        #expect(RedactionState.nextPageWithRegions(after: 2, in: two, pageCount: 23) == 6)
        #expect(RedactionState.nextPageWithRegions(after: 6, in: two, pageCount: 23) == nil)
        #expect(RedactionState.nextPageWithRegions(after: 22, in: two, pageCount: 23) == nil)
        // Page 4 (index 3) held a box that was removed: an empty list.
        let emptied = Self.regions([3: 0, 6: 1])
        #expect(RedactionState.nextPageWithRegions(after: 0, in: emptied, pageCount: 23) == 6)
    }

    @Test("The previous page with a box is the nearest earlier page that holds one, and none before the first")
    func previousPageWithABox() {
        let none: [Int: [RedactionRegion]] = [:]
        for page in 0..<23 { #expect(RedactionState.previousPageWithRegions(before: page, in: none, pageCount: 23) == nil) }
        let two = Self.regions([2: 1, 6: 2])
        #expect(RedactionState.previousPageWithRegions(before: 6, in: two, pageCount: 23) == 2)
        #expect(RedactionState.previousPageWithRegions(before: 2, in: two, pageCount: 23) == nil)
        #expect(RedactionState.previousPageWithRegions(before: 0, in: two, pageCount: 23) == nil)
        // The nearest, not the first: boxes on pages 3 and 5, from page 7.
        let nearer = Self.regions([2: 1, 4: 1])
        #expect(RedactionState.previousPageWithRegions(before: 6, in: nearer, pageCount: 23) == 4)
        let emptied = Self.regions([2: 1, 3: 0])
        #expect(RedactionState.previousPageWithRegions(before: 6, in: emptied, pageCount: 23) == 2)
    }

    /// The totals as [boxes, pages], on 23 pages.
    private static func totals(_ regions: [Int: [RedactionRegion]]) -> [Int] {
        let t = RedactionState.regionTotals(in: regions, pageCount: 23)
        return [t.regions, t.pages]
    }

    @Test("The total counts every box and every page that holds one")
    func totals() {
        #expect(Self.totals([:]) == [0, 0])
        #expect(Self.totals(Self.regions([3: 0])) == [0, 0])
        // 17 boxes over 6 pages, a whole-page mark among them: one box, as the bar counts it.
        var seventeen = Self.regions([0: 5, 2: 3, 4: 2, 9: 3, 15: 2, 22: 1, 7: 0])
        seventeen[22] = [PageNavigationBar.wholePageRegion()]
        #expect(Self.totals(seventeen) == [16, 6])
        seventeen[22]?.append(Self.region())
        #expect(Self.totals(seventeen) == [17, 6])
        // It equals the sum of the counts the bar shows page by page.
        let shown = (0..<23).reduce(0) { $0 + (seventeen[$1]?.count ?? 0) }
        #expect(RedactionState.regionTotals(in: seventeen, pageCount: 23).regions == shown)
    }

    @Test("The total line reads the chosen words for every count")
    func totalLine() {
        #expect(PageMenuWords.totalLine(boxes: 0, pages: 0) == "No boxes yet")
        #expect(PageMenuWords.totalLine(boxes: 1, pages: 1) == "1 box on 1 page")
        #expect(PageMenuWords.totalLine(boxes: 3, pages: 1) == "3 boxes on 1 page")
        #expect(PageMenuWords.totalLine(boxes: 17, pages: 6) == "17 boxes on 6 pages")
    }

    @Test("A typed page is a page only from 1 to the page count")
    func typedPage() {
        for text in ["", " ", "0", "24", "abc", "12a", "1.5", "-3", "+3", "1 2", "99999999999999999999999"] {
            #expect(RedactionState.typedPage(text, pageCount: 23) == nil, "\"\(text)\" is not a page")
        }
        #expect(RedactionState.typedPage("1", pageCount: 23) == 1)
        #expect(RedactionState.typedPage("12", pageCount: 23) == 12)
        #expect(RedactionState.typedPage("23", pageCount: 23) == 23)
        #expect(RedactionState.typedPage(" 12 ", pageCount: 23) == 12)
        #expect(RedactionState.typedPage("012", pageCount: 23) == 12)
        #expect(RedactionState.typedPage("1", pageCount: 0) == nil)
    }

    @Test("The menu shows from two pages; a one-page document keeps the plain counter")
    func showsFromTwoPages() {
        #expect(!PageNavigationBar.showsPageMenu(pageCount: 1))
        #expect(PageNavigationBar.showsPageMenu(pageCount: 2))
        #expect(PageNavigationBar.showsPageMenu(pageCount: 23))
    }

    @Test("Every page change in the menu goes through the bar's one page write")
    func everyMoveCallsShowPage() throws {
        let source = try Self.repoFile("Sources/ResectaApp/Views/PageMenu.swift")
        #expect(source.contains("PageNavigationBar.showPage("))
        #expect(!source.contains("currentPageIndex = "))
        #expect(!source.contains("currentPageIndex +="))
        #expect(!source.contains("currentPageIndex -="))
    }

    @Test("The menu's words are the chosen words")
    func chosenWords() {
        #expect(PageMenuWords.goToPage == "Go to Page\u{2026}")
        #expect(PageMenuWords.nextPageWithBoxes == "Next Page with Boxes")
        #expect(PageMenuWords.previousPageWithBoxes == "Previous Page with Boxes")
        #expect(PageMenuWords.noBoxes == "No boxes yet")
        #expect(PageMenuWords.promptTitle == "Go to Page")
        #expect(PageMenuWords.fieldHint(pageCount: 23) == "Page 1 to 23")
        #expect(PageMenuWords.go == "Go")
        #expect(PageMenuWords.cancel == "Cancel")
        #expect(PageMenuWords.counterHint == "Opens the page menu.")
    }

    @Test("The counter's menu button is floored to the shared touch target")
    func counterIsFloored() throws {
        let source = try Self.repoFile("Sources/ResectaApp/Views/PageNavigationBar.swift")
        let menu = try #require(source.range(of: "PageMenu(pageCount: pageCount)")?.lowerBound, "the bar opens the page menu")
        let hint = try #require(source.range(of: "PageMenuWords.counterHint")?.lowerBound, "the menu carries its hint")
        let label = source[menu..<hint]
        #expect(label.contains(".frame(minHeight: ResectaTokens.TouchTarget.minimum)"))
        #expect(label.contains(".contentShape(Rectangle())"))
    }
}
