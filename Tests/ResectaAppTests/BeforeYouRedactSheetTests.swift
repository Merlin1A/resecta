import Testing
import Foundation
import SwiftUI
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
        #expect(!DocumentEditorView.handOffRestores(stopParkedSearch: true, searchUp: true, homeWaits: false, settingsWaits: false))
        // The re-run's session closed: the user's comes back.
        #expect(DocumentEditorView.handOffRestores(stopParkedSearch: true, searchUp: false, homeWaits: false, settingsWaits: false))
        #expect(!DocumentEditorView.handOffRestores(stopParkedSearch: true, searchUp: false, homeWaits: true, settingsWaits: false))
        #expect(!DocumentEditorView.handOffRestores(stopParkedSearch: false, searchUp: false, homeWaits: false, settingsWaits: false))
    }

    /// Hand words: the name line lists the texts; a row names its reason and pages.
    static let words = BeforeYouRedactWords(
        nameLine: { names, withOptions in
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
        #expect(onlyLarge.content.sections.flatMap(\.rows).map(\.pages) == [[1]])
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
}
