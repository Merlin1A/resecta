import Foundation

/// The account of what one search run read, as the app and the search
/// record see it: a narrow public face over `AccountOfWhatWasRead`, which
/// stays internal so its rules can still change. The app folds the
/// searcher's page reports and its own two signals (recognition off, a
/// pattern that ran out of time) into it, ends it, and reads the pages
/// behind each line of the statement about the run.
public struct SearchAccount: Sendable, Hashable {

    /// How the run ended. Pages are zero-based.
    public enum Ending: Sendable, Hashable {
        case completed
        case stoppedAtResultLimit(page: Int)
        case stopped(page: Int)
    }

    /// Why a page's pictures were not read, in the order their lines stand.
    /// `notReported` is a page whose pictures had to be read and no report
    /// or signal says why they were not: it stops Redact like the others.
    public enum PictureCause: Sendable, Hashable, CaseIterable {
        case recognitionFailed, recognitionFoundNoText, tooLarge, recognitionOff, notReported
    }

    /// The reason a line of the statement is given, one line per reason.
    public enum LineReason: Sendable, Hashable {
        case couldNotBeOpened, recognitionFailed, recognitionFoundNoText, tooLarge, recognitionOff
        case picturesNotRead(PictureCause)
        case patternTimedOut, notReached, noReport

        /// Every reason, in the fixed order the lines stand in.
        public static let order: [LineReason] =
            [.couldNotBeOpened, .recognitionFailed, .recognitionFoundNoText, .tooLarge, .recognitionOff]
            + PictureCause.allCases.map { .picturesNotRead($0) }
            + [.patternTimedOut, .notReached, .noReport]
    }

    private(set) var account: AccountOfWhatWasRead
    /// Per page, the searched texts that ran out of time there: the one fact
    /// in which two texts of one run can differ.
    public private(set) var patternTimedOutTexts: [Int: Set<String>] = [:]
    /// Per page, the texts of matches found there that could not be given a box.
    public private(set) var unboxedMatchTexts: [Int: Set<String>] = [:]

    public init(pageCount: Int) { account = AccountOfWhatWasRead(pageCount: pageCount) }

    public mutating func record(_ coverage: PageSearchCoverage) { account.record(coverage) }

    /// Facts given directly: for tests, which build pages the searcher would report.
    mutating func record(_ facts: AccountOfWhatWasRead.Facts, forPage page: Int) { account.record(facts, forPage: page) }

    public mutating func recordRecognitionOff(page: Int) { account.record(.recognitionOff, forPage: page) }

    public mutating func recordPatternTimedOut(page: Int, text: String) {
        account.record(.patternTimedOut, forPage: page)
        patternTimedOutTexts[page, default: []].insert(text)
    }

    public mutating func recordUnboxedMatch(page: Int, text: String) { unboxedMatchTexts[page, default: []].insert(text) }

    public mutating func end(_ ending: Ending) {
        switch ending {
        case .completed: account.end(.completed)
        case .stoppedAtResultLimit(let page): account.end(.stoppedAtResultLimit(page: page))
        case .stopped(let page): account.end(.stopped(page: page))
        }
    }

    public var pageCount: Int { account.pageCount }

    public var ending: Ending {
        switch account.ending {
        case .completed: .completed
        case .stoppedAtResultLimit(let page): .stoppedAtResultLimit(page: page)
        case .stopped(let page): .stopped(page: page)
        }
    }

    /// The page the run stopped on, searched in part; nil for a completed run.
    public var stopPage: Int? {
        switch account.ending {
        case .completed: nil
        case .stoppedAtResultLimit(let page), .stopped(let page): account.settled.contains(page) ? nil : page
        }
    }

    /// The account of one searched text of this run: a run's texts share every
    /// page fact but a pattern running out of time, which it keeps only where
    /// that text ran out.
    public func forText(_ text: String) -> SearchAccount {
        var facts = account.facts
        for page in facts.indices where patternTimedOutTexts[page]?.contains(text) != true {
            facts[page].remove(.patternTimedOut)
        }
        var derived = self
        derived.account = AccountOfWhatWasRead(facts: facts, ending: account.ending, settled: account.settled)
        derived.patternTimedOutTexts = patternTimedOutTexts.compactMapValues { $0.contains(text) ? [text] : nil }
        return derived
    }

    /// The facts that say something was read, or what the page holds.
    private static let kept: AccountOfWhatWasRead.Facts =
        [.ownText, .anotherAppsLayer, .recognised, .emptyReadBlank, .picturesRequired, .smallPictures]

    /// One text's runs joined, oldest first, for the stop at Redact: a page any
    /// run read is read, with that run's facts. Any other page keeps the facts
    /// that say something was read or what it holds from every run, and takes
    /// its other facts, and its place against the ending, from the latest;
    /// a page the latest gave no facts stays as the latest left it. Nil for
    /// no runs. The matches with no box are every run's.
    public static func joined(_ runs: [SearchAccount]) -> SearchAccount? {
        guard var joined = runs.last else { return nil }
        let latest = joined.account
        var facts = latest.facts
        var settled = Set<Int>()
        for page in facts.indices {
            let reading = runs.last { run in
                run.account.facts.indices.contains(page) && run.account.state(ofPage: page).kind == .read
            }
            if let reading {
                facts[page] = reading.account.facts[page]
                settled.insert(page)
            } else if !facts[page].isEmpty {
                // A page the latest run gave nothing (no report, or not reached)
                // stays as the latest left it: taking only the earlier "read"
                // facts would drop the earlier gap and count an unknown read as read.
                for run in runs where run.account.facts.indices.contains(page) {
                    facts[page].formUnion(run.account.facts[page].intersection(kept))
                }
            }
        }
        joined.account = AccountOfWhatWasRead(facts: facts, ending: latest.ending, settled: settled)
        for run in runs.dropLast() {
            joined.unboxedMatchTexts.merge(run.unboxedMatchTexts) { $0.union($1) }
        }
        return joined
    }

    /// The pages behind one line, ascending. For `notReached` these are the
    /// pages after the stop page that no report reached; the stop page itself
    /// is `stopPage`, and is not among them.
    public func pages(for reason: LineReason) -> [Int] {
        let summary = account.summary
        switch reason {
        case .couldNotBeOpened: return summary.pages(in: .couldNotBeOpened)
        case .recognitionFailed: return summary.pages(in: .recognitionFailed)
        case .recognitionFoundNoText: return summary.pages(in: .recognitionFoundNoText)
        case .tooLarge: return summary.pages(in: .tooLarge)
        case .recognitionOff: return summary.pages(in: .recognitionOff)
        case .picturesNotRead(let cause): return Self.picturePages(cause, in: summary)
        case .patternTimedOut: return summary.pages(withReason: .patternTimedOut)
        case .notReached:
            return (summary.pages(in: .notReachedResultLimit) + summary.pages(in: .notReachedStopped)).sorted()
        // The stop page belongs to "not reached" as searched in part, even with no report.
        case .noReport: return summary.pages(in: .noReport).filter { $0 != stopPage }
        }
    }

    /// Pages read by recognition or through another app's text.
    public var qualifiedPages: [Int] { account.summary.qualifiedPages }

    /// Pages whose only gap is small pictures: the quiet line's count.
    public var quietPages: [Int] { account.summary.quietPages }

    /// True only when every page was read from its own text or is blank.
    public var plainNoMatchAllowed: Bool { account.summary.plainNoMatchAllowed }

    /// Every page not read, and every page partly read for a reason other than small pictures.
    public var pagesThatStopRedact: [Int] { account.summary.pagesThatStopRedact }

    /// A page whose pictures were not read has one cause: the first known of
    /// the four, or `notReported` when none is known.
    private static let knownCauses: [(PictureCause, AccountOfWhatWasRead.Reason)] = [
        (.recognitionFailed, .recognitionFailed), (.recognitionFoundNoText, .recognitionFoundNoText),
        (.tooLarge, .tooLarge), (.recognitionOff, .recognitionOff),
    ]

    private static func picturePages(_ cause: PictureCause, in summary: AccountOfWhatWasRead.Summary) -> [Int] {
        summary.states.indices.filter { page in
            guard case .partlyRead(let reasons) = summary.states[page] else { return false }
            let first = knownCauses.first { reasons.contains($0.1) }?.0
            if let first { return first == cause }
            return cause == .notReported && reasons.contains(.picturesNotRead)
        }
    }
}
