import Foundation

// Two lines the approved rows have no words for, both provisional until
// their words are approved: a page no report reached, and pictures that had to be
// read with no cause given. Not drawn yet. Pages are zero-based here and
// named one-based.

extension SearchStatement {

    enum ProvisionalWords {

        /// A page no report reached, in a run that completed.
        static func noReport(pages: [Int]) -> String? {
            guard let (list, one) = named(pages) else { return nil }
            return one
                ? "Page \(list) has no record of being searched. Check it by eye."
                : "Pages \(list) have no record of being searched. Check them by eye."
        }

        /// Pictures on a page with its own text had to be read, and no cause was given.
        static func picturesNotReported(pages: [Int]) -> String? {
            guard let (list, one) = named(pages) else { return nil }
            return one
                ? "The pictures on page \(list) were not read. Check it by eye."
                : "The pictures on pages \(list) were not read. Check them by eye."
        }

        private static func named(_ pages: [Int]) -> (String, Bool)? {
            let oneBased = Array(Set(pages)).sorted().map { $0 + 1 }
            guard !oneBased.isEmpty else { return nil }
            return (SearchResultsSection.formatPageList(oneBased), oneBased.count == 1)
        }
    }
}
