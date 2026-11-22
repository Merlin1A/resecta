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

    /// Of an `ocr` report whose accurate read returned no line: whether the
    /// picture recognition was given holds ink (`PageInk`).
    public enum EmptyRead: Sendable, Equatable {
        case blank
        case ink
    }

    /// Of a `textLayer` report on a page with pictures: whether the picture
    /// rule requires them read, or they are below its floors.
    public enum Pictures: Sendable, Equatable {
        case required
        case belowFloors
    }

    public let pageIndex: Int
    public let route: Route
    /// Nil unless the route is `ocr` and the accurate read returned no line.
    public let emptyRead: EmptyRead?
    /// Nil when the report says nothing of the page's pictures.
    public let pictures: Pictures?
    /// The searched text is hidden text over a page-size picture: another
    /// app's recognition.
    public let throughAnotherAppsLayer: Bool
    /// The page is fitted because its painting cannot be followed, so where
    /// its print lies is not known; it is not said to be another app's text.
    public let paintingNotFollowed: Bool

    init(pageIndex: Int, route: Route, emptyRead: EmptyRead? = nil, pictures: Pictures? = nil,
         throughAnotherAppsLayer: Bool = false, paintingNotFollowed: Bool = false) {
        self.pageIndex = pageIndex
        self.route = route
        self.emptyRead = emptyRead
        self.pictures = pictures
        self.throughAnotherAppsLayer = throughAnotherAppsLayer
        self.paintingNotFollowed = paintingNotFollowed
    }
}
