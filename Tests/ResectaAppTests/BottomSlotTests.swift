import Testing
import Foundation
@testable import ResectaApp

// The bottom slot above the page bar holds at most one occupant: the first
// that asks, in the order message, first-time line, selection (Add to
// Selection is its adding state), drawing caption. A selection made after
// the message takes the slot from it. Outside editing nothing holds it. The
// widened-box notice is not here: it is the band's fit notice.

@Suite("Bottom slot")
struct BottomSlotTests {

    /// One asker of the slot.
    nonisolated enum Asker: String, CaseIterable, Sendable {
        case message, firstTimeLine, selection, addToSelection, drawingCaption
    }

    /// A set of askers and the occupant they must give.
    nonisolated struct Case: Sendable, CustomTestStringConvertible {
        let askers: [Asker]
        let expected: BottomSlotOccupant?
        var testDescription: String {
            askers.isEmpty ? "nobody asks" : askers.map(\.rawValue).joined(separator: " with ")
        }
    }

    static func occupant(_ askers: [Asker], phase: DocumentState.PhaseKind = .editing,
                         selectionNewer: Bool = false) -> BottomSlotOccupant? {
        DocumentEditorView.bottomSlotOccupant(
            phaseKind: phase,
            messageShowing: askers.contains(.message),
            selectionNewerThanMessage: selectionNewer,
            firstTimeLineDue: askers.contains(.firstTimeLine),
            selectedCount: askers.contains(.selection) ? 2 : 0,
            addToSelection: askers.contains(.addToSelection),
            activeTool: askers.contains(.drawingCaption) ? .rectangle : nil
        )
    }

    nonisolated static let cases: [Case] = [
        Case(askers: [], expected: nil),
        // Each alone.
        Case(askers: [.message], expected: .message),
        Case(askers: [.firstTimeLine], expected: .firstTimeLine),
        Case(askers: [.selection], expected: .selection(adding: false)),
        Case(askers: [.addToSelection], expected: .selection(adding: true)),
        Case(askers: [.drawingCaption], expected: .drawingCaption),
        // A message with anyone.
        Case(askers: [.message, .firstTimeLine], expected: .message),
        Case(askers: [.message, .selection], expected: .message),
        Case(askers: [.message, .addToSelection], expected: .message),
        Case(askers: [.message, .drawingCaption], expected: .message),
        // The first-time line with anyone after it.
        Case(askers: [.firstTimeLine, .selection], expected: .firstTimeLine),
        Case(askers: [.firstTimeLine, .addToSelection], expected: .firstTimeLine),
        Case(askers: [.firstTimeLine, .drawingCaption], expected: .firstTimeLine),
        // A selection: Add to Selection is one occupant in its adding state.
        Case(askers: [.selection, .addToSelection], expected: .selection(adding: true)),
        Case(askers: [.selection, .drawingCaption], expected: .selection(adding: false)),
        Case(askers: [.addToSelection, .drawingCaption], expected: .selection(adding: true)),
    ]

    @Test("One occupant: every pair of askers has one winner, in the slot's order", arguments: cases)
    func oneOccupant(_ c: Case) {
        #expect(Self.occupant(c.askers) == c.expected)
    }

    @Test("Every pair is ruled")
    func everyPairIsRuled() {
        let ruled = Set(Self.cases.map { Set($0.askers) })
        let all = Asker.allCases
        for i in all.indices { for j in all.indices where j > i {
            #expect(ruled.contains([all[i], all[j]]), "\(all[i].rawValue) with \(all[j].rawValue) has a case")
        } }
        for a in all { #expect(ruled.contains([a]), "\(a.rawValue) alone has a case") }
    }

    @Test("A selection made after the message takes the slot; otherwise the message keeps it")
    func selectionNewerThanTheMessage() {
        #expect(Self.occupant([.message, .selection]) == .message)
        #expect(Self.occupant([.message, .addToSelection]) == .message)
        #expect(Self.occupant([.message, .selection], selectionNewer: true) == .selection(adding: false))
        #expect(Self.occupant([.message, .addToSelection], selectionNewer: true) == .selection(adding: true))
        // With no message, "newer" changes nothing.
        #expect(Self.occupant([.selection], selectionNewer: true) == .selection(adding: false))
        #expect(Self.occupant([.drawingCaption], selectionNewer: true) == .drawingCaption)
        #expect(Self.occupant([], selectionNewer: true) == nil)
        // A newer selection does not pass the message when there is none.
        #expect(Self.occupant([.message, .drawingCaption], selectionNewer: true) == .message)
    }

    @Test("Outside editing the slot is empty, whoever asks")
    func emptyOutsideEditing() {
        let phases: [DocumentState.PhaseKind] = [.empty, .importing, .detecting, .redacting,
                                                 .verifying, .verified, .exporting, .failed]
        for phase in phases {
            #expect(Self.occupant(Asker.allCases, phase: phase) == nil, "\(phase)")
            #expect(Self.occupant(Asker.allCases, phase: phase, selectionNewer: true) == nil, "\(phase)")
        }
    }

    @Test("The bar shows while one or more boxes are selected, with no drawing tool and no Add to Selection, while editing")
    func selectionBarHoldsTheSlot() throws {
        func plain(_ count: Int, tool: DocumentEditorView.DrawingTool? = nil, adding: Bool = false) -> BottomSlotOccupant? {
            DocumentEditorView.bottomSlotOccupant(
                phaseKind: .editing, messageShowing: false, selectionNewerThanMessage: false,
                firstTimeLineDue: false, selectedCount: count, addToSelection: adding,
                activeTool: tool)
        }
        #expect(plain(0) == nil)
        #expect(plain(1) == .selection(adding: false))
        #expect(plain(500) == .selection(adding: false))
        #expect(plain(1, adding: true) == .selection(adding: true))
        // The drawing tool's entry clears the selection; with none, its caption.
        #expect(plain(0, tool: .rectangle) == .drawingCaption)
        // The slot draws the bar itself, as `selectionBar`, and it takes touches.
        #expect(DocumentEditorView.bottomSlotDrawsHere(.selection(adding: false)))
        #expect(DocumentEditorView.bottomSlotIdentifier(.selection(adding: false)) == "selectionBar")
        #expect(DocumentEditorView.bottomSlotIdentifier(.selection(adding: true)) == "addModeCapsule")
        // The slot is told the real count.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent(
            "Sources/ResectaApp/Views/DocumentEditorView+Caption.swift"), encoding: .utf8)
        #expect(source.contains("selectedCount: redactionState.selectedRegionIDs.count,"))
        #expect(source.contains("case .selection(adding: false): SelectionBar(toolbar: editorToolbar)"))
    }

    @Test("The bottom slot holds no widened-box notice")
    func noWidenedBoxNotice() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent(
            "Sources/ResectaApp/Views/DocumentEditorView+Caption.swift"), encoding: .utf8)
        #expect(!source.contains("widenedBox"), "the slot's file names no widened box")
        #expect(!source.contains("pageHoldsWidenedBox"), "and does not read the widened pages")
    }

    @Test("The editor passes the first-time line's own rule to the slot")
    func editorPassesTheLine() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent(
            "Sources/ResectaApp/Views/DocumentEditorView+Caption.swift"), encoding: .utf8)
        #expect(source.contains("firstTimeLineDue: firstDocumentHintShows,"))
        #expect(!source.contains("firstTimeLineDue: false"))
        #expect(Self.occupant([.firstTimeLine]) == .firstTimeLine)
    }

    @Test("The slot's measures")
    func measures() {
        // The canvas already ends 8 pt above the page bar's glass (the bar's
        // own spacing): the slot adds no padding under itself.
        #expect(DocumentEditorView.bottomSlotFootPadding == 0)
        #expect(DocumentEditorView.bottomSlotHorizontalPadding == 16)
        #expect(DocumentEditorView.bottomSlotVerticalPadding == 12)
        #expect(DocumentEditorView.bottomSlotCornerRadius == 22)
        #expect(DocumentEditorView.bottomSlotMinimumWidth == 120)
        #expect(DocumentEditorView.bottomSlotMaximumWidth(containerWidth: 402) == 360)
        #expect(DocumentEditorView.bottomSlotMaximumWidth(containerWidth: 375) == 343)
        #expect(DocumentEditorView.bottomSlotMaximumWidth(containerWidth: 320) == 288)
    }
}
