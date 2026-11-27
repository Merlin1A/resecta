import RedactionEngine

// What the Search sheet says about one run, as one pure function of the
// mode, whether the list has results, the run's account and the count of
// results a filter hides. It decides the parts and their pages; the words
// of each part are the approved row it names. Not drawn yet: the sheet's
// view still shows today's empty state and banners.

enum SearchStatement {

    /// The headline above an empty list.
    enum Headline: Equatable, Sendable {
        /// Today's plain no-match.
        case plain
        /// Today's lead alone: the first sentence of the qualified no-match.
        case lead
        /// Today's whole qualified no-match, with its count.
        case qualified(Int)
        /// The mode's words for a run that did not finish; no no-match statement.
        case stopped
        /// The stopped form, then the recognition warning with its count.
        case stoppedWithRecognition(Int)
    }

    /// One line: its reason and its pages. "Not reached" is also given the
    /// page the run stopped on, searched in part and not counted, and how
    /// the run ended.
    struct Line: Equatable, Sendable {
        let reason: SearchAccount.LineReason
        let pages: [Int]
        var stopPage: Int? = nil
        var atResultLimit: Bool = false
        var count: Int { pages.count }
    }

    struct Statement: Equatable, Sendable {
        /// Nil when the list has results.
        let headline: Headline?
        let lines: [Line]
        /// The pages whose only gap is small pictures; nil when there are none.
        let quietCount: Int?
        /// Results a filter hides, ticked or not; nil when none are hidden.
        let hiddenCount: Int?
    }

    static func statement(
        mode: SearchModeType, hasResults: Bool, account: SearchAccount, hiddenCount: Int
    ) -> Statement {
        var lines: [Line] = []
        for reason in SearchAccount.LineReason.order {
            let pages = account.pages(for: reason)
            if reason == .notReached, let stop = account.stopPage {
                // A run that stopped on its last page still gives the line, with a count of none.
                var atLimit = false
                if case .stoppedAtResultLimit = account.ending { atLimit = true }
                lines.append(Line(reason: reason, pages: pages, stopPage: stop, atResultLimit: atLimit))
            } else if !pages.isEmpty {
                lines.append(Line(reason: reason, pages: pages))
            }
        }
        let quiet = account.quietPages.count
        return Statement(
            headline: hasResults ? nil : headline(account),
            lines: lines,
            quietCount: quiet > 0 ? quiet : nil,
            hiddenCount: hiddenCount > 0 ? hiddenCount : nil)
    }

    /// Exactly one headline above an empty list. A run that did not complete
    /// makes no no-match statement; pages read by recognition always carry
    /// the warning, whatever else is unread.
    private static func headline(_ account: SearchAccount) -> Headline {
        let recognised = account.qualifiedPages.count
        guard account.ending == .completed else {
            return recognised > 0 ? .stoppedWithRecognition(recognised) : .stopped
        }
        if account.plainNoMatchAllowed { return .plain }
        return recognised > 0 ? .qualified(recognised) : .lead
    }
}
