import Foundation
import RedactionEngine

// The widened boxes. A Search box over a page image whose text the ink fit
// could not fit to the printed word is drawn as the larger envelope around
// where the word can be (`SearchResult.inkFitDegraded`). Shrinking one back
// to the word can leave part of it readable, so the results sheet names the
// pages holding one (`SearchWidenedBoxBanner`) and the page in view says so
// in the bottom capsule, before the apply and after it. An applied box keeps
// the flag on its audit snapshot (`MatchAuditSnapshot.inkFitDegraded`),
// which rides undo and redo with its region; a deleted region drops out with
// the region, a moved or resized one keeps it.

extension SearchState {
    /// The pages (0-based) holding a result drawn as a widened box.
    var widenedBoxPages: Set<Int> {
        Set(results.lazy.filter(\.inkFitDegraded).map(\.pageIndex))
    }

    /// Results as they land in the published list. In DEBUG builds the
    /// `--uitestWidenPage=N` launch argument (0-based) marks page N's
    /// results widened, so UI tests and screenshots can show the notices
    /// without a page whose ink fit fails; release builds pass them through.
    nonisolated static func landing(_ results: [SearchResult]) -> [SearchResult] {
        #if DEBUG
        let prefix = "--uitestWidenPage="
        guard let page = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix(prefix) })
            .flatMap({ Int($0.dropFirst(prefix.count)) }) else { return results }
        return results.map { r in
            guard r.pageIndex == page, !r.inkFitDegraded else { return r }
            return SearchResult(
                id: r.id, pageIndex: r.pageIndex, normalizedRect: r.normalizedRect, matchedText: r.matchedText,
                contextSnippet: r.contextSnippet, source: r.source, term: r.term, isSelected: r.isSelected,
                piiCategory: r.piiCategory, piiConfidence: r.piiConfidence, rationale: r.rationale,
                matchRangeInSnippet: r.matchRangeInSnippet, occurrenceID: r.occurrenceID,
                textLayerRect: r.textLayerRect, inkFitDegraded: true)
        }
        #else
        return results
        #endif
    }
}

extension RedactionState {
    /// The pages (0-based) holding a live region applied from a widened box.
    var widenedRegionPages: Set<Int> {
        Set(regions.lazy
            .filter { _, list in list.contains { self.appliedMatchAudit[$0.id]?.inkFitDegraded == true } }
            .map(\.key))
    }

    /// Whether `page` holds a widened box: a live region applied from one,
    /// or a result of the open search session.
    func pageHoldsWidenedBox(_ page: Int) -> Bool {
        widenedRegionPages.contains(page) || (activeSearch?.widenedBoxPages.contains(page) ?? false)
    }
}
