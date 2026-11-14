import Foundation

// MARK: - Live Preview / Scope-Aware Navigation

/// Scope of a live-preview pass. Controls how many pages
/// `DocumentSearcher.previewMatches` walks while still scoping the
/// per-page highlight ranges to the visible page.
public enum SearchPreviewScope: Sendable, Equatable {
    case currentPage(pageIndex: Int)
    case wholeDocument
}

/// Result of a live-preview pass. `currentPageMatches` is always
/// scoped to the visible page so the overlay can highlight without
/// rescanning, while `totalCount` reflects the requested scope.
public struct SearchPreviewResult: Sendable, Equatable {
    public let scope: SearchPreviewScope
    public let totalCount: Int
    public let saturated: Bool
    public let regexInvalid: Bool
    public let currentPageMatches: [NSRange]
    /// The visible page's matches as ranges in the raw page text
    /// (`PDFPage.string`): the ranges the full search places its boxes
    /// from, through the same page map. `currentPageMatches` is in the
    /// searched text's coordinates, which shift on a page whose text the
    /// search normalizes (a ligature, a wide character); a highlight drawn
    /// from these ranges sits where Apply's box will. A match the map cannot
    /// place is left out, as the full search leaves it out.
    public let currentPageRawRanges: [NSRange]
    /// Why a `.regex` preview is empty when `regexInvalid` is set: the
    /// safety gate's typed reason or the engine's compile error text.
    /// nil for every other result.
    public let regexRejection: String?

    public init(
        scope: SearchPreviewScope,
        totalCount: Int,
        saturated: Bool,
        regexInvalid: Bool,
        currentPageMatches: [NSRange],
        currentPageRawRanges: [NSRange] = [],
        regexRejection: String? = nil
    ) {
        self.scope = scope
        self.totalCount = totalCount
        self.saturated = saturated
        self.regexInvalid = regexInvalid
        self.currentPageMatches = currentPageMatches
        self.currentPageRawRanges = currentPageRawRanges
        self.regexRejection = regexRejection
    }

    public static func == (lhs: SearchPreviewResult, rhs: SearchPreviewResult) -> Bool {
        lhs.scope == rhs.scope
            && lhs.totalCount == rhs.totalCount
            && lhs.saturated == rhs.saturated
            && lhs.regexInvalid == rhs.regexInvalid
            && lhs.currentPageMatches == rhs.currentPageMatches
            && lhs.currentPageRawRanges == rhs.currentPageRawRanges
            && lhs.regexRejection == rhs.regexRejection
    }
}
