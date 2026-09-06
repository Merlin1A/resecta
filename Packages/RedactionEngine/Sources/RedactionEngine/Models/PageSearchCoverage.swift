import Foundation

/// What `DocumentSearcher` reported for one page it visited: which evidence
/// the page was read from, or why it was not read. Delivered through
/// `DocumentSearcher.setPageCoverageSink(_:)` — the search-side seam for the
/// verification search re-check. Reporting-only: installing the sink never
/// changes which results a search yields.
public struct PageSearchCoverage: Sendable, Equatable {
    public enum Route: Sendable, Equatable {
        /// The page's text layer was searched.
        case textLayer
        /// The page was rendered and read by OCR (cached or fresh).
        case ocr
        /// The page's render exceeded the OCR pixel caps; OCR did not run.
        case ocrSkippedOversize
        /// The page could not be rendered, or OCR reported an error.
        case ocrUnavailable
        /// The page could not be opened.
        case unopenable
    }

    public let pageIndex: Int
    public let route: Route

    public init(pageIndex: Int, route: Route) {
        self.pageIndex = pageIndex
        self.route = route
    }
}
