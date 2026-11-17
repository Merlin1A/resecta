import SwiftUI

// The page counter's menu, on a document of two or more pages: Go to Page…
// (a prompt for a page number), the next and the previous page that holds a
// box, and a total line that cannot be tapped. Every page change goes through
// the page bar's one page write, `PageNavigationBar.showPage`, so a parked
// Search walk lets go of a match on another page as it does for the arrows.

/// The page menu's words, in one place.
enum PageMenuWords {
    static let goToPage = "Go to Page\u{2026}"
    static let nextPageWithBoxes = "Next Page with Boxes"
    static let previousPageWithBoxes = "Previous Page with Boxes"
    static let noBoxes = "No boxes yet"
    static let promptTitle = "Go to Page"
    static let go = "Go"
    static let cancel = "Cancel"
    /// The counter's spoken hint, after its label.
    static let counterHint = "Opens the page menu."

    /// The prompt's field hint: "Page 1 to 23".
    static func fieldHint(pageCount: Int) -> String {
        "Page 1 to \(pageCount)"
    }

    /// The total line: "17 boxes on 6 pages", its one-page forms, or
    /// "No boxes yet". A page holding a box holds at least one, so there are
    /// never fewer boxes than pages.
    static func totalLine(boxes: Int, pages: Int) -> String {
        if boxes == 0 { return noBoxes }
        if pages == 1 { return boxes == 1 ? "1 box on 1 page" : "\(boxes) boxes on 1 page" }
        return "\(boxes) boxes on \(pages) pages"
    }
}

/// The counter as the label of the page menu.
struct PageMenu<Label: View>: View {
    @Environment(DocumentState.self) private var documentState
    @Environment(RedactionState.self) private var redactionState
    let pageCount: Int
    @ViewBuilder let label: Label

    @State private var showsPrompt = false
    @State private var typed = ""

    var body: some View {
        // Read once for each drawing of the bar, not once for each row.
        let current = documentState.currentPageIndex
        let regions = redactionState.regions
        let next = RedactionState.nextPageWithRegions(after: current, in: regions, pageCount: pageCount)
        let previous = RedactionState.previousPageWithRegions(before: current, in: regions, pageCount: pageCount)
        let totals = RedactionState.regionTotals(in: regions, pageCount: pageCount)
        let typedPage = RedactionState.typedPage(typed, pageCount: pageCount)
        Menu {
            Section {
                Button(PageMenuWords.goToPage) {
                    typed = ""
                    showsPrompt = true
                }
                Button(PageMenuWords.nextPageWithBoxes) {
                    if let next { show(next) }
                }
                .disabled(next == nil)
                Button(PageMenuWords.previousPageWithBoxes) {
                    if let previous { show(previous) }
                }
                .disabled(previous == nil)
            }
            Section {
                Text(PageMenuWords.totalLine(boxes: totals.regions, pages: totals.pages))
            }
        } label: {
            label
        }
        .menuOrder(.fixed)
        // The counter keeps its own colours: the menu does not tint it.
        .tint(.primary)
        .alert(PageMenuWords.promptTitle, isPresented: $showsPrompt) {
            TextField(PageMenuWords.fieldHint(pageCount: pageCount), text: $typed)
                .keyboardType(.numberPad)
            Button(PageMenuWords.go) {
                if let typedPage { show(typedPage - 1) }
                // Close it here: iOS 27 does not always write the dismissal
                // back through the binding.
                if #available(iOS 27, *) { showsPrompt = false }
            }
            .disabled(typedPage == nil)
            Button(PageMenuWords.cancel, role: .cancel) {
                if #available(iOS 27, *) { showsPrompt = false }
            }
        }
    }

    private func show(_ page: Int) {
        PageNavigationBar.showPage(page, documentState: documentState, redactionState: redactionState)
    }
}
