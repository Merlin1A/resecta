import Testing
import Foundation
import SwiftUI
@testable import RedactionEngine
@testable import ResectaApp

// The stop at Redact's sheet: its choices, what each answer does, when the
// editor's slot shows it, and its height. Each expectation is copied from
// the rule's table, never worked out from the code under test.

@Suite("Before You Redact")
@MainActor
struct BeforeYouRedactSheetTests {

    typealias Sheet = BeforeYouRedactSheet

    @Test("Exactly one capsule is teal in every state of the stop sheet, and it is never Redact Anyway")
    func oneTealCapsule() {
        // A recognition-off row with the re-run offered: three capsules.
        #expect(Sheet.choices(offersSearchThesePages: true) == [
            Sheet.Choice(capsule: .searchThesePages, style: .tealSolid),
            Sheet.Choice(capsule: .redactAnyway, style: .outlined),
            Sheet.Choice(capsule: .cancel, style: .plain),
        ])
        // Any other state: two capsules.
        #expect(Sheet.choices(offersSearchThesePages: false) == [
            Sheet.Choice(capsule: .redactAnyway, style: .outlined),
            Sheet.Choice(capsule: .cancel, style: .tealSolid),
        ])
        for offers in [true, false] {
            let choices = Sheet.choices(offersSearchThesePages: offers)
            #expect(choices.filter { $0.style == .tealSolid }.count == 1)
            #expect(!choices.contains(Sheet.Choice(capsule: .redactAnyway, style: .tealSolid)))
        }
    }

    @Test("Each answer does only what it promises; a swipe down and Go to page are Cancel")
    func answers() {
        typealias E = Sheet.Effects
        let table: [(BeforeYouRedactAnswer, E)] = [
            (.redactAnyway, E(records: true, clearsCase: true, entersRun: true, opensSearch: false, showsPage: nil)),
            (.searchThesePages(Self.reRun), E(records: false, clearsCase: true, entersRun: false, opensSearch: true, showsPage: nil)),
            (.cancel, E(records: false, clearsCase: true, entersRun: false, opensSearch: false, showsPage: nil)),
            (.swipedDown, E(records: false, clearsCase: true, entersRun: false, opensSearch: false, showsPage: nil)),
            (.goToPage(2), E(records: false, clearsCase: true, entersRun: false, opensSearch: false, showsPage: 2)),
        ]
        #expect(table.count == 5)
        for (answer, expected) in table {
            #expect(Sheet.effects(of: answer) == expected, "\(answer)")
        }
    }

    @Test("The slot shows the stop only while editing")
    func onlyWhileEditing() {
        let phases: [DocumentState.PhaseKind] =
            [.empty, .importing, .editing, .detecting, .redacting, .verifying, .verified, .exporting, .failed]
        var shown: [(DocumentState.PhaseKind, Bool)] = []
        for phase in phases {
            for awaits in [true, false]
            where DocumentEditorView.sheetSlotShowsStop(stopAwaitsAnswer: awaits, phaseKind: phase) {
                shown.append((phase, awaits))
            }
        }
        #expect(phases.count * 2 == 18)
        #expect(shown.count == 1)
        #expect(shown.first?.0 == .editing && shown.first?.1 == true)
    }

    @Test("The editor counts the stop as presenting, and its Cancel leaves no case awaiting")
    func stopCountsAsPresenting() {
        let coordinator = makeLoadedCoordinator()
        let documentState = coordinator.documentState
        let redactionState = coordinator.redactionState
        #expect(!DocumentEditorView.editorSlotIsPresenting(documentState: documentState, redactionState: redactionState))
        documentState.redactRefusalAwaitingAnswer = .pagesNotRead([RedactStop.Page(page: 0, reason: .line(.recognitionOff))])
        #expect(DocumentEditorView.editorSlotIsPresenting(documentState: documentState, redactionState: redactionState))
        DocumentEditorView.applyStopAnswer(.cancel, documentState: documentState, redactionState: redactionState,
                                           coordinator: coordinator, documentOverride: nil)
        #expect(documentState.redactRefusalAwaitingAnswer == nil)
        #expect(redactionState.redactStopAnswered.isEmpty)
        #expect(!DocumentEditorView.editorSlotIsPresenting(documentState: documentState, redactionState: redactionState))
    }

    @Test("The stop's height follows its content, and it opens at full height at the accessibility sizes")
    func height() {
        #expect(Sheet.stopSheetDetent(contentHeight: 420, availableHeight: 800, isAccessibilitySize: false) == .height(420))
        #expect(Sheet.stopSheetDetent(contentHeight: 900, availableHeight: 800, isAccessibilitySize: false) == .large)
        #expect(Sheet.stopSheetDetent(contentHeight: 420, availableHeight: 800, isAccessibilitySize: true) == .large)
    }

    /// A re-run as the stop's producer gives it: recognition on, any term.
    static let reRun = AppliedSearchQuery(kind: .multiTerm(["Delia", "Rourke"]),
                                          options: SearchOptions(caseSensitive: true, includeOCR: true, multiTermConjunction: false))

    @Test("Search These Pages opens a session in the re-run's mode, terms and options, armed to run once")
    func reRunSessionByKind() {
        let options = Self.reRun.options
        let cases: [(AppliedSearchQuery.Kind, SearchModeType)] = [
            (.text("Hartwell"), .text), (.regex("[0-9]{3}"), .regex),
            (.multiTerm(["Delia", "Rourke"]), .multiTerm), (.piiScan(categories: [.email]), .piiScan),
        ]
        for (kind, mode) in cases {
            let session = SearchState.reRunSession(for: AppliedSearchQuery(kind: kind, options: options))
            #expect(session.searchModeType == mode, "\(kind)")
            #expect(session.options == options, "\(kind)")
            #expect(session.options.includeOCR && !session.options.multiTermConjunction, "\(kind)")
            #expect(session.pendingAutoRun == mode, "\(kind)")
            switch kind {
            case .text(let text), .regex(let text): #expect(session.queryText == text)
            case .multiTerm(let terms): #expect(session.searchTerms == terms)
            case .piiScan(let categories): #expect(session.enabledPIICategories == categories)
            }
        }
    }

    @Test("The one-shot runs once as the sheet appears, and not once the mode has changed")
    func autoRunFiresOnce() {
        let session = SearchState.reRunSession(for: Self.reRun)
        #expect(session.consumeAutoRun())
        #expect(!session.consumeAutoRun())
        let changed = SearchState.reRunSession(for: Self.reRun)
        changed.searchModeType = .text
        #expect(!changed.consumeAutoRun())
        #expect(changed.pendingAutoRun == nil)
    }

    @Test("Search These Pages answers nothing, clears the case and puts the re-run's session in the slot")
    func searchThesePagesOpensTheReRun() throws {
        let coordinator = makeLoadedCoordinator()
        let documentState = coordinator.documentState
        let redactionState = coordinator.redactionState
        documentState.redactRefusalAwaitingAnswer = .pagesNotRead([RedactStop.Page(page: 0, reason: .line(.recognitionOff))])
        DocumentEditorView.applyStopAnswer(.searchThesePages(Self.reRun), documentState: documentState,
                                           redactionState: redactionState, coordinator: coordinator, documentOverride: nil)
        #expect(documentState.redactRefusalAwaitingAnswer == nil)
        #expect(redactionState.redactStopAnswered.isEmpty)
        let session = try #require(redactionState.activeSearch)
        #expect(session.searchModeType == .multiTerm && session.searchTerms == ["Delia", "Rourke"])
        #expect(session.pendingAutoRun == .multiTerm)
    }

    @Test("The user's own session parked by the stop is kept through Search These Pages and comes back when the slot is free")
    func searchThesePagesKeepsTheUsersSession() {
        #expect(DocumentEditorView.stopAnswerDropsParkedSearch(.redactAnyway))
        #expect(!DocumentEditorView.stopAnswerDropsParkedSearch(.searchThesePages(Self.reRun)))
        #expect(!DocumentEditorView.stopAnswerDropsParkedSearch(.cancel))
        // The re-run's session holds the slot: the user's waits.
        #expect(!DocumentEditorView.handOffRestores(stopParkedSearch: true, stopUp: false, searchUp: true, homeWaits: false, settingsWaits: false))
        // The re-run's session closed: the user's comes back.
        #expect(DocumentEditorView.handOffRestores(stopParkedSearch: true, stopUp: false, searchUp: false, homeWaits: false, settingsWaits: false))
        #expect(!DocumentEditorView.handOffRestores(stopParkedSearch: true, stopUp: false, searchUp: false, homeWaits: true, settingsWaits: false))
        #expect(!DocumentEditorView.handOffRestores(stopParkedSearch: false, stopUp: false, searchUp: false, homeWaits: false, settingsWaits: false))
        // The stop still up: the Search sheet taken down for it is dismissed under it, and nothing comes back.
        #expect(!DocumentEditorView.handOffRestores(stopParkedSearch: true, stopUp: true, searchUp: false, homeWaits: false, settingsWaits: false))
    }

    @Test("The stop's case arriving with Search up parks the user's own session whole; the Search sheet's dismissal under the stop keeps it parked; Search These Pages keeps it until the re-run's session closes, and then it comes back")
    func theStopParksTheUsersSessionThroughSearchThesePages() {
        let redactionState = RedactionState()
        let users = SearchState()
        let document = UUID()
        redactionState.activeSearch = users
        var parked: SearchState?
        var stopParked = false
        // The case arrives with the user's session up: parked whole, out of the slot, and the stop is shown.
        DocumentEditorView.parkSearchForStop(stopUp: true, redactionState: redactionState, document: document,
                                             parked: &parked, stopParked: &stopParked)
        #expect(parked === users)
        #expect(stopParked)
        #expect(redactionState.activeSearch == nil)
        #expect(users.parkedForHomeClose && users.parkedDocument == document)
        #expect(DocumentEditorView.slotItem(stopUp: true, activeSearch: redactionState.activeSearch,
                                            mayPresentSearch: true, rationale: nil)?.id == "before-redact")
        // The Search sheet's dismissal, with the stop up: the session stays parked.
        #expect(!DocumentEditorView.handOffAfterStop(stopUp: true, redactionState: redactionState, homeWaits: false,
                                                     settingsWaits: false, stopParked: &stopParked))
        #expect(stopParked && parked === users)
        // Search These Pages: the stop goes down and the re-run's session holds the slot; the user's waits.
        redactionState.activeSearch = SearchState.reRunSession(for: Self.reRun)
        #expect(!DocumentEditorView.handOffAfterStop(stopUp: false, redactionState: redactionState, homeWaits: false,
                                                     settingsWaits: false, stopParked: &stopParked))
        #expect(stopParked && parked === users)
        // The re-run's session closed: the user's comes back.
        redactionState.activeSearch = nil
        #expect(DocumentEditorView.handOffAfterStop(stopUp: false, redactionState: redactionState, homeWaits: false,
                                                    settingsWaits: false, stopParked: &stopParked))
        #expect(!stopParked)
    }

    @Test("Cancel with the user's session parked for the stop, and nothing else waiting for the slot: the session comes back; with no stop up nothing is parked")
    func cancelBringsTheParkedSessionBack() {
        let redactionState = RedactionState()
        let users = SearchState()
        redactionState.activeSearch = users
        var parked: SearchState?
        var stopParked = false
        // No stop up: the park for the stop leaves the session where it is.
        DocumentEditorView.parkSearchForStop(stopUp: false, redactionState: redactionState, document: UUID(),
                                             parked: &parked, stopParked: &stopParked)
        #expect(parked == nil && !stopParked && redactionState.activeSearch === users)
        DocumentEditorView.parkSearchForStop(stopUp: true, redactionState: redactionState, document: UUID(),
                                             parked: &parked, stopParked: &stopParked)
        #expect(parked === users && stopParked)
        // Home's dialog waiting for the slot keeps it parked for Home.
        #expect(!DocumentEditorView.handOffAfterStop(stopUp: false, redactionState: redactionState, homeWaits: true,
                                                     settingsWaits: false, stopParked: &stopParked))
        // Cancel, nothing waiting: it comes back.
        #expect(DocumentEditorView.handOffAfterStop(stopUp: false, redactionState: redactionState, homeWaits: false,
                                                    settingsWaits: false, stopParked: &stopParked))
        #expect(!stopParked)
    }

    /// Hand words: the name line lists the texts; a row names its reason and pages.
    static let words = BeforeYouRedactWords(
        nameLine: { names, withOptions, _ in
            let line = names.map { withOptions.contains(RedactStop.NamedText(kind: $0.kind, text: $0.text)) ? "\($0.text)*" : $0.text }
                .joined(separator: ", ")
            return NotSearchedListContent.NameLine(shown: line, spoken: line)
        },
        row: { group, _ in "\(group.reason) \(group.pages)" })
    typealias G = RedactStopGroupsTests

    @Test("The stop shows only the pages its case carries")
    func showsOnlyTheCasesPages() {
        let runs: [RedactStop.Run] = [(G.text("Delia"), G.unread)]
        let casePages: Set<RedactStop.Page> = [.init(page: 2, reason: .line(.recognitionOff)), .init(page: 4, reason: .line(.recognitionOff))]
        let stop = Sheet.stop(casePages: casePages, runs: runs, answered: [], words: Self.words)
        #expect(stop.content.sections.count == 1)
        #expect(stop.content.sections[0].nameLine == nil)
        #expect(stop.content.sections[0].rows.map(\.pages) == [[2, 4]])
        #expect(stop.content.smallPicturesLine == nil)
    }

    @Test("A section per set of searches, the one with no name first, its name line in run order")
    func sectionsBySearches() {
        let onlyFive = G.account((0..<10).map { $0 == 4 ? [] : [.ownText] }, off: [4])
        let runs: [RedactStop.Run] = [(G.text("Delia"), G.unread), (G.text("Rourke"), onlyFive)]
        let casePages = Set([2, 4, 8].map { RedactStop.Page(page: $0, reason: .line(.recognitionOff)) })
        let stop = Sheet.stop(casePages: casePages, runs: runs, answered: [], words: Self.words)
        #expect(stop.content.sections.count == 2)
        #expect(stop.content.sections[0].nameLine == nil && stop.content.sections[0].rows.map(\.pages) == [[4]])
        #expect(stop.content.sections[1].nameLine?.shown == "Delia" && stop.content.sections[1].rows.map(\.pages) == [[2, 8]])
    }

    @Test("Search These Pages is offered only when a group the stop shows has a re-run")
    func offersOnlyForAShownGroup() throws {
        let runs: [RedactStop.Run] = [(G.text("Delia"), G.unread)]
        let off = Sheet.stop(casePages: [.init(page: 2, reason: .line(.recognitionOff))], runs: runs, answered: [], words: Self.words)
        let reRun = try #require(off.reRun)
        #expect(reRun.kind == .text("Delia") && reRun.options.includeOCR)
        let tooLarge = G.account((0..<3).map { $0 == 1 ? [.tooLarge] : [.ownText] })
        let large = Sheet.stop(casePages: [.init(page: 1, reason: .line(.tooLarge))], runs: [(G.text("Delia"), tooLarge)],
                               answered: [], words: Self.words)
        #expect(large.content.sections.count == 1)
        #expect(large.reRun == nil)
        // Recognition off on page 3 too, but the case carries only page 2: no re-run is offered.
        let both = G.account([[.ownText], [.tooLarge], []], off: [2])
        let onlyLarge = Sheet.stop(casePages: [.init(page: 1, reason: .line(.tooLarge))], runs: [(G.text("Delia"), both)],
                                   answered: [], words: Self.words)
        #expect(onlyLarge.content.sections.flatMap { $0.rows }.map { $0.pages } == [[1]])
        #expect(onlyLarge.reRun == nil)
    }

    @Test("The re-run searches the whole document; once its account joins, the stop names none of the pages it showed")
    func afterTheReRunNothingIsNamed() throws {
        let runs: [RedactStop.Run] = [(G.text("Delia"), G.unread)]
        let casePages = Set([2, 4, 8].map { RedactStop.Page(page: $0, reason: .line(.recognitionOff)) })
        let before = Sheet.stop(casePages: casePages, runs: runs, answered: [], words: Self.words)
        let reRun = try #require(before.reRun)
        let after = Sheet.stop(casePages: casePages, runs: runs + [(reRun, G.read)], answered: [], words: Self.words)
        #expect(after.content.sections.isEmpty)
        #expect(after.reRun == nil)
    }

    @Test("The stop's name line in each of its forms")
    func nameLines() {
        let delia = G.unit(.text, "Delia"), rourke = G.unit(.text, "Rourke"), moss = G.unit(.text, "Moss")
        let pattern = G.unit(.pattern, "[0-9]{3}"), scan = G.unit(.scan, "")
        let table: [([RedactStopUnit], String)] = [
            ([delia], "For your search for \u{201C}Delia\u{201D}:"),
            ([delia, rourke], "For your searches for \u{201C}Delia\u{201D} and \u{201C}Rourke\u{201D}:"),
            ([delia, rourke, moss], "For your searches for \u{201C}Delia\u{201D}, \u{201C}Rourke\u{201D}, and \u{201C}Moss\u{201D}:"),
            ([pattern], "For your pattern search \u{201C}[0-9]{3}\u{201D}:"),
            ([scan], "For your Scan:"),
            ([delia, scan], "For your search for \u{201C}Delia\u{201D} and for your Scan:"),
            ([delia, pattern, scan], "For your search for \u{201C}Delia\u{201D}, for your pattern search \u{201C}[0-9]{3}\u{201D}, and for your Scan:"),
        ]
        #expect(table.count == 7)
        for (names, line) in table {
            #expect(StopWords.nameLine(names, withOptions: [], allUnits: names) == line)
        }
        let strict = G.unit(.text, "Hartwell", SearchOptions(caseSensitive: true)), loose = G.unit(.text, "Hartwell")
        #expect(StopWords.nameLine([strict], withOptions: [RedactStop.NamedText(kind: .text, text: "Hartwell")],
                                   allUnits: [strict, loose])
                == "For your search for \u{201C}Hartwell\u{201D} with Case-sensitive on:")
    }

    @Test("Not reached names the cause only when every search ended that way; a mixed group is searched and scanned")
    func notReachedRows() {
        let delia = G.unit(.text, "Delia"), scan = G.unit(.scan, "")
        func row(_ pages: [Int], _ ending: RedactStop.NotReachedEnding?, _ names: [RedactStopUnit]) -> String? {
            StopWords.row(RedactStop.Group(reason: .line(.notReached), units: Set(names), pages: pages, notReachedEnding: ending), names: names)
        }
        #expect(row([5], .stopped, [delia]) == "Page 6 was not searched, because the search stopped before it reached it.")
        #expect(row([5, 6, 7], .stopped, [delia]) == "Pages 6\u{2013}8 were not searched, because the search stopped before it reached them.")
        #expect(row([5], .atResultLimit, [delia])
                == "Page 6 was not searched, because the search reached its limit of 1,000 results before it reached it.")
        #expect(row([5, 7], .differs, [delia]) == "Pages 6 and 8 were not searched, because the search ended before it reached them.")
        #expect(row([5], .stopped, [scan]) == "Page 6 was not scanned, because the Scan stopped before it reached it.")
        #expect(row([5], .stopped, [delia, scan])
                == "Page 6 was not searched and scanned, because the search and the Scan stopped before they reached it.")
        #expect(row([1, 3, 4, 5, 6, 11], .stopped, [delia])
                == "Pages 2, 4\u{2013}7, and 12 were not searched, because the search stopped before it reached them.")
        #expect(row([5, 6], .atResultLimit, [delia, scan])
                == "Pages 6 and 7 were not searched and scanned, because the search and the Scan reached their limit of 1,000 results before they reached them.")
    }

    @Test("Searched in part in its three forms; the other reasons take the Search sheet's lines")
    func searchedInPartRows() {
        let delia = G.unit(.text, "Delia"), scan = G.unit(.scan, "")
        func row(_ reason: RedactStop.Reason, _ names: [RedactStopUnit]) -> String? {
            StopWords.row(RedactStop.Group(reason: reason, units: Set(names), pages: [3]), names: names)
        }
        #expect(row(.searchedInPart, [delia]) == "Page 4 was searched in part.")
        #expect(row(.searchedInPart, [scan]) == "Page 4 was scanned in part.")
        #expect(row(.searchedInPart, [delia, scan]) == "Page 4 was searched and scanned in part.")
        #expect(row(.line(.recognitionOff), [delia]) == nil)
    }

    /// A source file of the app, its comment lines left out.
    static func source(_ path: String) throws -> String {
        let file = URL(fileURLWithPath: "\(#filePath)")
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(path)
        return try String(contentsOf: file, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// The offset of `needle` in `text` at or after `from`, or nil.
    static func offset(of needle: String, in text: String, from: String.Index? = nil) -> String.Index? {
        text.range(of: needle, range: (from ?? text.startIndex)..<text.endIndex)?.lowerBound
    }

    @Test("The stop takes the slot ahead of Search and the canvas rationale")
    func stopTakesTheSlotFirst() throws {
        let text = try Self.source("Sources/ResectaApp/Views/DocumentEditorView.swift")
        let search = SearchState(), region = UUID()
        // The stop first: ahead of the canvas rationale.
        #expect(DocumentEditorView.slotItem(stopUp: true, activeSearch: nil, mayPresentSearch: true,
                                            rationale: region)?.id == "before-redact")
        // A session not yet parked holds the slot: the stop waits for the park, so the session's teardown never runs.
        #expect(DocumentEditorView.slotItem(stopUp: true, activeSearch: search, mayPresentSearch: true,
                                            rationale: nil)?.id == "search-\(search.id)")
        #expect(DocumentEditorView.slotItem(stopUp: false, activeSearch: search, mayPresentSearch: true,
                                            rationale: region)?.id == "search-\(search.id)")
        #expect(DocumentEditorView.slotItem(stopUp: false, activeSearch: nil, mayPresentSearch: true,
                                            rationale: region)?.id == "rationale-\(region)")
        #expect(DocumentEditorView.slotItem(stopUp: false, activeSearch: search, mayPresentSearch: false,
                                            rationale: nil) == nil)
        // The slot's getter is that rule.
        let get = try #require(Self.offset(of: "get: {", in: text))
        let rule = try #require(Self.offset(of: "Self.slotItem(stopUp: sheetSlotShowsStop", in: text, from: get))
        let set = try #require(Self.offset(of: "set: { newValue in", in: text))
        #expect(rule < set)
        let swipe = try #require(Self.offset(of: "answerStop(.swipedDown)", in: text, from: set))
        let session = try #require(Self.offset(of: "if let session = redactionState.activeSearch", in: text, from: set))
        #expect(swipe < session)
        let dismiss = try #require(text.range(of: "onDismiss: {\n"))
        let next = text[dismiss.upperBound...].drop { $0 == " " }
        #expect(next.hasPrefix("handOffAfterStop()"))
    }

    @Test("Cancel and Go to page leave the answered set as it was; Go to page shows the page")
    func cancelAndGoToPageRecordNothing() {
        let coordinator = makeLoadedCoordinator()
        let documentState = coordinator.documentState
        let redactionState = coordinator.redactionState
        let page = RedactStop.Page(page: 0, reason: .line(.recognitionOff))
        documentState.redactRefusalAwaitingAnswer = .pagesNotRead([page])
        DocumentEditorView.applyStopAnswer(.goToPage(2), documentState: documentState, redactionState: redactionState,
                                           coordinator: coordinator, documentOverride: nil)
        #expect(documentState.redactRefusalAwaitingAnswer == nil)
        #expect(redactionState.redactStopAnswered.isEmpty)
        #expect(documentState.currentPageIndex == 2)
        documentState.redactRefusalAwaitingAnswer = .pagesNotRead([page])
        DocumentEditorView.applyStopAnswer(.swipedDown, documentState: documentState, redactionState: redactionState,
                                           coordinator: coordinator, documentOverride: nil)
        #expect(documentState.redactRefusalAwaitingAnswer == nil)
        #expect(redactionState.redactStopAnswered.isEmpty)
    }

    @Test("The stop sheet carries the capture cover, takes the monitor as a value, and changes nothing when it leaves the screen")
    func carriesTheCaptureCover() throws {
        let text = try Self.source("Sources/ResectaApp/Views/BeforeYouRedactSheet.swift")
        #expect(text.components(separatedBy: ".shieldedSheetContent(monitor:").count - 1 == 1)
        #expect(text.components(separatedBy: "let captureMonitor: ScreenCaptureMonitor").count - 1 == 1)
        #expect(!text.contains("@Environment(ScreenCaptureMonitor.self)"))
        #expect(!text.contains("onDisappear"))
    }

    /// A row's reason as a short key, for the table below.
    static func key(_ reason: RedactStop.Reason) -> String {
        switch reason {
        case .searchedInPart: return "part"
        case .line(.notReached): return "notReached"
        case .line(.recognitionOff): return "off"
        case .line(.tooLarge): return "large"
        case .line: return "other"
        }
    }
    static let keyWords = BeforeYouRedactWords(
        nameLine: { names, _, _ in
            let line = names.map(\.text).joined(separator: ", ")
            return NotSearchedListContent.NameLine(shown: line, spoken: line)
        },
        row: { group, _ in key(group.reason) })

    /// One expected section: its name line (nil for none) and its rows' keys and pages.
    typealias Expected = (name: String?, rows: [(String, [Int])])

    // The cases are rebuilt from the state part's own suites (RedactStopTests,
    // RedactStopGroupsTests).
    @Test("The stop's list is the grouping function's output, in order, once each")
    func listIsTheGrouping() {
        let scanQuery = AppliedSearchQuery(kind: .piiScan(categories: []), options: SearchOptions())
        let onlyFive = G.account((0..<10).map { $0 == 4 ? [] : [.ownText] }, off: [4])
        let onlyThree = G.account((0..<10).map { $0 == 2 ? [] : [.ownText] }, off: [2])
        let stopped = G.account((0..<10).map { $0 > 4 ? [] : [.ownText] }, .stopped(page: 4))
        let largeAndOff = G.account([[.ownText], [.tooLarge], [], [.ownText]], off: [2])
        let table: [(String, [RedactStop.Run], Set<RedactStop.Page>, [Expected])] = [
            ("one text, recognition off", [(G.text("Delia"), G.unread)], [],
             [(nil, [("off", [2, 4, 8])])]),
            ("two texts unread alike", [(G.text("Delia"), G.unread), (G.text("Rourke"), G.unread)], [],
             [(nil, [("off", [2, 4, 8])])]),
            ("one text on more pages than another", [(G.text("Delia"), G.unread), (G.text("Rourke"), onlyFive)], [],
             [(nil, [("off", [4])]), ("Delia", [("off", [2, 8])])]),
            ("a run stopped on page 5", [(G.text("Delia"), stopped)], [],
             [(nil, [("part", [4]), ("notReached", [5, 6, 7, 8, 9])])]),
            ("a page answered", [(G.text("Delia"), G.unread)], [RedactStop.Page(page: 2, reason: .line(.recognitionOff))],
             [(nil, [("off", [4, 8])])]),
            ("two reasons, in the Search sheet's order", [(G.text("Delia"), largeAndOff)], [],
             [(nil, [("large", [1]), ("off", [2])])]),
            ("a pattern and a text", [(G.text("Delia"), G.unread), (AppliedSearchQuery(kind: .regex("[0-9]{3}"), options: SearchOptions()), onlyThree)], [],
             [(nil, [("off", [2])]), ("Delia", [("off", [4, 8])])]),
            ("a Scan and a text unread alike", [(G.text("Delia"), G.unread), (scanQuery, G.unread)], [],
             [(nil, [("off", [2, 4, 8])])]),
            ("two of three texts unread", [(G.text("Delia"), G.unread), (G.text("Rourke"), G.unread), (G.text("Moss"), G.read)], [],
             [("Delia, Rourke", [("off", [2, 4, 8])])]),
        ]
        #expect(table.count == 9)
        for (name, runs, answered, expected) in table {
            let casePages = RedactStop.namedPages(runs: runs, answered: answered)
            let stop = Sheet.stop(casePages: casePages, runs: runs, answered: answered, words: Self.keyWords)
            #expect(stop.content.sections.map { $0.nameLine?.shown } == expected.map(\.name), "\(name)")
            #expect(stop.content.sections.map { $0.rows.map(\.sentence) } == expected.map { $0.rows.map(\.0) }, "\(name)")
            #expect(stop.content.sections.map { $0.rows.map(\.pages) } == expected.map { $0.rows.map(\.1) }, "\(name)")
            #expect(stop.content.sections.allSatisfy { $0.nameLine.map { $0.shown == $0.spoken } ?? true }, "\(name)")
        }
    }
}
