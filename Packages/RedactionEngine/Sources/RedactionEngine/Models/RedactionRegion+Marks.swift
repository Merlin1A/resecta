import CoreGraphics
import Foundation
import RedactionCore

// A region's two marks: where they are set, and how the plan reads them.
// "Placed from the page's own text" is set once where a region is made;
// `textAnchored` is that and "not moved or resized since".

extension RedactionRegion {
    /// The region a Search or Scan result places. The one maker for the app's
    /// placing sites and the verification corpus's runner, so every region
    /// placed from a result carries both marks as the app sets them: placed
    /// from the page's own text, and anchored, exactly when the result was
    /// read from the text layer; a result read from the page's picture is
    /// neither.
    public init(placing result: SearchResult) {
        self.init(id: UUID(), normalizedRect: result.normalizedRect,
                  source: .searchMatch(term: result.term, rationale: result.rationale),
                  textLayerRect: result.textLayerRect,
                  textAnchored: result.source == .textLayer)
    }
}

extension RegionKind {
    /// The region's kind, read from its source and its two marks, in the
    /// order of the plan's table: drawn by hand (its source is manual; a
    /// duplicate is one); placed from the text and still anchored; placed
    /// from the text, then moved or resized; placed from the page's picture.
    package init(of region: RedactionRegion) {
        if case .manual = region.source {
            self = .drawnByHand
        } else if region.textAnchored {
            self = .placedFromTextAnchored
        } else if region.placedFromPageText {
            self = .placedFromTextThenEdited
        } else {
            self = .placedFromPicture
        }
    }
}
