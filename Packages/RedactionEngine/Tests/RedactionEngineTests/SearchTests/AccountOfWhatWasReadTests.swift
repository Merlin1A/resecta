import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import RedactionEngine

// The account of what a search run read: its facts, its table, its summary,
// and the ink test for a page whose accurate recognition returned no line.
// Pure: no searcher runs here; the searcher's reports are given as
// `PageSearchCoverage` values or as facts. Page numbers in the row names are
// one-based, as a person reads them; the code's indices are zero-based.
@Suite("Account of what was read")
struct AccountOfWhatWasReadTests {

    typealias Account = AccountOfWhatWasRead
    typealias Facts = AccountOfWhatWasRead.Facts
    typealias State = AccountOfWhatWasRead.State

    enum Row: String, CaseIterable, CustomTestStringConvertible {
        case c01 = "C-01 a typed document that completes is read from its own text, and the plain no-match is allowed"
        case c02 = "C-02 a scanned page with recognition off is not read"
        case c07 = "C-07 a typed page with a full-page picture and recognition off is partly read for two reasons"
        case c08 = "C-08 a typed page with a small picture is partly read and does not stop Redact"
        case c09 = "C-09 a pattern that ran out of time leaves the page partly read"
        case c10 = "C-10 the pages after the result limit's page are not reached"
        case c10b = "C-10b the result limit's own page is partly read"
        case c11 = "C-11 a run stopped on page 6 leaves it partly read and the rest not reached"
        case c13 = "C-13 a page read by recognition is counted in the qualified no-match"
        case c14 = "C-14 another app's hidden text with recognition on is read through it, and qualified"
        case c14b = "C-14b another app's hidden text with recognition off is partly read"
        case unfollowed = "A page whose painting cannot be followed is read with that reason, not as another app's text"
        case c15 = "C-15 an empty read on a blank picture is read, and the plain no-match stays allowed"
        case c16 = "C-16 adding a page not read or partly read never gives fewer warnings"
        case c17 = "C-17 a failure after a success leaves the page not read"
        case c17b = "C-17b a success after a failure leaves the page not read"
        case c18 = "C-18 a page with no report is not read, and named"
        case c19 = "C-19 an empty read on a picture with one line of print is not read"
        case c20 = "C-20 a cached empty read reports what the fresh read did"
        case c21 = "C-21 an empty read with no picture at hand is ink"
        case c22 = "C-22 a share exactly at the floor is ink, and one pixel under is blank"
        case c23 = "C-23 small pictures alone stop nothing"
        case c24 = "C-24 a timeout on a page read by recognition leaves it partly read"
        case c25 = "C-25 every set of facts at every place gives exactly one state, and a failure never a better one"
        case c26 = "C-26 a typed page whose pictures the rule requires, with no report of their reading, is partly read"
        case floorArithmetic = "The floor is the geometric mean of the two real ranges, rounded down to three figures"
        case floorUnset = "While no floor is set, every empty read is ink"
        case darkThreshold = "A pixel is dark below the ink fit's threshold"
        case edgeBand = "The band at each edge is left out of the count"

        var testDescription: String { rawValue }
    }

    @Test("The account's rows are all here")
    func rowCount() {
        #expect(Row.allCases.count == 29)
    }

    @Test("Account of what was read", arguments: Row.allCases)
    func row(_ row: Row) throws {
        switch row {
        case .c01: c01()
        case .c02: c02()
        case .c07: expectPage4(of: [.ownText, .picturesRequired, .recognitionOff],
                               is: .partlyRead([.picturesNotRead, .recognitionOff]), stopsRedact: true)
        case .c08: c08()
        case .c09: expectPage4(of: [.ownText, .patternTimedOut], is: .partlyRead([.patternTimedOut]), stopsRedact: true)
        case .c10: c10()
        case .c10b: c10b()
        case .c11: c11()
        case .c13: c13()
        case .c14: c14()
        case .c14b: expectPage4(of: [.ownText, .anotherAppsLayer, .picturesRequired, .recognitionOff],
                                is: .partlyRead([.picturesNotRead, .recognitionOff]), stopsRedact: true)
        case .unfollowed: unfollowed()
        case .c15: c15()
        case .c16: c16()
        case .c17: c17(failureFirst: false)
        case .c17b: c17(failureFirst: true)
        case .c18: c18()
        case .c19: try c19()
        case .c20: try c20()
        case .c21: c21()
        case .c22: try c22()
        case .c23: c23()
        case .c24: expectPage4(of: [.recognised, .patternTimedOut], is: .partlyRead([.patternTimedOut]), stopsRedact: true)
        case .c25: c25()
        case .c26: expectPage4(of: [.ownText, .picturesRequired], is: .partlyRead([.picturesNotRead]), stopsRedact: true)
        case .floorArithmetic: floorArithmetic()
        case .floorUnset: try floorUnset()
        case .darkThreshold: try darkThreshold()
        case .edgeBand: try edgeBand()
        }
    }

    // MARK: - Accounts

    /// A completed ten-page account: every page read from its own text,
    /// except page 4 (index 3), which has `page4`.
    static func typed(page4: Facts? = nil, pages: Int = 10) -> Account {
        var account = Account(pageCount: pages)
        for page in 0..<pages { account.record(page == 3 && page4 != nil ? page4! : .ownText, forPage: page) }
        return account
    }

    func expectPage4(of facts: Facts, is expected: State, stopsRedact: Bool) {
        let account = Self.typed(page4: facts)
        #expect(account.state(ofPage: 3) == expected)
        #expect(account.summary.pagesThatStopRedact == (stopsRedact ? [3] : []))
        #expect(!account.summary.plainNoMatchAllowed)
        #expect(!account.summary.everyPageRead)
    }

    func c01() {
        let account = Self.typed()
        #expect(account.states == Array(repeating: .readFromOwnText, count: 10))
        #expect(account.summary.plainNoMatchAllowed)
        #expect(account.summary.everyPageRead)
        #expect(account.summary.pagesThatStopRedact.isEmpty)
        #expect(account.summary.qualifiedPages.isEmpty)
    }

    func c02() {
        let account = Self.typed(page4: .recognitionOff)
        #expect(account.state(ofPage: 3) == .recognitionOff)
        #expect(account.summary.pages(in: .recognitionOff) == [3])
        #expect(account.summary.pagesThatStopRedact == [3])
    }

    func c08() {
        let account = Self.typed(page4: [.ownText, .smallPictures])
        #expect(account.state(ofPage: 3) == .partlyRead([.smallPictures]))
        #expect(account.summary.quietPages == [3])
        #expect(account.summary.pages(withReason: .smallPictures) == [3])
        #expect(account.summary.pagesThatStopRedact.isEmpty)
        #expect(!account.summary.plainNoMatchAllowed)
    }

    /// Pages 1 to 6 read, the run ended on page 6 (index 5) by `ending`.
    static func endedOnPage6(_ ending: Account.Ending) -> Account {
        var account = Account(pageCount: 10)
        for page in 0...5 { account.record(.ownText, forPage: page) }
        account.end(ending)
        return account
    }

    func c10() {
        let account = Self.endedOnPage6(.stoppedAtResultLimit(page: 5))
        #expect(account.summary.pages(in: .notReachedResultLimit) == [6, 7, 8, 9])
        #expect(account.states[0...4].allSatisfy { $0 == .readFromOwnText })
        #expect(account.summary.pagesThatStopRedact == [5, 6, 7, 8, 9])
    }

    func c10b() {
        let account = Self.endedOnPage6(.stoppedAtResultLimit(page: 5))
        #expect(account.state(ofPage: 5) == .partlyRead([.runEndedOnThisPage]))
        #expect(account.summary.pages(withReason: .runEndedOnThisPage) == [5])
    }

    func c11() {
        let account = Self.endedOnPage6(.stopped(page: 5))
        #expect(account.state(ofPage: 5) == .partlyRead([.runEndedOnThisPage]))
        #expect(account.summary.pages(in: .notReachedStopped) == [6, 7, 8, 9])
        #expect(account.summary.pages(in: .notReachedResultLimit).isEmpty)
        #expect(account.summary.pagesThatStopRedact == [5, 6, 7, 8, 9])
    }

    func c13() {
        let account = Self.typed(page4: .recognised)
        #expect(account.state(ofPage: 3) == .readByRecognition)
        #expect(account.summary.qualifiedPages == [3])
        #expect(account.summary.everyPageRead)
        #expect(!account.summary.plainNoMatchAllowed)
        #expect(account.summary.pagesThatStopRedact.isEmpty)
    }

    func c14() {
        var account = Account(pageCount: 10)
        for page in 0..<10 where page != 3 { account.record(PageSearchCoverage(pageIndex: page, route: .textLayer)) }
        account.record(PageSearchCoverage(pageIndex: 3, route: .textLayer, pictures: .required, throughAnotherAppsLayer: true))
        account.record(PageSearchCoverage(pageIndex: 3, route: .ocr))
        #expect(account.facts[3] == [.ownText, .anotherAppsLayer, .picturesRequired, .recognised])
        #expect(account.state(ofPage: 3) == .readThroughAnotherAppsText)
        #expect(account.summary.qualifiedPages == [3])
        #expect(!account.summary.plainNoMatchAllowed)
        #expect(account.summary.everyPageRead)
    }

    func unfollowed() {
        var account = Account(pageCount: 10)
        for page in 0..<10 where page != 3 { account.record(PageSearchCoverage(pageIndex: page, route: .textLayer)) }
        account.record(PageSearchCoverage(pageIndex: 3, route: .textLayer, pictures: .required, paintingNotFollowed: true))
        account.record(PageSearchCoverage(pageIndex: 3, route: .ocr))
        #expect(account.facts[3] == [.ownText, .paintingNotFollowed, .picturesRequired, .recognised])
        #expect(account.state(ofPage: 3) == .readWherePaintingIsNotFollowed)
        #expect(account.summary.qualifiedPages.isEmpty, "not read by recognition, and not another app's text")
        #expect(!account.summary.plainNoMatchAllowed)
        #expect(account.summary.everyPageRead)
    }

    func c15() {
        var account = Account(pageCount: 10)
        for page in 0..<10 where page != 3 { account.record(PageSearchCoverage(pageIndex: page, route: .textLayer)) }
        account.record(PageSearchCoverage(pageIndex: 3, route: .ocr, emptyRead: .blank))
        #expect(account.state(ofPage: 3) == .readBlank)
        #expect(account.summary.plainNoMatchAllowed)
        #expect(account.summary.pagesThatStopRedact.isEmpty)
    }

    func c17(failureFirst: Bool) {
        let reports = [PageSearchCoverage(pageIndex: 3, route: .ocr), PageSearchCoverage(pageIndex: 3, route: .ocrUnavailable)]
        var account = Self.typed(page4: [])
        for report in failureFirst ? reports.reversed() : reports { account.record(report) }
        #expect(account.state(ofPage: 3) == .recognitionFailed)
        #expect(account.summary.pagesThatStopRedact == [3])
    }

    func c18() {
        var account = Account(pageCount: 10)
        for page in 0..<10 where page != 4 { account.record(.ownText, forPage: page) }
        account.record(.ownText, forPage: 3)
        account.record(.ownText, forPage: 99)
        #expect(account.state(ofPage: 4) == .noReport)
        #expect(account.summary.pages(in: .noReport) == [4])
        #expect(account.summary.pagesThatStopRedact == [4])
        #expect(!account.summary.everyPageRead)
    }

    func c23() {
        #expect(Self.typed().summary.pagesThatStopRedact.isEmpty)
        var account = Self.typed(page4: [.ownText, .smallPictures])
        account.record([.ownText, .smallPictures], forPage: 7)
        #expect(account.summary.pagesThatStopRedact.isEmpty)
        #expect(account.summary.quietPages == [3, 7])
    }

    // MARK: - C-16: more unread never reads as less

    static let readStates: [State] = [.readFromOwnText, .readBlank, .readByRecognition, .readThroughAnotherAppsText,
                                      .readWherePaintingIsNotFollowed]
    static let unreadStates: [State] = [
        .notReachedResultLimit, .notReachedStopped, .noReport, .couldNotBeOpened,
        .recognitionFailed, .tooLarge, .recognitionOff, .recognitionFoundNoText,
    ] + Account.Reason.allCases.map { State.partlyRead([$0]) }

    /// What a summary warns of, as page masks, so that "at least the
    /// first's warnings" is a subset test on bits.
    struct Warnings {
        var stop: UInt8 = 0, named: UInt8 = 0, qualified: UInt8 = 0
        var plain = false, every = false
        var perState: [UInt8] = []
        var perReason: [UInt8] = []

        init(_ summary: Account.Summary) {
            func mask(_ pages: [Int]) -> UInt8 { pages.reduce(0) { $0 | UInt8(1 << $1) } }
            stop = mask(summary.pagesThatStopRedact)
            named = stop | mask(summary.quietPages)
            qualified = mask(summary.qualifiedPages)
            plain = summary.plainNoMatchAllowed
            every = summary.everyPageRead
            perState = AccountOfWhatWasReadTests.unreadStates.prefix(8).map { mask(summary.pages(in: $0)) }
            perReason = Account.Reason.allCases.map { mask(summary.pages(withReason: $0)) }
        }

        /// True when `self` warns of everything `first` did.
        func covers(_ first: Warnings) -> Bool {
            func within(_ a: UInt8, _ b: UInt8) -> Bool { a & ~b == 0 }
            return within(first.stop, stop) && within(first.named, named)
                && within(first.qualified, qualified | named)
                && (!plain || first.plain) && (!every || first.every)
                && zip(first.perState, perState).allSatisfy(within)
                && zip(first.perReason, perReason).allSatisfy(within)
        }
    }

    /// Documents of one to four pages, each page in any of the twenty states
    /// (the five read states, the eight not read, and partly read for each
    /// reason). The second account turns one read page of the first into any
    /// unread state; a larger addition is a chain of these, and "warns of
    /// everything the first did" carries along a chain.
    func c16() {
        let alphabet = Self.readStates + Self.unreadStates
        var pairs = 0, failures = 0
        for pages in 1...4 {
            var count = 1
            for _ in 0..<pages { count *= alphabet.count }
            let warnings: [Warnings] = (0..<count).map { code in
                Warnings(Account.Summary(states: Self.states(code, pages: pages, alphabet: alphabet)))
            }
            for code in 0..<count {
                var digits = Self.digits(code, pages: pages, base: alphabet.count)
                for page in 0..<pages where digits[page] < Self.readStates.count {
                    let kept = digits[page]
                    for unread in Self.readStates.count..<alphabet.count {
                        digits[page] = unread
                        pairs += 1
                        if !warnings[Self.code(digits, base: alphabet.count)].covers(warnings[code]) { failures += 1 }
                    }
                    digits[page] = kept
                }
            }
        }
        #expect(pairs == 3_072_800)
        #expect(failures == 0)
    }

    static func digits(_ code: Int, pages: Int, base: Int) -> [Int] {
        var rest = code
        return (0..<pages).map { _ in defer { rest /= base }; return rest % base }
    }

    static func code(_ digits: [Int], base: Int) -> Int {
        digits.reversed().reduce(0) { $0 * base + $1 }
    }

    static func states(_ code: Int, pages: Int, alphabet: [State]) -> [State] {
        digits(code, pages: pages, base: alphabet.count).map { alphabet[$0] }
    }

    // MARK: - C-25: the table is total and a failure never reads better

    /// The table as the paper writes it, read row by row: the first row
    /// whose condition holds.
    static func paperState(_ facts: Facts, _ place: Account.Position) -> State? {
        let t = facts.contains(.ownText), a = facts.contains(.anotherAppsLayer), r = facts.contains(.recognised)
        let n = facts.contains(.emptyReadWithInk), b = facts.contains(.emptyReadBlank)
        let p = facts.contains(.picturesRequired), s = facts.contains(.smallPictures)
        let o = facts.contains(.recognitionOff), f = facts.contains(.recognitionFailed)
        let l = facts.contains(.tooLarge), u = facts.contains(.unopenable), x = facts.contains(.patternTimedOut)
        let w = facts.contains(.paintingNotFollowed)
        let fail = f || l || o || n
        let endedHere = place == .onTheResultLimitPage || place == .onTheStopPage
        if facts.isEmpty, place == .afterTheResultLimit { return .notReachedResultLimit }
        if facts.isEmpty, place == .afterTheStop { return .notReachedStopped }
        if facts.isEmpty { return .noReport }
        if u { return .couldNotBeOpened }
        if !t, f { return .recognitionFailed }
        if !t, l { return .tooLarge }
        if !t, o { return .recognitionOff }
        if !t, n { return .recognitionFoundNoText }
        if !t, !r, !b { return .noReport }
        if endedHere || x || s || (t && fail) || (t && p && !r && !b) {
            var reasons: Set<Account.Reason> = []
            if endedHere { reasons.insert(.runEndedOnThisPage) }
            if x { reasons.insert(.patternTimedOut) }
            if s { reasons.insert(.smallPictures) }
            if t, f { reasons.insert(.recognitionFailed) }
            if t, l { reasons.insert(.tooLarge) }
            if t, o { reasons.insert(.recognitionOff) }
            if t, n { reasons.insert(.recognitionFoundNoText) }
            if t, p, !r, !b { reasons.insert(.picturesNotRead) }
            return .partlyRead(reasons)
        }
        if t, w { return .readWherePaintingIsNotFollowed }
        if t, a { return .readThroughAnotherAppsText }
        if t { return .readFromOwnText }
        if r { return .readByRecognition }
        if b { return .readBlank }
        return nil
    }

    func c25() {
        let worsening: [Facts] = [.unopenable, .recognitionFailed, .tooLarge, .recognitionOff, .emptyReadWithInk, .patternTimedOut]
        var inputs = 0, mismatches = 0, untotal = 0, better = 0
        for raw in 0..<(UInt16(1) << 13) {
            let facts = Facts(rawValue: raw)
            for place in Account.Position.allCases {
                inputs += 1
                let state = Account.state(of: facts, position: place)
                guard let paper = Self.paperState(facts, place) else { untotal += 1; continue }
                if state != paper { mismatches += 1 }
                for fact in worsening where Account.state(of: facts.union(fact), position: place).kind < state.kind {
                    better += 1
                }
            }
        }
        #expect(inputs == 40_960)
        #expect(untotal == 0)
        #expect(mismatches == 0)
        #expect(better == 0)
    }

    // MARK: - The ink test

    /// A test value: the first of the paper's two worked floors (0.0611 %)
    /// at the 0.15-inch band. Not the measurement.
    static let testSetting = PageInk.Setting(floor: .init(significand: 611, exponent: 6), edgeBandInches: 0.15)

    /// Search's picture scale: 300 pixels per inch.
    static let searchPixelsPerInch = 300.0

    /// A US Letter page at Search's scale, white, drawn on by `draw`.
    static func letterPage(_ draw: (CGContext) -> Void = { _ in }) throws -> CGImage {
        let width = Int(8.5 * searchPixelsPerInch), height = Int(11 * searchPixelsPerInch)
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                             space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        draw(context)
        return try #require(context.makeImage())
    }

    /// One header line of 10-point print, 0.6 inch below the top edge.
    static func oneLinePage() throws -> CGImage {
        try letterPage { context in
            let font = CTFontCreateWithName("Helvetica" as CFString, 10 * searchPixelsPerInch / 72, nil)
            let text = NSAttributedString(string: "Statement of account 4417 for the period ending 31 October",
                                          attributes: [.init(kCTFontAttributeName as String): font,
                                                       .init(kCTForegroundColorFromContextAttributeName as String): true])
            context.setFillColor(gray: 0, alpha: 1)
            context.textPosition = CGPoint(x: searchPixelsPerInch, y: Double(context.height) - 0.6 * searchPixelsPerInch)
            CTLineDraw(CTLineCreateWithAttributedString(text), context)
        }
    }

    /// A blank back: white, twenty specks of dust, and a scanner's edge
    /// shadow 10 pixels wide down the left edge, inside the band.
    static func blankBack() throws -> CGImage {
        try letterPage { context in
            context.setFillColor(gray: 0, alpha: 1)
            for speck in 0..<20 { context.fill(CGRect(x: 200 + speck * 97, y: 400 + speck * 131, width: 1, height: 1)) }
            context.fill(CGRect(x: 0, y: 0, width: 10, height: context.height))
        }
    }

    /// A gray picture whose pixels are `values`, row by row, `width` wide.
    static func grayImage(_ values: [UInt8], width: Int) throws -> CGImage {
        let height = values.count / width
        let provider = try #require(CGDataProvider(data: Data(values) as CFData))
        return try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                                    provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    func c19() throws {
        let share = try #require(PageInk.emptyReadShare(of: try Self.oneLinePage(), pixelsPerInch: Self.searchPixelsPerInch,
                                                        setting: Self.testSetting))
        #expect(share.dark > 0)
        #expect(PageInk.emptyRead(share, setting: Self.testSetting) == .ink)
        var account = Self.typed(page4: [])
        account.record(PageSearchCoverage(pageIndex: 3, route: .ocr, emptyRead: .ink))
        #expect(account.state(ofPage: 3) == .recognitionFoundNoText)
        #expect(account.summary.pagesThatStopRedact == [3])
    }

    func c20() throws {
        var cache = OCRPageCache()
        cache.insert([], for: 3, picture: (try Self.oneLinePage(), Self.searchPixelsPerInch), inkSetting: Self.testSetting)
        cache.insert([], for: 4, picture: (try Self.blankBack(), Self.searchPixelsPerInch), inkSetting: Self.testSetting)
        #expect(cache.touch(3)?.isEmpty == true)
        #expect(cache.emptyRead(for: 3, inkSetting: Self.testSetting) == .ink)
        #expect(cache.emptyRead(for: 4, inkSetting: Self.testSetting) == .blank)
        #expect(cache.emptyRead(for: 5, inkSetting: Self.testSetting) == nil)
        var account = Self.typed(page4: [])
        account.record(PageSearchCoverage(pageIndex: 3, route: .ocr, emptyRead: cache.emptyRead(for: 3, inkSetting: Self.testSetting)))
        #expect(account.state(ofPage: 3) == .recognitionFoundNoText)
    }

    func c21() {
        #expect(PageInk.emptyReadShare(of: nil, pixelsPerInch: Self.searchPixelsPerInch, setting: Self.testSetting) == nil)
        #expect(PageInk.emptyRead(nil, setting: Self.testSetting) == .ink)
        var cache = OCRPageCache()
        cache.insert([], for: 3, inkSetting: Self.testSetting)
        #expect(cache.emptyRead(for: 3, inkSetting: Self.testSetting) == .ink)
    }

    func c22() throws {
        let floor = PageInk.FloorShare(significand: 611, exponent: 6)
        for (dark, ink) in [(611, true), (610, false)] {
            var pixels = [UInt8](repeating: 255, count: 1_000_000)
            for index in 0..<dark { pixels[index * 1_009 % pixels.count] = 0 }
            let share = try #require(PageInk.darkShare(of: try Self.grayImage(pixels, width: 1_000), edgeBand: 0))
            #expect(share == PageInk.DarkShare(dark: dark, total: 1_000_000))
            #expect(PageInk.hasInk(share, floor: floor) == ink)
        }
    }

    func floorArithmetic() {
        #expect(PageInk.floor(darkestBlank: .init(dark: 20, total: 100_000), lightestLine: .init(dark: 187, total: 100_000))
                == PageInk.FloorShare(significand: 611, exponent: 6))
        #expect(PageInk.floor(darkestBlank: .init(dark: 90, total: 100_000), lightestLine: .init(dark: 187, total: 100_000))
                == PageInk.FloorShare(significand: 129, exponent: 5))
        // More than half the line's share: the ranges do not stand apart.
        #expect(PageInk.floor(darkestBlank: .init(dark: 94, total: 100_000), lightestLine: .init(dark: 187, total: 100_000)) == nil)
        #expect(PageInk.floor(darkestBlank: .init(dark: 0, total: 100_000), lightestLine: .init(dark: 187, total: 100_000)) == nil)
    }

    func floorUnset() throws {
        let blank = try Self.blankBack()
        #expect(PageInk.emptyReadShare(of: blank, pixelsPerInch: Self.searchPixelsPerInch, setting: nil) == nil)
        #expect(PageInk.emptyRead(nil, setting: nil) == .ink)
        let measured = PageInk.darkShare(of: blank, edgeBand: 0)
        #expect(PageInk.emptyRead(measured, setting: nil) == .ink)
        var cache = OCRPageCache()
        cache.insert([], for: 0, picture: (blank, Self.searchPixelsPerInch), inkSetting: nil)
        #expect(cache.emptyRead(for: 0, inkSetting: nil) == .ink)
    }

    func darkThreshold() throws {
        let share = try #require(PageInk.darkShare(of: try Self.grayImage([0, 127, 128, 255], width: 4), edgeBand: 0))
        #expect(share == PageInk.DarkShare(dark: 2, total: 4))
    }

    func edgeBand() throws {
        var pixels = [UInt8](repeating: 255, count: 100 * 100)
        for row in 0..<100 { for column in 0..<10 { pixels[row * 100 + column] = 0 } }
        let image = try Self.grayImage(pixels, width: 100)
        #expect(PageInk.darkShare(of: image, edgeBand: 0) == PageInk.DarkShare(dark: 1_000, total: 10_000))
        #expect(PageInk.darkShare(of: image, edgeBand: 10) == PageInk.DarkShare(dark: 0, total: 6_400))
        #expect(PageInk.darkShare(of: image, edgeBand: 50) == nil)
        #expect(PageInk.edgeBandPixels(inches: 0.15, pixelsPerInch: 300) == 45)
        #expect(PageInk.edgeBandPixels(inches: 0.15, pixelsPerInch: 72) == 10)
    }
}
