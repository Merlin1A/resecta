import Testing
import Foundation
import CoreGraphics
import SwiftUI
import RedactionEngine
@testable import ResectaApp

// The selection bar in the bottom slot: its count, Duplicate's rule (the
// touch-and-hold menu's), the symbols at the accessibility sizes, the
// capsules' text ceiling, its colours and tappable frames, the limit's
// second line and its clock, the large-content view, and the spoken words.

@MainActor
@Suite("Selection bar")
struct SelectionBarTests {

    private typealias Bar = DocumentEditorView

    private static func box(_ rect: CGRect = CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.05)) -> RedactionRegion {
        RedactionRegion(id: UUID(), normalizedRect: rect, source: .manual)
    }

    private static func repoFile(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private static let barFile = "Sources/ResectaApp/Views/DocumentEditorView+SelectionBar.swift"

    @Test("Duplicate applies to one box that is not a whole page, as in the hold menu")
    func duplicateFollowsTheHoldMenu() {
        let one = Self.box(), two = Self.box(), whole = PageNavigationBar.wholePageRegion()
        let regions: [Int: [RedactionRegion]] = [0: [one, two], 3: [whole]]
        let cases: [(Set<UUID>, RedactionRegion, Bool)] = [
            ([one.id], one, true),
            ([one.id, two.id], one, false),
            ([whole.id], whole, false),
        ]
        for (selection, held, applies) in cases {
            let target = Bar.selectionBarDuplicateTarget(selection: selection, regions: regions)
            #expect((target != nil) == applies)
            let menu = RedactionOverlayView.contextMenuRows(
                for: held, selectedIDs: selection, infoTitle: nil, canSelectAllOnPage: false, showsRationale: false)
            #expect((target != nil) == menu.contains(.duplicate), "the bar and the hold menu agree")
        }
        #expect(Bar.selectionBarDuplicateTarget(selection: [one.id], regions: regions)?.id == one.id)
        #expect(Bar.selectionBarDuplicateTarget(selection: [], regions: regions) == nil)
        #expect(Bar.selectionBarDuplicateTarget(selection: [UUID()], regions: regions) == nil)
    }

    @Test("The count's words")
    func countWords() {
        for n in [1, 2, 99, 500] {
            #expect(Bar.selectionBarCount(n) == "\(n) selected")
            #expect(Bar.selectionBarCount(n) == Bar.addModeCaption(selectedCount: n, accessibilitySize: true))
        }
        #expect(Bar.selectionBarDuplicateWord == "Duplicate")
        #expect(Bar.selectionBarDeleteWord == "Delete")
    }

    @Test("The actions are symbols at every accessibility size")
    func symbolsAtTheAccessibilitySizes() {
        for size: DynamicTypeSize in [.xSmall, .large, .xxxLarge] { #expect(!Bar.selectionBarUsesSymbols(size), "\(size)") }
        for size: DynamicTypeSize in [.accessibility1, .accessibility2, .accessibility3, .accessibility4, .accessibility5] {
            #expect(Bar.selectionBarUsesSymbols(size), "\(size)")
        }
        #expect(Bar.selectionBarDuplicateSymbol == RedactionOverlayView.ContextMenuRow.duplicate.systemImage)
        #expect(Bar.selectionBarDeleteSymbol == RedactionOverlayView.ContextMenuRow.deleteRegion.systemImage)
        #expect(Bar.selectionBarDuplicateSymbol == "plus.square.on.square")
        #expect(Bar.selectionBarDeleteSymbol == "trash")
    }

    @Test("The bar takes the capsules' ceiling")
    func takesTheCeiling() throws {
        #expect(Bar.capsuleTypeSizeCeiling == .accessibility1)
        let source = try Self.repoFile("Sources/ResectaApp/Views/DocumentEditorView+Caption.swift")
        let overlay = try #require(source.range(of: "var captionOverlay: some View {")?.lowerBound)
        let bar = try #require(source.range(of: "SelectionBar(toolbar: editorToolbar)")?.lowerBound)
        let clamp = try #require(source.range(of: ".dynamicTypeSize(...Self.capsuleTypeSizeCeiling)")?.lowerBound)
        #expect(overlay < bar && bar < clamp, "the bar is drawn inside the clamped group")
        #expect(source.components(separatedBy: "SelectionBar(").count - 1 == 1)
    }

    @Test("The bar's colours and its hit frame")
    func coloursAndHitFrame() throws {
        #expect(Bar.selectionBarDeleteWordColour == ResectaTokens.SemanticColor.failText)
        #expect(Bar.selectionBarDeleteSymbolColour == Color.red)
        #expect(Bar.selectionBarDuplicateColour == ResectaTokens.BrandTeal.text)
        #expect(Bar.selectionBarQuietColour == ResectaTokens.SemanticColor.supportText)
        // The drawing reads the constants: each colour named where it is used.
        let source = try Self.repoFile(Self.barFile)
        #expect(source.contains("wordColour: Bar.selectionBarDeleteWordColour, symbolColour: Bar.selectionBarDeleteSymbolColour"))
        #expect(source.contains("wordColour: Bar.selectionBarDuplicateColour, symbolColour: Bar.selectionBarDuplicateColour"))
        #expect(source.components(separatedBy: "Color.red").count - 1 == 1, "the system red only for the trash symbol")
        #expect(!source.contains(".red)"))
        #expect(!source.contains(".secondary"))
        #expect(!source.contains(".tint("))
        // The tappable height is the touch target, the padding computed from it.
        #expect(Bar.selectionBarHitSize == ResectaTokens.TouchTarget.minimum)
        #expect(Bar.selectionBarHitPadding(lineHeight: 20) == (ResectaTokens.TouchTarget.minimum - 20) / 2)
        #expect(Bar.selectionBarHitPadding(lineHeight: 60) == 0)
        // Beside each word, past half the gap: a tap between them lands on one.
        #expect(Bar.selectionBarWordSidePadding * 2 > Bar.selectionBarWordGap)
        #expect(source.contains(".modifier(SelectionBarHitArea(symbols: symbols, wordLineHeight: wordLineHeight))"))
        #expect(source.components(separatedBy: ".modifier(SelectionBarHitArea(").count - 1 == 2)
    }

    @Test("The limit's second line lasts 4 seconds, 5 with VoiceOver, and ends when the selection changes")
    func limitLineClock() {
        let at = Date(timeIntervalSinceReferenceDate: 10_000)
        let kept: Set<UUID> = [UUID(), UUID()]
        let cut = LassoCut(at: at, selection: kept)
        func shows(_ seconds: TimeInterval, _ selection: Set<UUID> = kept, voiceOver: Bool = false, cut: LassoCut? = cut) -> Bool {
            Bar.selectionLimitLineShows(cut: cut, selection: selection, now: at.addingTimeInterval(seconds), voiceOverRunning: voiceOver)
        }
        #expect(shows(0))
        #expect(shows(3.9))
        #expect(!shows(4.0))
        #expect(shows(4.9, voiceOver: true))
        #expect(!shows(5.0, voiceOver: true))
        #expect(!shows(1, cut: nil), "no cut, no line")
        // At 1 s: the selection changed; a delete left nothing selected; a
        // page turn kept only the boxes of the page in view.
        #expect(!shows(1, kept.union([UUID()])))
        #expect(!shows(1, []))
        #expect(!shows(1, [UUID()]))
        #expect(!shows(-1), "nothing before the cut")
        #expect(Bar.selectionLimitLineSeconds(voiceOverRunning: false) == 4)
        #expect(Bar.selectionLimitLineSeconds(voiceOverRunning: true) == 5)
        // A cut through the state, at a known time.
        let state = RedactionState()
        let regions = (0..<501).map { _ in Self.box() }
        state.regions[0] = regions
        state.applyBatch(regions, now: at, barShowing: true)
        #expect(Bar.selectionLimitLineShows(cut: state.lassoCut, selection: state.selectedRegionIDs,
                                            now: at.addingTimeInterval(1), voiceOverRunning: false))
        state.selectedRegionIDs.removeFirst()
        #expect(!Bar.selectionLimitLineShows(cut: state.lassoCut, selection: state.selectedRegionIDs,
                                             now: at.addingTimeInterval(1), voiceOverRunning: false))
    }

    @Test("Each part offers the large-content view")
    func largeContentView() throws {
        let source = try Self.repoFile(Self.barFile)
        #expect(source.components(separatedBy: ".accessibilityShowsLargeContentViewer").count - 1 == 3)
    }

    @Test("Each part speaks its approved words")
    func spokenWords() throws {
        #expect(Bar.selectionBarCountSpoken(1) == "Selection, 1 box")
        #expect(Bar.selectionBarCountSpoken(3) == "Selection, 3 boxes")
        #expect(Bar.selectionBarDuplicateSpoken == "Duplicate Box")
        #expect(Bar.selectionBarDeleteSpoken(1) == "Delete Box")
        #expect(Bar.selectionBarDeleteSpoken(3) == "Delete 3 Boxes")
        let source = try Self.repoFile(Self.barFile)
        #expect(source.contains(".accessibilityLabel(Bar.selectionBarCountSpoken(count))"))
        #expect(source.contains(".accessibilityLabel(Bar.selectionBarDuplicateSpoken)"))
        #expect(source.contains(".accessibilityLabel(Bar.selectionBarDeleteSpoken(count))"))
    }
}
