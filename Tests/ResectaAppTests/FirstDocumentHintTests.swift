import Testing
import Foundation
import SwiftUI
@testable import ResectaApp

// The first-time line: shown on the first document while editing, with no
// sheet or dialog up and no message at the slot; ended for good by the
// person's first action (with VoiceOver running, only a state change); its
// second sentence names the Redact button where the bar shows it and the
// More menu where Redact is folded; drawn by the brief message's size rule.

@MainActor
@Suite("First-time line")
struct FirstDocumentHintTests {

    typealias Rules = FirstDocumentHintRules

    private static func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private static func repoFile(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot().appendingPathComponent(relativePath), encoding: .utf8)
    }

    private static func freshDefaults(_ name: String) -> UserDefaults {
        let suite = "FirstDocumentHintTests.\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    // MARK: - when it shows

    struct ShowCase: Sendable, CustomTestStringConvertible {
        let done: Bool
        let phase: DocumentState.PhaseKind
        let covered: Bool
        let message: Bool
        let shows: Bool
        var testDescription: String {
            "done \(done), \(phase), covered \(covered), message \(message) → \(shows ? "shows" : "hidden")"
        }
    }

    static let showCases: [ShowCase] = [
        ShowCase(done: false, phase: .editing, covered: false, message: false, shows: true),
        ShowCase(done: false, phase: .editing, covered: false, message: true, shows: false),
        ShowCase(done: false, phase: .editing, covered: true, message: false, shows: false),
        ShowCase(done: false, phase: .editing, covered: true, message: true, shows: false),
        ShowCase(done: true, phase: .editing, covered: false, message: false, shows: false),
        ShowCase(done: true, phase: .editing, covered: false, message: true, shows: false),
        ShowCase(done: false, phase: .detecting, covered: false, message: false, shows: false),
        ShowCase(done: false, phase: .empty, covered: false, message: false, shows: false),
    ]

    @Test("The line shows on a first document while editing, with no sheet and no message", arguments: showCases)
    func showsOnlyWhenDue(_ row: ShowCase) {
        let covers = Rules.Covers(editorSheet: row.covered)
        let due = Rules.isDue(done: row.done, phaseKind: row.phase, covers: covers)
        #expect(Rules.shows(due: due, messageAtSlot: row.message) == row.shows)
    }

    @Test("Every row of the showing table is counted")
    func showTableCounted() {
        #expect(Self.showCases.count == 8)
        #expect(Self.showCases.filter(\.shows).count == 1)
    }

    @Test("A message holds the slot: the line waits and shows when the message leaves")
    func waitsBehindAMessage() {
        let due = Rules.isDue(done: false, phaseKind: .editing, covers: .init())
        #expect(due)
        #expect(!Rules.shows(due: due, messageAtSlot: true))
        #expect(Rules.shows(due: due, messageAtSlot: false))
    }

    // MARK: - once

    @Test("Once it has left it never shows again")
    func onceLeftNeverAgain() {
        let defaults = Self.freshDefaults("once")
        let store = FirstDocumentHintStore(defaults: defaults)
        #expect(!store.isDone)
        #expect(Rules.isDue(done: store.isDone, phaseKind: .editing, covers: .init()))
        store.markDone()
        let later = FirstDocumentHintStore(defaults: defaults)
        #expect(later.isDone)
        #expect(!Rules.isDue(done: later.isDone, phaseKind: .editing, covers: .init()))
        #expect(defaults.bool(forKey: "firstDocumentHint.done.v1"))
    }

    @Test("Only the test launch clears the flag")
    func clearUnsets() {
        let defaults = Self.freshDefaults("clear")
        let store = FirstDocumentHintStore(defaults: defaults)
        store.markDone()
        store.clear()
        #expect(!FirstDocumentHintStore(defaults: defaults).isDone)
    }

    // MARK: - never during a run

    /// Every phase but editing; a new phase stops this switch from compiling.
    static func isEditing(_ phase: DocumentState.PhaseKind) -> Bool {
        switch phase {
        case .editing: true
        case .empty, .importing, .detecting, .redacting, .verifying, .verified, .exporting, .failed: false
        }
    }

    static let otherPhases: [DocumentState.PhaseKind] = [
        .empty, .importing, .detecting, .redacting, .verifying, .verified, .exporting, .failed,
    ]

    @Test("Never during a run, nor in any phase but editing", arguments: otherPhases)
    func neverOutsideEditing(_ phase: DocumentState.PhaseKind) {
        #expect(!Self.isEditing(phase))
        #expect(!Rules.isDue(done: false, phaseKind: phase, covers: .init()))
    }

    @Test("Every phase but editing is listed")
    func otherPhasesCounted() {
        #expect(Self.otherPhases.count == 8)
        #expect(Set(Self.otherPhases).count == 8)
    }

    // MARK: - never with a sheet or dialog up

    static let coverSources: [(String, Rules.Covers)] = [
        ("the editor's sheet", Rules.Covers(editorSheet: true)),
        ("Settings", Rules.Covers(settings: true)),
        ("the password sheet", Rules.Covers(password: true)),
        ("the drop's replace dialog", Rules.Covers(dropReplace: true)),
        ("the close dialog", Rules.Covers(closeDialog: true)),
    ]

    @Test("Never with a sheet or dialog up: one row per source")
    func neverCovered() {
        #expect(Self.coverSources.count == 5)
        for (name, covers) in Self.coverSources {
            #expect(covers.any, "\(name)")
            #expect(!Rules.isDue(done: false, phaseKind: .editing, covers: covers), "\(name)")
        }
        #expect(!Rules.Covers().any)
        #expect(Rules.isDue(done: false, phaseKind: .editing, covers: .init()))
    }

    // MARK: - the first action

    static let editing = Rules.Snapshot(
        editing: true, covered: false, activeTool: nil, addToSelection: false,
        selection: [], regionVersion: 0, page: 0)

    static func changed(_ change: (inout Rules.Snapshot) -> Void, from base: Rules.Snapshot = editing) -> Rules.Snapshot {
        var snapshot = base
        change(&snapshot)
        return snapshot
    }

    struct ActionCase: @unchecked Sendable, CustomTestStringConvertible {
        let name: String
        let old: Rules.Snapshot
        let new: Rules.Snapshot
        let action: Rules.Action?
        var testDescription: String { name }
    }

    static let actionCases: [ActionCase] = [
        ActionCase(name: "a tool chosen", old: editing,
                   new: changed { $0.activeTool = .rectangle }, action: .toolChosen),
        ActionCase(name: "Add to Selection", old: editing,
                   new: changed { $0.addToSelection = true }, action: .addToSelection),
        ActionCase(name: "a box selected", old: editing,
                   new: changed { $0.selection = [UUID()] }, action: .selectionChanged),
        ActionCase(name: "a box made, moved or removed", old: editing,
                   new: changed { $0.regionVersion = 1 }, action: .boxesChanged),
        ActionCase(name: "a page turned", old: editing,
                   new: changed { $0.page = 1 }, action: .pageTurned),
        ActionCase(name: "a sheet or dialog opened", old: editing,
                   new: changed { $0.covered = true }, action: .sheetOpened),
        ActionCase(name: "editing left", old: editing,
                   new: changed { $0.editing = false }, action: .leftEditing),
        ActionCase(name: "a sheet or dialog closed", old: changed { $0.covered = true },
                   new: editing, action: nil),
        ActionCase(name: "nothing changed", old: editing, new: editing, action: nil),
        // A document's arrival sets the page, the boxes and the tools in the
        // update that enters editing: none of it counts.
        ActionCase(name: "the arrival", old: changed({ $0.editing = false; $0.page = 4; $0.regionVersion = 9 }),
                   new: editing, action: nil),
        ActionCase(name: "changes outside editing", old: changed { $0.editing = false },
                   new: changed({ $0.editing = false; $0.page = 3 }), action: nil),
    ]

    @Test("The state changes that count as the first action, only while editing", arguments: actionCases)
    func stateChangesThatCount(_ row: ActionCase) {
        #expect(Rules.action(from: row.old, to: row.new) == row.action)
    }

    @Test("Every state change of the editor is in the action table")
    func actionTableCounted() {
        #expect(Self.actionCases.count == 11)
        let named = Set(Self.actionCases.compactMap(\.action))
        #expect(named == Set(Rules.Action.allCases).subtracting([.touch]))
    }

    @Test("The first action sets the flag; with VoiceOver, only an activation does")
    func voiceOverTouchesDoNotCount() {
        var rows = 0
        for action in Rules.Action.allCases {
            for voiceOver in [false, true] {
                rows += 1
                let expected = !(action == .touch && voiceOver)
                #expect(Rules.ends(action, voiceOverRunning: voiceOver) == expected, "\(action), VoiceOver \(voiceOver)")
            }
        }
        #expect(rows == 16)
    }

    // MARK: - the size rule

    @Test("The line's size follows the brief message's rule")
    func sizeFollowsTheMessageRule() {
        let limit = MessageSizing.limit(space: 613)
        let heights: [DynamicTypeSize: CGFloat] = [.accessibility5: 272, .accessibility4: 236, .accessibility3: 208]
        #expect(MessageSizing.drawSize(person: .accessibility5, limit: limit) { heights[$0] ?? 0 } == .accessibility4)
        #expect(MessageSizing.drawSize(person: .large, limit: limit) { _ in 1_000 } == .large)
        #expect(MessageSizing.drawSize(person: .accessibility5, limit: limit) { _ in 1_000 } == .accessibility3)
    }

    @Test("Drawn: at the largest size on a 402-point screen the line is drawn smaller, within two fifths or at the third accessibility size")
    func drawnLineFitsOrStopsAtTheFloor() {
        let canvas = CGSize(width: 402, height: 613)
        let limit = MessageSizing.limit(space: canvas.height)
        let person = DynamicTypeSize.accessibility5
        let atPerson = FirstDocumentHintView.height(personSize: person, size: person, width: canvas.width)
        #expect(atPerson > limit)
        let drawn = FirstDocumentHintView.drawSize(personSize: person, canvas: canvas)
        #expect(drawn < person)
        let atDrawn = FirstDocumentHintView.height(personSize: person, size: drawn, width: canvas.width)
        #expect(atDrawn <= limit || drawn == MessageSizing.typeFloor)
        // At the default size the line is drawn at the person's size.
        #expect(FirstDocumentHintView.drawSize(personSize: .large, canvas: CGSize(width: 402, height: 654)) == .large)
    }

    // MARK: - the symbol and the words

    @Test("The line's symbol is the Redact button's, and its words are as chosen")
    func wordsAndSymbol() throws {
        typealias Words = FirstDocumentHintWords
        #expect("\(Words.firstSentence) \(Words.onBarLead) [scissors symbol] \(Words.onBarTail)"
                == "Draw a box, or use Search or Scan. Then tap [scissors symbol] to redact.")
        #expect("\(Words.firstSentence) \(Words.foldedLead) [More symbol] \(Words.foldedTail)"
                == "Draw a box, or use Search or Scan. Then tap [More symbol] and choose Redact.")
        #expect(Words.spoken == "Use Search or Scan. Then use Redact.")
        let toolbar = try Self.repoFile("Sources/ResectaApp/Views/DocumentEditorToolbar.swift")
        #expect(toolbar.contains("Button(\"Redact\", systemImage: \"\(Words.redactSymbol)\")"))
        #expect(toolbar.contains("Label(\"More\", systemImage: \"\(Words.moreSymbol)\")"))
        let view = try Self.repoFile("Sources/ResectaApp/Views/FirstDocumentHintView.swift")
        #expect(view.contains("Image(systemName: second.symbol)"))
    }

    // MARK: - The form follows the bar

    @Test("The line names the scissors only where the bar shows it")
    func formFollowsTheBar() {
        var rows = 0
        for size in DynamicTypeSize.allCases {
            rows += 1
            let onBar = EditorToolbarLayout(dynamicTypeSize: size, canUndo: false, canRedo: false).trailing.contains(.redact)
            let second = FirstDocumentHintWords.secondSentence(size)
            #expect(second.symbol == (onBar ? "scissors" : "ellipsis"), "\(size)")
            #expect(second.tail == (onBar ? "to redact." : "and choose Redact."), "\(size)")
        }
        #expect(rows == 12)
        #expect(FirstDocumentHintWords.secondSentence(.large).symbol == "scissors")
        #expect(FirstDocumentHintWords.secondSentence(.accessibility5).symbol == "ellipsis")
    }

    @Test("The line's file holds no copy of the bar's threshold")
    func noSecondThreshold() throws {
        let view = try Self.repoFile("Sources/ResectaApp/Views/FirstDocumentHintView.swift")
        #expect(!view.contains(".xxxLarge"))
        #expect(view.contains("EditorToolbarLayout(dynamicTypeSize:"))
    }

    // MARK: - the test arguments

    @Test("The two test arguments live only in the DEBUG launch handler", arguments: ["--firstDocumentHintFresh", "--firstDocumentHintStored"])
    func testArgumentsOnlyInDebug(_ argument: String) throws {
        let sources = Self.repoRoot().appendingPathComponent("Sources")
        var hits: [String] = []
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        while let url = files?.nextObject() as? URL {
            guard url.pathExtension == "swift",
                  let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let count = text.components(separatedBy: argument).count - 1
            hits += Array(repeating: url.lastPathComponent, count: count)
        }
        #expect(hits == ["ResectaApp.swift"])
        let app = try Self.repoFile("Sources/ResectaApp/App/ResectaApp.swift")
        let at = try #require(app.range(of: argument)).lowerBound
        let before = app[..<at]
        let lastOpen = try #require(before.range(of: "#if DEBUG", options: .backwards)).lowerBound
        if let lastClose = before.range(of: "#endif", options: .backwards) {
            #expect(lastClose.lowerBound < lastOpen)
        }
        #expect(app[at...].contains("#endif"))
    }
}
