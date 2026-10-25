import Testing
import Foundation
import CoreGraphics
import RedactionEngine
@testable import ResectaApp

// A result on a page whose text is an invisible layer over a page image
// carries its hidden glyphs' box (`SearchResult.textLayerRect`) beside the ink
// it paints, and the region made from it keeps that box. Apply and the draw
// nudge read coverage on both: a result is covered only when its box is
// covered by painted boxes alone (a hidden glyphs' box is never painted, and on
// a drifted layer it can lie over the next word's ink) and its hidden glyphs'
// box lies wholly inside one painted or stripped box (a part left outside could
// hold a whole glyph). Moving or resizing a region leaves its hidden glyphs'
// box where it is; the hidden glyphs do not move.

@Suite("Hidden glyph box — apply, nudge and edits")
@MainActor
struct HiddenGlyphBoxApplyTests {

    /// The printed ink of a word and its hidden glyphs' box on a drifted
    /// layer: about 4 pt low and 5 pt to the right on a letter page.
    static let ink = CGRect(x: 0.20, y: 0.50, width: 0.10, height: 0.02)
    static let strip = CGRect(x: 0.208, y: 0.495, width: 0.10, height: 0.02)

    static func result(_ paint: CGRect, strip: CGRect?, term: String = "delia",
                       piiCategory: PIICategory? = nil) -> SearchResult {
        SearchResult(pageIndex: 0, normalizedRect: paint, matchedText: term, contextSnippet: "… \(term) …",
                     source: .textLayer, term: term, isSelected: true, piiCategory: piiCategory,
                     textLayerRect: strip)
    }

    static func apply(_ results: [SearchResult], paints: [CGRect] = [], strips: [CGRect] = []) -> PreparedApply {
        prepareApply(selected: results, existingRectsByPage: [0: paints], existingStripRectsByPage: [0: strips],
                     appliedAt: Date(), searchRecord: nil)
    }

    // MARK: - Apply

    @Test("a hit over a box the user drew on its ink applies and keeps its hidden glyphs' box")
    func drawnFirstThenApplied() {
        let drawn = Self.ink.insetBy(dx: -0.002, dy: -0.002)
        let prepared = Self.apply([Self.result(Self.ink, strip: Self.strip)], paints: [drawn])
        #expect(prepared.appliedCount == 1)
        let region = prepared.createdRegions[0]?.first
        #expect(region?.normalizedRect == Self.ink)
        #expect(region?.textLayerRect == Self.strip)
    }

    @Test("a hit under an earlier hit's hidden glyphs' box is still painted")
    func neighbourUnderStripIsPainted() {
        // The first word's hidden glyphs' box runs over the next word's ink.
        let firstStrip = CGRect(x: 0.20, y: 0.50, width: 0.16, height: 0.02)
        let neighbour = CGRect(x: 0.31, y: 0.50, width: 0.04, height: 0.02)
        let neighbourStrip = CGRect(x: 0.318, y: 0.495, width: 0.04, height: 0.02)
        let inOnePass = Self.apply([Self.result(Self.ink, strip: firstStrip),
                                    Self.result(neighbour, strip: neighbourStrip, term: "R.")])
        #expect(inOnePass.appliedCount == 2)
        let later = Self.apply([Self.result(neighbour, strip: neighbourStrip, term: "R.")],
                               paints: [Self.ink], strips: [firstStrip])
        #expect(later.appliedCount == 1)
    }

    @Test("the same hit twice makes one region")
    func repeatedHitIsCovered() {
        let prepared = Self.apply([Self.result(Self.ink, strip: Self.strip), Self.result(Self.ink, strip: Self.strip)])
        #expect(prepared.appliedCount == 1)
        #expect(prepared.skippedOverlaps == 1)
    }

    @Test("a hit whose hidden glyphs' box reaches past the covering box applies")
    func stripPastCoverApplies() {
        // The drawn box covers the ink and most of the hidden glyphs' box, not all of it.
        let drawn = Self.ink.union(Self.strip).insetBy(dx: 0.004, dy: 0)
        let prepared = Self.apply([Self.result(Self.ink, strip: Self.strip)], paints: [drawn])
        #expect(prepared.appliedCount == 1)
        let covering = Self.ink.union(Self.strip)
        #expect(Self.apply([Self.result(Self.ink, strip: Self.strip)], paints: [covering]).appliedCount == 0)
    }

    @Test("a hit with no hidden glyphs' box keeps the coverage rule it had")
    func plainHitUnchanged() {
        let covering = Self.ink.insetBy(dx: -0.001, dy: -0.001)
        #expect(Self.apply([Self.result(Self.ink, strip: nil)], paints: [covering]).appliedCount == 0)
        #expect(Self.apply([Self.result(Self.ink, strip: nil)], strips: [covering]).appliedCount == 1)
        #expect(Self.apply([Self.result(Self.ink, strip: nil)]).createdRegions[0]?.first?.textLayerRect == nil)
    }

    @Test("a hit over a box the user drew on its ink is not marked covered, so its Apply stays live")
    func drawnBoxLeavesTheHitUnmarked() {
        let state = RedactionState()
        state.addRegion(RedactionRegion(id: UUID(), normalizedRect: Self.ink.insetBy(dx: -0.002, dy: -0.002), source: .manual),
                        page: 0, undoManager: nil)
        let drifted = Self.result(Self.ink, strip: Self.strip)
        let plain = Self.result(Self.ink, strip: nil)
        let markers = state.derivedSearchMarkers(for: [drifted, plain])
        #expect(!markers.covered.contains(drifted.id))
        #expect(markers.covered.contains(plain.id))
    }

    // MARK: - The draw nudge

    @Test("the draw nudge offers a hit whose hidden glyphs the drawn box leaves out, and its accept keeps them")
    func nudgeReadsTheHiddenGlyphsBox() {
        let drawn = RedactionRegion(id: UUID(), normalizedRect: Self.ink.insetBy(dx: -0.002, dy: -0.002), source: .manual)
        let hit = Self.result(Self.ink, strip: Self.strip, piiCategory: .name)
        let offered = RedactionState.nearbyUnappliedPIIMatch(
            addedRegion: drawn, page: 0, results: [hit], appliedIDs: [], suppressed: false,
            proximityNormalized: RedactionState.manualDrawNudgeProximityNormalized)
        #expect(offered?.id == hit.id)
        let wide = RedactionRegion(id: UUID(), normalizedRect: Self.ink.union(Self.strip), source: .manual)
        #expect(RedactionState.nearbyUnappliedPIIMatch(
            addedRegion: wide, page: 0, results: [hit], appliedIDs: [], suppressed: false,
            proximityNormalized: RedactionState.manualDrawNudgeProximityNormalized) == nil)
        let state = RedactionState()
        #expect(state.acceptManualDrawNudge(hit, undoManager: nil)?.textLayerRect == Self.strip)
    }

    // MARK: - Edits

    @Test("move and resize leave the hidden glyphs' box in place; delete and undo restore it; a duplicate has none")
    func editsKeepTheHiddenGlyphsBox() throws {
        let state = RedactionState()
        let undo = UndoManager()
        undo.groupsByEvent = false
        let region = RedactionRegion(id: UUID(), normalizedRect: Self.ink, source: .searchMatch(term: "delia"),
                                     textLayerRect: Self.strip)
        state.addRegion(region, page: 0, undoManager: nil)

        #expect(state.moveRegion(region.id, page: 0, newRect: Self.ink.offsetBy(dx: 10.0 / 612.0, dy: 0), undoManager: nil))
        #expect(state.regions[0]?.first?.textLayerRect == Self.strip)
        #expect(state.resizeRegion(region.id, page: 0, newRect: Self.ink.insetBy(dx: -0.01, dy: 0), undoManager: nil))
        #expect(state.regions[0]?.first?.textLayerRect == Self.strip)

        undo.beginUndoGrouping()
        state.removeRegion(region.id, page: 0, undoManager: undo)
        undo.endUndoGrouping()
        #expect(state.regions[0]?.isEmpty ?? true)
        undo.undo()
        #expect(state.regions[0]?.first?.id == region.id)
        #expect(state.regions[0]?.first?.textLayerRect == Self.strip)

        state.duplicateRegion(region.id, page: 0, undoManager: nil)
        let copy = try #require(state.regions[0]?.first { $0.id != region.id })
        #expect(copy.textLayerRect == nil)
    }

    // MARK: - Manual regions carry no hidden glyphs' box

    @Test("the whole-page region carries no hidden glyphs' box")
    func wholePageRegionHasNone() {
        #expect(PageNavigationBar.wholePageRegion().textLayerRect == nil)
    }

    /// The canvas draw builds its region inside a gesture handler, so its
    /// constructor is read from the source: the manual-terms capture models
    /// a `.manual` region's one rect, and holds only while no `.manual`
    /// region is made with a hidden glyphs' box.
    @Test("no manual-region constructor in the app passes a hidden glyphs' box")
    func manualConstructorsPassNone() throws {
        let root = URL(fileURLWithPath: "\(#filePath)").deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let sources = root.appendingPathComponent("Sources/ResectaApp")
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        var manualCalls = 0
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            let calls = text.components(separatedBy: "RedactionRegion(").dropFirst()
                .map { String($0.prefix(240)) }.filter { $0.contains("source: .manual") }
            manualCalls += calls.count
            #expect(!calls.contains { $0.contains("textLayerRect") }, "\(file.lastPathComponent)")
        }
        // The canvas draw, the whole-page region and Duplicate at least.
        #expect(manualCalls >= 3, "the scan found \(manualCalls) manual-region constructors")
    }
}
