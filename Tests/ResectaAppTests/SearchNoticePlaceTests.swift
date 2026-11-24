import Testing
import Foundation
@testable import ResectaApp
import RedactionEngine

// The notice place above the results: its rules as tables, and source
// readings of where it is mounted. Expected values are written out, never
// derived from the code under test.

@MainActor
@Suite("Search notice place")
struct SearchNoticePlaceTests {

    typealias Place = SearchNoticePlace
    typealias Line = SearchNoticeLine

    static let tooLarge7 = "Page 7 was too large to scan for text \u{2014} image content there was not searched."
    static let timedOut3and5 = "The active regex pattern timed out on pages 3 and 5. Results may be incomplete."
    static let limit40of120 = "Showing first 1,000 results. Search stopped at page 40 of 120, which it searched in part. "
        + "The 80 pages after it were not searched. Refine your search for more specific matches."
    static let degradedCorpus = "Detection is degraded for this session because the detection corpus failed to load. "
        + "Manual redaction tools remain available."

    static func line(_ kind: Line.Kind, _ sentence: String, _ pages: [Int], _ identifier: String) -> Line {
        Line(kind: kind, sentence: sentence, pages: pages, identifier: identifier)
    }
    static let notSearched = line(.notSearched, tooLarge7, [6], "ocrSkipBanner")
    static let timedOut = line(.notSearched, timedOut3and5, [2, 4], "regexTimeoutNotice")
    static let degraded = line(.degraded, degradedCorpus, [], "degradedDetectionBanner")
    static let fit = line(.fit, "Some boxes on page 1 were drawn wider than their words, because the text could not be "
        + "fitted to the printed words. Keep them wide: shrinking one can leave part of a word readable.", [0],
        "widenedBoxBanner")

    static func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: "\(#filePath)")
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    // MARK: - The lines

    @Test("The run's lines are the shipped sentences, in a fixed order")
    func runLines() {
        typealias F = Place.Facts
        let rows: [(F, [String], [String], [[Int]])] = [
            (F(), [], [], []),
            (F(tooLargePages: [6]), ["ocrSkipBanner"], [Self.tooLarge7], [[6]]),
            (F(timedOutPages: [4, 2]), ["regexTimeoutNotice"], [Self.timedOut3and5], [[2, 4]]),
            (F(atResultLimit: true, limitStopPage: 40, unscannedPageCount: 80), ["resultLimitNotice"],
             [Self.limit40of120], [[39]]),
            (F(widenedPages: [0]), ["widenedBoxBanner"], [Self.fit.sentence], [[0]]),
            (F(tooLargePages: [6], timedOutPages: [2, 4], atResultLimit: true, limitStopPage: 40,
               unscannedPageCount: 80, widenedPages: [0]),
             ["ocrSkipBanner", "regexTimeoutNotice", "resultLimitNotice", "widenedBoxBanner"],
             [Self.tooLarge7, Self.timedOut3and5, Self.limit40of120, Self.fit.sentence], [[6], [2, 4], [39], [0]]),
            (F(atResultLimit: true, limitStopPage: 40, unscannedPageCount: 80, interface: .scan),
             ["resultLimitNotice"],
             ["Showing first 1,000 results. Search stopped at page 40 of 120, which it searched in part. "
              + "The 80 pages after it were not searched."], [[39]]),
            (F(tooLargePages: [8, 6]), ["ocrSkipBanner"],
             ["Pages 7 and 9 were too large to scan for text \u{2014} image content there was not searched."],
             [[6, 8]]),
        ]
        #expect(rows.count == 8)
        for (facts, identifiers, sentences, pages) in rows {
            let lines = Place.runLines(facts)
            #expect(lines.map(\.identifier) == identifiers)
            #expect(lines.map(\.sentence) == sentences)
            #expect(lines.map(\.pages) == pages)
        }
        // The lines read no filtered count: `Facts` has no field for it, so
        // the limit's line holds when a filter hides every result.
        #expect(Place.degradedLine(shows: true, failures: [])?.sentence == Self.degradedCorpus)
        #expect(Place.degradedLine(shows: true, failures: [])?.identifier == "degradedDetectionBanner")
        #expect(Place.degradedLine(shows: false, failures: []) == nil)
    }

    @Test("The result limit's line names the stop page and the pages after it, in its approved words")
    func resultLimitWords() {
        let rows: [(Int, Int, SearchInterface, String)] = [
            (40, 80, .search, Self.limit40of120),
            (40, 1, .search, "Showing first 1,000 results. Search stopped at page 40 of 41, which it searched in part. "
                + "The page after it was not searched. Refine your search for more specific matches."),
            (41, 0, .search, "Showing first 1,000 results. Search stopped at page 41 of 41, which it searched in part. "
                + "Refine your search for more specific matches."),
            (40, 80, .scan, "Showing first 1,000 results. Search stopped at page 40 of 120, which it searched in part. "
                + "The 80 pages after it were not searched."),
            (0, 0, .search, "Showing first 1,000 results. Refine your search for more specific matches."),
        ]
        #expect(rows.count == 5)
        for (stop, after, interface, expected) in rows {
            #expect(Place.resultLimitSentence(stopPage: stop, unscannedPageCount: after, interface: interface) == expected)
        }
    }

    // The limit of this line, named: the stop page is said to be searched in
    // part whenever the result limit is met. That is untrue only when the stop
    // page held exactly the matches left under the limit (it was then read
    // whole); the line never says more of the document was read than was.
    @Test("At the result limit the stop page is said to be searched in part, even when the limit falls at its end")
    func stopPageSaidInPart() {
        let state = SearchState()
        state.totalPages = 3
        state.currentSearchPage = 2
        state.noteCapReached()
        let facts = state.noticeFacts
        #expect(facts.atResultLimit)
        #expect(facts.limitStopPage == 2)
        #expect(facts.unscannedPageCount == 1)
        #expect(Place.runLines(facts).map(\.sentence) == [
            "Showing first 1,000 results. Search stopped at page 2 of 3, which it searched in part. "
                + "The page after it was not searched. Refine your search for more specific matches."])
        state.clearResults()
        #expect(state.noticeFacts.limitStopPage == 0)
        #expect(!state.noticeFacts.atResultLimit)
    }

    // MARK: - Rank and room

    @Test("One notice shows, by rank: pages not searched, then degraded detection, then the larger boxes")
    func rank() {
        let n = Self.notSearched, d = Self.degraded, f = Self.fit
        let rows: [([Line], Line?, String?, Bool)] = [
            ([], nil, nil, false),
            ([n], nil, "ocrSkipBanner", false),
            ([], d, "degradedDetectionBanner", false),
            ([f], nil, "widenedBoxBanner", false),
            ([n], d, "ocrSkipBanner", true),
            ([n, f], nil, "ocrSkipBanner", true),
            ([f], d, "degradedDetectionBanner", true),
            ([f, n], d, "ocrSkipBanner", true),
        ]
        #expect(rows.count == 8)
        for (run, degraded, identifier, opens) in rows {
            let lines = Place.shownLines(run: run, held: [], isSearching: false, degraded: degraded)
            let occupant = Place.occupant(lines: lines, isHeld: false, limit: 1000, wholeHeight: 64,
                                          twoLineHeight: 64, personFolded: false)
            #expect(occupant?.line.identifier == identifier)
            #expect((occupant?.control == .opensDetails) == opens)
        }
    }

    @Test("At a session's first Scan nothing outranks the degraded-detection notice")
    func degradedFirstAtScan() {
        let state = SearchState()
        state.recordOCRSkip(page: 6)
        state.hasCompletedRunSinceClear = true
        // The interface change clears the run's facts, as the mode switch does.
        state.searchModeType = .piiScan
        state.clearResults()
        let degraded = Place.degradedLine(
            shows: SearchAndRedactSheet.degradeBannerShouldShow(interface: .scan, degraded: true), failures: [])
        for searching in [false, true] {
            let lines = Place.shownLines(run: Place.runLines(state.noticeFacts), held: state.notices.held,
                                         isSearching: searching, degraded: degraded)
            #expect(lines.map(\.identifier) == ["degradedDetectionBanner"])
        }
    }

    @Test("A notice shows whole, as its first sentence, or on one line, by the room it has")
    func room() {
        let l = Self.line(.notSearched, Self.limit40of120, [39], "resultLimitNotice")
        let rows: [([Line], Int, Int, Int, Bool, String, Int?, Place.Control)] = [
            ([Self.notSearched], 175, 64, 64, false, Self.tooLarge7, nil, .none),
            ([Self.timedOut], 175, 82, 64, false, Self.timedOut3and5, nil, .foldsInPlace(folded: false)),
            ([Self.timedOut], 175, 82, 64, true, "The active regex pattern timed out on pages 3 and 5.", nil,
             .foldsInPlace(folded: true)),
            ([l], 175, 120, 64, false, Self.limit40of120, nil, .foldsInPlace(folded: false)),
            ([l], 62, 120, 64, false, "Showing first 1,000 results.", 1, .opensDetails),
            ([Self.degraded], 204, 100, 64, false, Self.degradedCorpus, nil, .foldsInPlace(folded: false)),
            ([Self.degraded], 42, 100, 64, false, "Detection is degraded for this session because the detection "
                + "corpus failed to load.", 1, .opensDetails),
            ([l], 120, 120, 64, false, Self.limit40of120, nil, .foldsInPlace(folded: false)),
            ([l], 119, 120, 64, false, "Showing first 1,000 results.", 2, .opensDetails),
            ([l], 63, 120, 64, false, "Showing first 1,000 results.", 1, .opensDetails),
            ([l], 0, 120, 64, false, "Showing first 1,000 results.", 1, .opensDetails),
            ([Self.notSearched, Self.fit], 175, 64, 64, false, Self.tooLarge7, nil, .opensDetails),
        ]
        #expect(rows.count == 12)
        for (lines, limit, whole, two, folded, text, lineLimit, control) in rows {
            let occupant = Place.occupant(lines: lines, isHeld: false, limit: limit, wholeHeight: whole,
                                          twoLineHeight: two, personFolded: folded)
            #expect(occupant?.text == text)
            #expect(occupant?.lineLimit == lineLimit)
            #expect(occupant?.control == control)
        }
    }

    @Test("The first sentence of each shipped notice sentence")
    func firstSentences() {
        let ner = [GazetteerLoadDiagnostics.Gazetteer.nerNameModel.rawValue]
        let rows: [(String, String)] = [
            (SearchResultsSection.ocrSkipBannerHeadline(pages: [6]), Self.tooLarge7),
            (SearchResultsSection.ocrSkipBannerHeadline(pages: [6, 8]),
             "Pages 7 and 9 were too large to scan for text \u{2014} image content there was not searched."),
            (SearchResultsSection.regexTimeoutBannerHeadline(pages: [6]), "The active regex pattern timed out on page 7."),
            (SearchResultsSection.regexTimeoutBannerHeadline(pages: [2, 4]),
             "The active regex pattern timed out on pages 3 and 5."),
            (SearchResultsSection.widenedBoxBannerHeadline(pages: [0]), "Some boxes on page 1 were drawn wider than "
                + "their words, because the text could not be fitted to the printed words."),
            (SearchResultsSection.widenedBoxBannerHeadline(pages: [0, 2]), "Some boxes on pages 1 and 3 were drawn "
                + "wider than their words, because the text could not be fitted to the printed words."),
            (DetectionDegradeCopy.banner(failedGazetteers: []),
             "Detection is degraded for this session because the detection corpus failed to load."),
            (DetectionDegradeCopy.banner(failedGazetteers: ner), "Name detection is degraded for this session "
                + "because the on-device name model isn't available on this OS version."),
            (Self.limit40of120, "Showing first 1,000 results."),
            (Place.resultLimitSentence(stopPage: 40, unscannedPageCount: 80, interface: .scan),
             "Showing first 1,000 results."),
            (Place.resultLimitSentence(stopPage: 0, unscannedPageCount: 0, interface: .search),
             "Showing first 1,000 results."),
        ]
        #expect(rows.count == 11)
        for (text, first) in rows { #expect(Place.firstSentence(of: text) == first) }
        #expect(Place.firstSentence(of: Self.tooLarge7) == Self.tooLarge7)
    }

    // MARK: - Held, spoken, listed

    @Test("While a search runs the place holds the last search's lines, and a clear empties them")
    func held() {
        let finished = SearchNoticeState()
        let started = finished.heldForNextRun(lines: [Self.notSearched], wasSearching: false)
        #expect(started.held == [Self.notSearched])
        let cutShort = started.heldForNextRun(lines: [Self.timedOut], wasSearching: true)
        #expect(cutShort.held == [Self.notSearched])
        #expect(Place.shownLines(run: [Self.timedOut], held: [Self.notSearched], isSearching: true, degraded: nil)
            == [Self.notSearched])
        #expect(Place.shownLines(run: [Self.timedOut], held: [Self.notSearched], isSearching: false, degraded: nil)
            == [Self.timedOut])
        #expect(Place.shownLines(run: [], held: [], isSearching: true, degraded: nil).isEmpty)
        let state = SearchState()
        state.notices = started
        state.clearResults()
        #expect(state.notices == SearchNoticeState())
    }

    @Test("A notice is announced once, and again only when it changes or the list is cleared")
    func spokenOnce() {
        var state = SearchNoticeState()
        let t7 = Self.notSearched
        let t7and9 = Self.line(.notSearched, "Pages 7 and 9 were too large to scan for text \u{2014} image content "
            + "there was not searched.", [6, 8], "ocrSkipBanner")
        #expect(state.shouldAnnounce(t7, isHeld: false))
        state.announced.insert(t7.key)
        #expect(!state.shouldAnnounce(t7, isHeld: false), "not again at a raise")
        state = state.heldForNextRun(lines: [t7], wasSearching: false)
        #expect(!state.shouldAnnounce(t7, isHeld: true), "a held notice is not spoken")
        #expect(!state.shouldAnnounce(t7, isHeld: false), "not again when a later run ends with it")
        #expect(state.shouldAnnounce(t7and9, isHeld: false), "again when its sentence changes")
        #expect(SearchNoticeState().shouldAnnounce(t7, isHeld: false), "again after a clear")
    }

    @Test("The details list every notice that holds, pages not searched first")
    func details() {
        typealias C = NotSearchedListContent
        func rows(_ content: C) -> [[String]] { content.sections.map { $0.rows.map(\.sentence) } }
        func pages(_ content: C) -> [[[Int]]] { content.sections.map { $0.rows.map(\.pages) } }
        let both = Place.detailsContent([Self.notSearched, Self.timedOut])
        #expect(rows(both.notSearched) == [[Self.tooLarge7, Self.timedOut3and5]])
        #expect(pages(both.notSearched) == [[[6], [2, 4]]])
        #expect(both.others.sections.isEmpty)
        let fit = Place.detailsContent([Self.notSearched, Self.fit])
        #expect(rows(fit.notSearched) == [[Self.tooLarge7]])
        #expect(rows(fit.others) == [[Self.fit.sentence]])
        #expect(pages(fit.others) == [[[0]]])
        let scan = Place.detailsContent([Self.notSearched, Self.degraded])
        #expect(rows(scan.others) == [[Self.degradedCorpus]])
        #expect(pages(scan.others) == [[[]]])
        let alone = Place.detailsContent([Self.fit])
        #expect(alone.notSearched.sections.isEmpty)
        for content in [both.notSearched, both.others, fit.notSearched, fit.others, scan.others] {
            #expect(content.sections.allSatisfy { $0.nameLine == nil })
            #expect(content.smallPicturesLine == nil)
        }
    }

    @Test("The parked strip's mark speaks the notice that would show")
    func markLabel() {
        #expect(Place.stripMarkLabel([]) == nil)
        #expect(Place.stripMarkLabel([Self.notSearched, Self.fit]) == Self.tooLarge7)
        #expect(Place.stripMarkLabel([Self.degraded, Self.fit]) == Self.degradedCorpus)
        #expect(Place.stripMarkLabel([Self.fit]) == Self.fit.sentence)
    }

    @Test("A page chip in the details shows its page and parks the sheet")
    func chipParks() throws {
        let walk = try Self.source("Sources/ResectaApp/Views/Search/SearchAndRedactSheet+Walk.swift")
        let body = try #require(walk.components(separatedBy: "func showPage(_ page: Int)").last)
        let fn = String(body.prefix(400))
        #expect(fn.contains("PageNavigationBar.showPage("))
        #expect(fn.contains("selectedDetent = .compactFloat"))
        let notices = try Self.source("Sources/ResectaApp/Views/Search/SearchAndRedactSheet+Notices.swift")
        let closeThenShow = try #require(notices.range(of: "activeModal = nil\n            showPage(page)"))
        #expect(!closeThenShow.isEmpty)
    }

    // MARK: - Where it stands

    @Test("The parked strip mounts the mark in each of its shapes")
    func markMounted() throws {
        let nav = try Self.source("Sources/ResectaApp/Views/Search/SearchAndRedactSheet+ResultNavigation.swift")
        let cluster = try #require(nav.components(separatedBy: "func resultNavCluster(").last)
        #expect(cluster.prefix(300).contains("if site == .parked { stripNoticeMark }"))
        let strip = try Self.source("Sources/ResectaApp/Views/Search/SearchAndRedactSheet+CompactStrip.swift")
        let title = try #require(strip.components(separatedBy: "var compactStripTitle: some View {").last)
        #expect(title.prefix(600).contains("stripNoticeMark"))
        #expect(strip.components(separatedBy: "compactStripTitle\n").count - 1 >= 2,
                "both branches of the strip show the title")
    }

    @Test("The sheet notice takes its marks and surface from the message tokens")
    func tokens() throws {
        let view = try Self.source("Sources/ResectaApp/Views/Messages/SheetNoticeView.swift")
        #expect(view.contains("NoticeView.markColor(for: .caution)"))
        #expect(view.contains("NoticeSurface("))
        #expect(view.contains("NoticeView.Metrics"))
        #expect(view.contains("ResectaTokens.Ink.quietPill"))
        for raw in ["SemanticColor.warnText", ".orange"] { #expect(!view.contains(raw), "\(raw)") }
        // A colour built in place, not a token's name that ends in "Color(".
        #expect(view.range(of: #"(?<![A-Za-z.])Color\("#, options: .regularExpression) == nil)
    }

    @Test("The place stands above the list in every state")
    func placeAboveTheList() throws {
        let section = try Self.source("Sources/ResectaApp/Views/Search/SearchResultsSection.swift")
        #expect(section.components(separatedBy: ".safeAreaInset(edge: .top").count == 2)
        let chrome = try #require(section.components(separatedBy: "private var sectionTopChrome: some View {").last)
        #expect(chrome.prefix(500).contains("SearchNoticePlaceView("))
        let root = URL(fileURLWithPath: "\(#filePath)")
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = root.appendingPathComponent("Sources/ResectaApp")
        var mounts = 0
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        while let url = files?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            mounts += text.components(separatedBy: "SearchNoticePlaceView(").count - 1
        }
        #expect(mounts == 1)
    }

    static let packageFiles = [
        "Sources/ResectaApp/Views/Search/SearchNoticePlace.swift",
        "Sources/ResectaApp/State/SearchState+Notices.swift",
        "Sources/ResectaApp/Views/Messages/SheetNoticeView.swift",
        "Sources/ResectaApp/Views/Search/SearchNoticePlaceView.swift",
        "Sources/ResectaApp/Views/Search/NotSearchedDetailsSheet.swift",
        "Sources/ResectaApp/Views/Search/SearchAndRedactSheet+Notices.swift",
    ]

    @Test("Notices change no state when they leave the screen")
    func noDisappear() throws {
        for path in Self.packageFiles {
            #expect(!(try Self.source(path)).contains("onDisappear"), "\(path)")
        }
        let details = try Self.source("Sources/ResectaApp/Views/Search/NotSearchedDetailsSheet.swift")
        #expect(details.contains(".onChange(of: lines.isEmpty)"))
    }

    @Test("Only plain-styled buttons in the sheet's fixed top")
    func plainButtons() throws {
        for path in ["Sources/ResectaApp/Views/Messages/SheetNoticeView.swift",
                     "Sources/ResectaApp/Views/Search/SearchAndRedactSheet+Notices.swift"] {
            let parts = (try Self.source(path)).components(separatedBy: "Button {").dropFirst()
            for part in parts {
                #expect(part.prefix(700).contains(".buttonStyle(.plain)"), "\(path)")
            }
        }
    }

    @Test("The notice seed reads its facts")
    func seed() {
        let parsed = SearchState.noticeSeed(from: ["x", "--uitestNoticeSeed=tooLarge:6;timedOut:2,4;limit:40/120;degraded"])
        #expect(parsed?.facts.tooLargePages == [6])
        #expect(parsed?.facts.timedOutPages == [2, 4])
        #expect(parsed?.facts.atResultLimit == true)
        #expect(parsed?.facts.limitStopPage == 40)
        #expect(parsed?.facts.unscannedPageCount == 80)
        #expect(parsed?.degraded == true)
        #expect(SearchState.noticeSeed(from: ["x"]) == nil)
    }
}
