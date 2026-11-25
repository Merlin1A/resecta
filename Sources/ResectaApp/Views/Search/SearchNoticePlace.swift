import Foundation
import RedactionEngine

// The rules of the one place above the results that says what a search did
// not read. Pure: no view and no state. The place shows one line at a time;
// a second line waits behind an arrow that opens the details, where every
// line that holds is listed with its pages. Every sentence is built by the
// builder that owns it; nothing here types a sentence but the result
// limit's, whose words are its row's.

/// One sentence the place may show, with the pages it names by number.
struct SearchNoticeLine: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// Pages a search did not read, or read in part.
        case notSearched
        /// The session's name detection is degraded (Scan only).
        case degraded
        /// Boxes drawn larger than their words.
        case fit
    }

    let kind: Kind
    /// Its builder's output, never retyped.
    let sentence: String
    /// 0-based, sorted: the pages the sentence names by number.
    let pages: [Int]
    let identifier: String

    /// What "the same notice" means for folding and for speaking it once.
    var key: String { identifier + "\u{1F}" + sentence }
}

enum SearchNoticePlace {

    /// The run's facts the lines are read from.
    struct Facts: Equatable, Sendable {
        var tooLargePages: Set<Int> = []
        var timedOutPages: Set<Int> = []
        var atResultLimit = false
        /// 1-based: the page the run was on when the result limit was met.
        var limitStopPage = 0
        /// Pages after the stop page that the run never reached.
        var unscannedPageCount = 0
        var interface: SearchInterface = .search
        var widenedPages: Set<Int> = []
    }

    static let tooLargeIdentifier = "ocrSkipBanner"
    static let timedOutIdentifier = "regexTimeoutNotice"
    static let resultLimitIdentifier = "resultLimitNotice"
    static let widenedIdentifier = "widenedBoxBanner"
    static let degradedIdentifier = "degradedDetectionBanner"

    /// The run's lines, in a fixed order, each present only while its fact
    /// holds: pages too large to scan, pages where the pattern timed out,
    /// the result limit, then boxes drawn larger than their words.
    static func runLines(_ facts: Facts) -> [SearchNoticeLine] {
        var lines: [SearchNoticeLine] = []
        if !facts.tooLargePages.isEmpty {
            let pages = facts.tooLargePages.sorted()
            lines.append(SearchNoticeLine(
                kind: .notSearched, sentence: SearchResultsSection.ocrSkipBannerHeadline(pages: pages),
                pages: pages, identifier: tooLargeIdentifier))
        }
        if !facts.timedOutPages.isEmpty {
            let pages = facts.timedOutPages.sorted()
            lines.append(SearchNoticeLine(
                kind: .notSearched, sentence: SearchResultsSection.regexTimeoutBannerHeadline(pages: pages),
                pages: pages, identifier: timedOutIdentifier))
        }
        if facts.atResultLimit {
            lines.append(SearchNoticeLine(
                kind: .notSearched,
                sentence: resultLimitSentence(
                    stopPage: facts.limitStopPage, unscannedPageCount: facts.unscannedPageCount,
                    interface: facts.interface),
                pages: facts.limitStopPage > 0 ? [facts.limitStopPage - 1] : [],
                identifier: resultLimitIdentifier))
        }
        if !facts.widenedPages.isEmpty {
            let pages = facts.widenedPages.sorted()
            lines.append(SearchNoticeLine(
                kind: .fit, sentence: SearchResultsSection.widenedBoxBannerHeadline(pages: pages),
                pages: pages, identifier: widenedIdentifier))
        }
        return lines
    }

    /// The result limit's sentence: how many results are listed, the page
    /// the search stopped on, and how many pages after it were not
    /// searched. Scan has no query to refine, so it drops the last sentence.
    ///
    /// The stop page is said to be searched in part whenever the limit is
    /// met. That is untrue only when the stop page held exactly the matches
    /// left under the limit, so that the page was read whole; it never says
    /// more of the document was read than was.
    static func resultLimitSentence(stopPage: Int, unscannedPageCount: Int, interface: SearchInterface) -> String {
        var text = "Showing first \(DocumentSearcher.maxResults.formatted(.number.locale(Locale(identifier: "en_US")))) results."
        if stopPage > 0 {
            let total = stopPage + max(0, unscannedPageCount)
            text += " Search stopped at page \(stopPage) of \(total), which it searched in part."
            switch unscannedPageCount {
            case ...0: break
            case 1: text += " The page after it was not searched."
            default: text += " The \(unscannedPageCount) pages after it were not searched."
            }
        }
        return interface == .scan ? text : text + " Refine your search for more specific matches."
    }

    /// The session's line: present while the degraded-detection notice
    /// shows for the interface in view.
    static func degradedLine(shows: Bool, failures: [String]) -> SearchNoticeLine? {
        guard shows else { return nil }
        return SearchNoticeLine(
            kind: .degraded, sentence: DetectionDegradeCopy.banner(failedGazetteers: failures),
            pages: [], identifier: degradedIdentifier)
    }

    /// The lines that hold, in rank order: pages not searched, then the
    /// degraded-detection line, then the fit line. While a run is in
    /// progress the run's part is the lines that held when it started.
    static func shownLines(
        run: [SearchNoticeLine], held: [SearchNoticeLine], isSearching: Bool, degraded: SearchNoticeLine?
    ) -> [SearchNoticeLine] {
        let runPart = isSearching ? held : run
        return runPart.filter { $0.kind == .notSearched }
            + (degraded.map { [$0] } ?? [])
            + runPart.filter { $0.kind == .fit }
    }

    enum Control: Equatable {
        /// No control: the whole text shows.
        case none
        /// A tap folds the notice to its first sentence, or unfolds it.
        case foldsInPlace(folded: Bool)
        /// A tap opens the details.
        case opensDetails
    }

    /// What the place shows: one line, the text drawn, how many lines it
    /// may take (nil: as many as it needs), its control, and whether it is
    /// held from the last run.
    struct Occupant: Equatable {
        let line: SearchNoticeLine
        let text: String
        let lineLimit: Int?
        let control: Control
        let isHeld: Bool
    }

    /// The occupant, by the room it has. Heights are whole points. Alone and
    /// within the limit: the whole text (a notice of more than one sentence
    /// folds in place on a tap). With another line, or over the limit: it
    /// opens the details, and shows its whole text if that is within the
    /// limit, else its first sentence on two lines if two are within the
    /// limit, else on one. One line always shows.
    static func occupant(
        lines: [SearchNoticeLine], isHeld: Bool, limit: Int, wholeHeight: Int, twoLineHeight: Int,
        personFolded: Bool
    ) -> Occupant? {
        guard let line = lines.first else { return nil }
        let whole = line.sentence
        let first = firstSentence(of: whole)
        if lines.count == 1 && wholeHeight <= limit {
            guard first != whole else {
                return Occupant(line: line, text: whole, lineLimit: nil, control: .none, isHeld: isHeld)
            }
            return Occupant(
                line: line, text: personFolded ? first : whole, lineLimit: nil,
                control: .foldsInPlace(folded: personFolded), isHeld: isHeld)
        }
        if wholeHeight <= limit {
            return Occupant(line: line, text: whole, lineLimit: nil, control: .opensDetails, isHeld: isHeld)
        }
        return Occupant(
            line: line, text: first, lineLimit: twoLineHeight <= limit ? 2 : 1, control: .opensDetails,
            isHeld: isHeld)
    }

    /// The text up to and including the first full stop that ends the text
    /// or is followed by a space and a capital letter.
    static func firstSentence(of text: String) -> String {
        let chars = Array(text)
        var index = 0
        while index < chars.count {
            if chars[index] == "." {
                if index == chars.count - 1 { return text }
                if index + 2 < chars.count, chars[index + 1] == " ", chars[index + 2].isUppercase {
                    return String(chars[...index])
                }
            }
            index += 1
        }
        return text
    }

    /// The details: every line that holds, whole, in rank order; the lines
    /// of pages not searched in one list (with its header), the others in
    /// a second. Each row's pages are its line's pages; no word is added.
    static func detailsContent(_ lines: [SearchNoticeLine])
        -> (notSearched: NotSearchedListContent, others: NotSearchedListContent) {
        func content(_ part: [SearchNoticeLine]) -> NotSearchedListContent {
            NotSearchedListContent(
                sections: part.isEmpty ? [] : [NotSearchedListContent.Section(
                    nameLine: nil,
                    rows: part.map { NotSearchedListContent.Row(sentence: $0.sentence, pages: $0.pages) })],
                smallPicturesLine: nil)
        }
        return (content(lines.filter { $0.kind == .notSearched }),
                content(lines.filter { $0.kind != .notSearched }))
    }

    /// What the parked strip's mark speaks: the occupant's whole sentence,
    /// or nil when no line holds.
    static func stripMarkLabel(_ lines: [SearchNoticeLine]) -> String? {
        lines.first?.sentence
    }

    /// The opacity of a held notice's words and arrow; its surface and its
    /// mark stay at full strength.
    static let heldWordsOpacity = 0.7
}
