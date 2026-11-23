import Foundation

/// What one search run read of a document, page by page: the facts each
/// page's reports gave, how the run ended, each page's state, and the
/// summary every statement about the run reads. Pure: no PDFKit, no
/// recognition; the searcher's reports and the app's two signals arrive as
/// `Facts` through `record(_:forPage:)`.
///
/// The rules. Every page starts with no facts ("not read: no report"). A
/// report can only add facts, never remove one, so within a run a page's
/// state is the worst that any term's visit reported. A page's state is the
/// first row of `state(of:position:)` that applies.
struct AccountOfWhatWasRead: Sendable, Equatable {

    /// What the reports said of one page. Each is a fact a report adds.
    struct Facts: OptionSet, Sendable, Hashable {
        let rawValue: UInt16
        init(rawValue: UInt16) { self.rawValue = rawValue }

        /// The page's own text was searched.
        static let ownText = Facts(rawValue: 1 << 0)
        /// That text is hidden text over a page-size picture: another
        /// app's recognition.
        static let anotherAppsLayer = Facts(rawValue: 1 << 1)
        /// Recognition read the page's picture and returned at least one line.
        static let recognised = Facts(rawValue: 1 << 2)
        /// Recognition returned no line, and the page has ink.
        static let emptyReadWithInk = Facts(rawValue: 1 << 3)
        /// Recognition returned no line, and the page has no ink.
        static let emptyReadBlank = Facts(rawValue: 1 << 4)
        /// The page has text, and the picture rule requires its pictures read.
        static let picturesRequired = Facts(rawValue: 1 << 5)
        /// The page has text and pictures below the picture rule's floors.
        static let smallPictures = Facts(rawValue: 1 << 6)
        /// Recognition was off for this page.
        static let recognitionOff = Facts(rawValue: 1 << 7)
        /// Recognition failed, or the page would not render.
        static let recognitionFailed = Facts(rawValue: 1 << 8)
        /// The page is too large for recognition.
        static let tooLarge = Facts(rawValue: 1 << 9)
        /// The page could not be opened.
        static let unopenable = Facts(rawValue: 1 << 10)
        /// A pattern ran out of time on this page.
        static let patternTimedOut = Facts(rawValue: 1 << 11)
        /// The page's text is searched where its painting cannot be followed:
        /// not known to be another app's text.
        static let paintingNotFollowed = Facts(rawValue: 1 << 12)

        /// The thirteen facts, in the order above.
        static let all: [Facts] = [
            .ownText, .anotherAppsLayer, .recognised, .emptyReadWithInk, .emptyReadBlank, .picturesRequired,
            .smallPictures, .recognitionOff, .recognitionFailed, .tooLarge, .unopenable, .patternTimedOut,
            .paintingNotFollowed,
        ]

        /// Any one of these on a page with its own text leaves it partly read.
        static let recognitionFailures: Facts = [.recognitionFailed, .tooLarge, .recognitionOff, .emptyReadWithInk]

        /// The facts one searcher report gives. `recognitionOff` and
        /// `patternTimedOut` are not reported by the searcher; the app adds them.
        init(_ coverage: PageSearchCoverage) {
            var facts: Facts = []
            switch coverage.route {
            case .textLayer:
                facts.insert(.ownText)
                if coverage.throughAnotherAppsLayer { facts.insert(.anotherAppsLayer) }
                if coverage.paintingNotFollowed { facts.insert(.paintingNotFollowed) }
                switch coverage.pictures {
                case .required: facts.insert(.picturesRequired)
                case .belowFloors: facts.insert(.smallPictures)
                case nil: break
                }
            case .ocr:
                switch coverage.emptyRead {
                case nil: facts.insert(.recognised)
                case .ink: facts.insert(.emptyReadWithInk)
                case .blank: facts.insert(.emptyReadBlank)
                }
            case .ocrSkippedOversize: facts.insert(.tooLarge)
            case .ocrUnavailable: facts.insert(.recognitionFailed)
            case .unopenable: facts.insert(.unopenable)
            }
            self = facts
        }
    }

    /// How the run ended. Pages are zero-based indices.
    enum Ending: Sendable, Equatable {
        case completed
        /// The result limit was reached on this page.
        case stoppedAtResultLimit(page: Int)
        /// The user stopped the run, or left, on this page.
        case stopped(page: Int)
    }

    /// Where a page stands against the run's ending.
    enum Position: Sendable, Equatable, CaseIterable {
        /// The run completed, or stopped after this page.
        case beforeTheEnd
        case afterTheResultLimit
        case onTheResultLimitPage
        case afterTheStop
        case onTheStopPage
    }

    /// Why a page was read only in part.
    enum Reason: Sendable, Hashable, CaseIterable {
        /// The run ended on this page.
        case runEndedOnThisPage
        case patternTimedOut
        /// Pictures below the picture rule's floors were not read. The only
        /// reason that does not stop Redact.
        case smallPictures
        /// The picture rule requires the pictures read, and no report says
        /// they were.
        case picturesNotRead
        case recognitionFailed
        case tooLarge
        case recognitionOff
        case recognitionFoundNoText
    }

    enum State: Sendable, Hashable {
        case notReachedResultLimit
        case notReachedStopped
        case noReport
        case couldNotBeOpened
        case recognitionFailed
        case tooLarge
        case recognitionOff
        case recognitionFoundNoText
        case partlyRead(Set<Reason>)
        case readThroughAnotherAppsText
        case readWherePaintingIsNotFollowed
        case readFromOwnText
        case readByRecognition
        case readBlank

        enum Kind: Int, Comparable, Sendable {
            case read = 0, partlyRead = 1, notRead = 2
            static func < (lhs: Kind, rhs: Kind) -> Bool { lhs.rawValue < rhs.rawValue }
        }

        /// Read, partly read, or not read: a worse kind is a larger value.
        var kind: Kind {
            switch self {
            case .readThroughAnotherAppsText, .readWherePaintingIsNotFollowed, .readFromOwnText, .readByRecognition, .readBlank: .read
            case .partlyRead: .partlyRead
            default: .notRead
            }
        }
    }

    /// The table, first row that applies.
    static func state(of facts: Facts, position: Position) -> State {
        let ownText = facts.contains(.ownText)
        if facts.isEmpty {
            switch position {
            case .afterTheResultLimit: return .notReachedResultLimit          // 1
            case .afterTheStop: return .notReachedStopped                     // 2
            default: return .noReport                                         // 3
            }
        }
        if facts.contains(.unopenable) { return .couldNotBeOpened }           // 4
        if !ownText {
            if facts.contains(.recognitionFailed) { return .recognitionFailed } // 5
            if facts.contains(.tooLarge) { return .tooLarge }                 // 6
            if facts.contains(.recognitionOff) { return .recognitionOff }     // 7
            if facts.contains(.emptyReadWithInk) { return .recognitionFoundNoText } // 8
            if facts.isDisjoint(with: [.recognised, .emptyReadBlank]) { return .noReport } // 9
        }
        let reasons = partReasons(of: facts, position: position)
        if !reasons.isEmpty { return .partlyRead(reasons) }                   // 10
        if ownText {
            if facts.contains(.paintingNotFollowed) { return .readWherePaintingIsNotFollowed }
            return facts.contains(.anotherAppsLayer) ? .readThroughAnotherAppsText : .readFromOwnText // 11, 12
        }
        return facts.contains(.recognised) ? .readByRecognition : .readBlank // 13, 14
    }

    /// Row 10's reasons: every one that applies.
    private static func partReasons(of facts: Facts, position: Position) -> Set<Reason> {
        var reasons: Set<Reason> = []
        if position == .onTheResultLimitPage || position == .onTheStopPage { reasons.insert(.runEndedOnThisPage) }
        if facts.contains(.patternTimedOut) { reasons.insert(.patternTimedOut) }
        if facts.contains(.smallPictures) { reasons.insert(.smallPictures) }
        if facts.contains(.ownText) {
            if facts.contains(.recognitionFailed) { reasons.insert(.recognitionFailed) }
            if facts.contains(.tooLarge) { reasons.insert(.tooLarge) }
            if facts.contains(.recognitionOff) { reasons.insert(.recognitionOff) }
            if facts.contains(.emptyReadWithInk) { reasons.insert(.recognitionFoundNoText) }
            if facts.contains(.picturesRequired), facts.isDisjoint(with: [.recognised, .emptyReadBlank]) {
                reasons.insert(.picturesNotRead)
            }
        }
        return reasons
    }

    // MARK: - The account

    let pageCount: Int
    private(set) var facts: [Facts]
    private(set) var ending: Ending = .completed

    /// Every page starts with no facts: "not read: no report".
    init(pageCount: Int) {
        self.pageCount = max(0, pageCount)
        facts = Array(repeating: [], count: self.pageCount)
    }

    /// Adds a report's facts to one page. A page outside the document is ignored.
    mutating func record(_ reported: Facts, forPage page: Int) {
        guard facts.indices.contains(page) else { return }
        facts[page].formUnion(reported)
    }

    mutating func record(_ coverage: PageSearchCoverage) {
        record(Facts(coverage), forPage: coverage.pageIndex)
    }

    mutating func end(_ ending: Ending) { self.ending = ending }

    func position(of page: Int) -> Position {
        switch ending {
        case .completed: return .beforeTheEnd
        case .stoppedAtResultLimit(let last):
            return page == last ? .onTheResultLimitPage : page > last ? .afterTheResultLimit : .beforeTheEnd
        case .stopped(let last):
            return page == last ? .onTheStopPage : page > last ? .afterTheStop : .beforeTheEnd
        }
    }

    func state(ofPage page: Int) -> State {
        Self.state(of: facts[page], position: position(of: page))
    }

    var states: [State] { (0..<pageCount).map(state(ofPage:)) }

    var summary: Summary { Summary(states: states) }

    // MARK: - The summary

    /// What the statements about a run may read, and nothing else.
    struct Summary: Sendable, Equatable {
        let states: [State]

        /// The pages in each state, ascending. Partly read pages are under
        /// their own reasons (`pages(withReason:)`) as well.
        func pages(in state: State) -> [Int] {
            states.indices.filter { states[$0] == state }
        }

        func pages(withReason reason: Reason) -> [Int] {
            states.indices.filter {
                if case .partlyRead(let reasons) = states[$0] { return reasons.contains(reason) }
                return false
            }
        }

        var everyPageRead: Bool { states.allSatisfy { $0.kind == .read } }

        /// True only when every page was read from its own text or is blank.
        var plainNoMatchAllowed: Bool {
            states.allSatisfy { $0 == .readFromOwnText || $0 == .readBlank }
        }

        /// The pages a qualified no-match counts: read by recognition, or
        /// through another app's text.
        var qualifiedPages: [Int] {
            states.indices.filter { states[$0] == .readByRecognition || states[$0] == .readThroughAnotherAppsText }
        }

        /// Partly read pages whose only reason is small pictures.
        var quietPages: [Int] {
            states.indices.filter { states[$0] == .partlyRead([.smallPictures]) }
        }

        /// Every page not read, and every page partly read for a reason
        /// other than small pictures.
        var pagesThatStopRedact: [Int] {
            states.indices.filter {
                switch states[$0].kind {
                case .read: false
                case .notRead: true
                case .partlyRead: states[$0] != .partlyRead([.smallPictures])
                }
            }
        }
    }
}
