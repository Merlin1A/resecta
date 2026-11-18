import SwiftUI
import RedactionEngine

// The row of a match that was found but could not be given a box
// (`SearchResult.hasBox == false`): listed with its page and no tick box,
// never dropped. A caution triangle sits in the tick circle's place and
// the approved sentence is a quiet line under the context. Apply
// makes no region from it (`prepareApply`) and Select All does not count it.
// Its guards elsewhere: `SearchState.setSelection` never selects it (the one
// selection primitive), `toggleSelectAll` and `toggleSelection` skip it, the
// Return pre-select passes over it, `deselectedCount` and the sweep's
// deselection snapshot leave it out (nobody un-ticked it), an occurrence is
// decided by its first piece with a box, the canvas coordinator never hands it
// to the overlay (no highlight, ring or VoiceOver frame), the walk shows its
// whole page, and the draw nudge never offers it.

enum NoBoxRowCopy {
    /// The approved sentence, word for word, with the page number as its variable. A match
    /// on a line wholly outside the visible page shows the first sentence
    /// alone: the second would point at something that is not there.
    static func sentence(pageIndex: Int, liesOffVisiblePage: Bool) -> String {
        let first = "Found on page \(pageIndex + 1), but Resecta can't place a box on it."
        return liesOffVisiblePage ? first : first + " If you can see it there, draw a box by hand."
    }
}

extension SearchResultRow {
    /// In the tick circle's place on a row with no box: decorative, the
    /// row's merged label carries the sentence.
    var noBoxMark: some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .font(.title3)
            .foregroundStyle(.secondary)
            .frame(
                width: ResectaTokens.TouchTarget.minimum,
                height: ResectaTokens.TouchTarget.minimum
            )
            .accessibilityHidden(true)
    }

    /// The approved sentence as a quiet line under the context.
    var noBoxLine: some View {
        Text(NoBoxRowCopy.sentence(pageIndex: result.pageIndex, liesOffVisiblePage: result.liesOffVisiblePage))
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
