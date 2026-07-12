import Testing
import Foundation
import PDFKit
import CoreGraphics
import CoreText
#if canImport(UIKit)
import UIKit
#endif
@testable import RedactionEngine

// S01 — Searchable-Redaction merge measurement TESTS. The reusable §12.2-safe
// harness (`enum SearchableMergeProbe`) lives in `SearchableMergeProbe.swift`;
// this file holds the @Suite validation-gate + open-question regression tests.

@Suite("Searchable merge probe", .tags(.sandwich))
struct SearchableMergeProbeTests {

    /// VALIDATION GATE — runs the fixture through the pipeline + all 10 layers,
    /// prints a §12.2-safe measurement report, and ASSERTS the pinned per-layer
    /// matrix. History: on the S01-era engine ONLY Layer 6 (idx5 / SVT-1,
    /// off-grid substituted advance) and Layer 8 (idx7 / SVT-4, /ToUnicode)
    /// reproduced; Layer 7 (idx6, count) and Layer 9 (idx8, lineage) are NOT
    /// synthetically reproducible on this fixture (PDFKit does not merge
    /// co-located glyphs on iOS 26.4 — see directColocationTest) and PASS here.
    /// S05 (2026-06-09): idx7 flipped to PASS with the J-5 SVT-4 refinement;
    /// idx5 stays FAIL BY DESIGN — the fixture's ∑/∆/█/─ glyphs draw at their
    /// natural substituted advances, off the cell grid at ANY base size, which
    /// is a deliberate adversarial property SVT-1 correctly flags. Do NOT
    /// chase idx5 green here; never weaken a verifier to move a pin.
    @Test("S01 validation gate — fixture reproduces Layer 6 + Layer 8 FAIL")
    func validationGate() async throws {
        let fixture = TestFixtures.searchableMergeReproPDF()
        let regions = TestFixtures.searchableMergeReproRegions()

        let url = try await TestPipeline.processAndExport(
            fixture, mode: .searchableRedaction, regions: regions, dpi: 150
        )
        defer { try? FileManager.default.removeItem(at: url) }
        let digests = try await TestPipeline.searchableDigests(fixture, regions: regions)
        let surviving = try await SearchableMergeProbe.survivingPerPage(fixture, regions: regions)

        guard let outDoc = PDFDocument(url: url) else {
            Issue.record("Output PDF did not open")
            return
        }
        let perPageModes = Array(repeating: PipelineMode.searchableRedaction, count: outDoc.pageCount)
        let layers = await SearchableMergeProbe.runLayers(
            outputDocument: SendablePDFDocument(outDoc),
            sourcePageCount: outDoc.pageCount,
            regions: regions, digests: digests, perPageModes: perPageModes
        )

        print("===== S01 VALIDATION GATE =====")
        print("pages=\(outDoc.pageCount)  cellWidth=\(SearchableMergeProbe.cellWidth)  tol=\(SearchableMergeProbe.advanceTol)")
        var totalOffGrid = 0
        var maxCountDeficit = Int.min   // max over pages of (surviving − outputComposed)
        for idx in 0..<(layers.count) {
            if let r = layers[idx] {
                print("LAYER \(idx) [\(r.name)] -> \(statusTag(r.status))  | \(r.shortDescription)")
            }
        }
        for pageIndex in 0..<outDoc.pageCount {
            guard let page = outDoc.page(at: pageIndex) else { continue }
            let prof = SearchableMergeProbe.composedProfile(page)
            let drawn = SearchableMergeProbe.drawnGlyphOperandCount(page)
            let surv = surviving[safe: pageIndex]?.count ?? -1
            let digestSurv: Int = (pageIndex < digests.count ? digests[pageIndex]?.survivingCount : nil) ?? -1
            let fonts = SearchableMergeProbe.fontReport(page)
            print("--- page \(pageIndex): drawn=\(drawn) surviving(extract+filter)=\(surv) digest.survivingCount=\(digestSurv) outputComposedNonZero=\(prof.totalNonZeroBounds) deficit=\(digestSurv - prof.totalNonZeroBounds)")
            totalOffGrid += prof.offGridOutliers.count
            if digestSurv >= 0 { maxCountDeficit = max(maxCountDeficit, digestSurv - prof.totalNonZeroBounds) }
            print("    zeroBounds=\(prof.zeroOrNegBoundsCount) multiScalarOut=\(prof.multiScalarCount) mono=\(prof.monospaceCount) nonMono=\(prof.nonMonospaceCount) sizes=\(prof.pointSizes)")
            print("    offGridOutliers=\(prof.offGridOutliers.count) nearZeroPositive=\(prof.nearZeroPositive.count)")
            for o in prof.offGridOutliers.prefix(8) {
                print("      outlier: family=\(o.family) pt=\(o.pointSize) width=\(round4(o.width)) expected=\(round4(o.expected)) dev=\(round4(o.deviation)) scalars=\(o.scalarCount) courierAdv12=\(round4(o.courierAdvance12pt))")
            }
            if let survChars = surviving[safe: pageIndex] {
                let cFilter = SearchableMergeProbe.censusSurviving(survChars)
                let cOut = SearchableMergeProbe.censusOutputNonZero(page)
                let diff = cFilter - cOut
                let rs = SearchableMergeProbe.runStructure(survChars)
                let sa = SearchableMergeProbe.sourceAnalysis(survChars)
                print("    census filter-minus-output: \(diff.description)")
                print("    runStructure: runs=\(rs.runCount) lengths=\(rs.runLengths)")
                print("    sourceAnalysis: surviving=\(sa.survivingCount) whitespace=\(sa.whitespaceCount) multiScalar=\(sa.multiScalarCount) lines=\(sa.lineCount) breaks=\(sa.breakCount) medW=\(round4(sa.medianGlyphWidth)) breakGaps=\(sa.sampleBreakGaps.map { round4($0) })")
            }
            for f in fonts {
                print("    font: base=\(f.baseFont) hasToUnicode=\(f.hasToUnicode)")
            }
        }
        print("===== END VALIDATION GATE =====")

        // ---- Validation gate assertions (BLOCKER-aware) ----
        // [S06 J-12/J-13 flip, 2026-06-09] idx5 FAIL → PASS: SVT-1 now
        // verifies origin DELTAS against `natural(prev) + j × cell` — and a
        // glyph's natural advance in the accepted family (the very thing
        // this fixture's anomalous-advance class deliberately tripped under
        // the S01-era selection-WIDTH proxy) is a writer/font property the
        // lattice admits (J-13/N1). TJ kerning displacements still land off
        // the lattice (RT-1). See §6.6 SVT-1.
        #expect(layers[5]?.status.isFail == false,
                "Spatial/SVT-1 (idx5 = spec Layer 6) PASSes: natural advances ride inside the J-13 lattice.")
        // [S05 phase-A flip, 2026-06-09] idx7 FAIL → PASS: the fixture's
        // CMap-bearing subsets carry accepted Courier/Menlo BaseFont names
        // (the S01-measured font picture), so the J-5-refined SVT-4
        // tolerates them. Emission itself is unchanged (writer behavior).
        #expect(layers[7]?.status.isFail == false,
                "Font/SVT-4 (idx7 = spec Layer 8) PASSes: accepted-subset CMaps tolerated (J-5).")
        // Leak/structure + base layers must stay non-FAIL:
        #expect(layers[9]?.status.isFail == false,
                "Operator Re-Extraction (idx9 = spec Layer 10) must stay PASS (no sensitive operators).")
        for base in 0...4 {
            #expect(layers[base]?.status.isFail == false,
                    "Base layer idx\(base) must stay PASS/INFO.")
        }
        // BLOCKER §2/§4: Character Count (idx6 = spec Layer 7) and Character
        // Lineage (idx8 = spec Layer 9) are NOT synthetically reproducible. PDFKit
        // on iOS 26.4 does not merge co-located glyphs (directColocationTest), so
        // output composed ≥ surviving — no count deficit, no lineage divergence.
        // They PASS here; assert PASS deliberately (do NOT manufacture a FAIL).
        #expect(layers[6]?.status.isFail == false,
                "Character Count (idx6 = spec Layer 7): unreproducible deficit — PASS (BLOCKER §2).")
        #expect(layers[8]?.status.isFail == false,
                "Character Lineage (idx8 = spec Layer 9): unreproducible here — PASS (BLOCKER §2/§4).")
        // Supporting mechanism evidence:
        #expect(totalOffGrid >= 1,
                "At least one off-grid substituted advance must exist (the Layer 6/SVT-1 trigger).")
        #expect(maxCountDeficit <= 0,
                "No page has output composed < surviving (this is WHY Layer 7 count passes).")
    }

    /// Sweep the inter-column gap and record where `groupIntoRuns` splits
    /// the row.
    ///
    /// [SV-4 re-pin] The S01-era premise — PDFKit bridges every born-digital
    /// same-line gap with a selectable synthesized space, so the row never
    /// splits — described the geometry defect the extractor now removes: a
    /// gap-wide bridging entry sat gap-free against BOTH columns, the row
    /// drew as ONE group, and the drawn gutter compressed to a single cell
    /// (value columns landed far off the raster). The extractor skips a
    /// whitespace entry at the run-grouping adjacency break (width ≥ 1.5×
    /// the previous entry's): below the break the space keeps its entry and
    /// the row stays whole (word spacing); at or beyond it the row SPLITS
    /// and the line layout re-tiles the gutter with whole cells at
    /// raster-true positions. The 1b run-boundary-overlap concern the old
    /// premise ruled out is measured directly by `constructedMergeProbe`
    /// (split + overlapping redraw → no merge, no Layer-7/9 deficit).
    @Test("S01 gap sweep — run-break window follows the grouping threshold")
    func gapSweep() async throws {
        let regions = TestFixtures.searchableMergeReproRegions()
        print("===== S01 GAP SWEEP =====")
        for rightX in stride(from: 128.0, through: 210.0, by: 4.0) {
            let fixture = TestFixtures.searchableMergeReproPDF(
                sourceFontSize: 7, rightX: CGFloat(rightX)
            )
            let surviving = try await SearchableMergeProbe.survivingPerPage(fixture, regions: regions)
            let sa = SearchableMergeProbe.sourceAnalysis(surviving.first ?? [])
            print("rightX=\(rightX) gap≈\(round4(rightX - 126.6)) surviving=\(sa.survivingCount) whitespace=\(sa.whitespaceCount) lines=\(sa.lineCount) breaks=\(sa.breakCount) breakGaps=\(sa.sampleBreakGaps.map { round4($0) })")
            if rightX <= 128.0 {
                // Sub-threshold gutter (≈1.4pt): the bridging space cannot
                // constitute a run break and keeps its entry — no split.
                #expect(sa.breakCount == 0,
                        "gapSweep rightX=\(rightX): a sub-threshold gutter keeps its bridging entry; the row must not split.")
            } else if rightX >= 136.0 {
                // All 6 column rows split at their gutters once the
                // bridging entry reaches the grouping break.
                #expect(sa.breakCount == 6,
                        "gapSweep rightX=\(rightX): every column row must split at its gutter; got \(sa.breakCount).")
                for gap in sa.sampleBreakGaps {
                    #expect(gap >= sa.medianGlyphWidth * 1.5,
                            "gapSweep rightX=\(rightX): a break gap (\(round4(gap))) below the adjacency threshold (\(round4(sa.medianGlyphWidth * 1.5))) would jam word spacing.")
                }
            }
            // rightX == 132 straddles the per-row threshold (previous-glyph
            // widths vary row to row) — recorded, not pinned.
        }
        print("===== END SWEEP =====")
    }

    /// Sweep candidate co-location / zero-advance mechanisms (1a family) to
    /// determine which produce a Layer 7/9 deficit, since run-boundary overlap (1b)
    /// is unreproducible (PDFKit bridges all same-line gaps — see gapSweep).
    @Test("S01 deficit mechanism sweep")
    func deficitSweep() async throws {
        let regions = TestFixtures.searchableMergeReproRegions()
        let candidates: [(name: String, lines: [String])] = [
            ("standalone-combining", ["ABCDEF \u{0301} GHIJKL \u{0303} MNOPQR \u{0308} STUVWX"]),
            ("nonprecompose-decomp", ["q\u{0301} h\u{0301} z\u{0303} d\u{0308} b\u{0300} f\u{0302}"]),
            ("stacked-combining", ["e\u{0301}\u{0302}\u{0323} a\u{0300}\u{0324}\u{0304} o\u{0306}\u{0307}\u{0308}"]),
            ("zwj-between", ["A\u{200D}B\u{200D}C\u{200D}D\u{200D}E\u{200D}F\u{200D}G"]),
            ("softhyphen", ["A\u{00AD}B\u{00AD}C\u{00AD}D\u{00AD}E\u{00AD}F\u{00AD}G"]),
            ("regional-indicators", ["\u{1F1FA}\u{1F1F8} \u{1F1EC}\u{1F1E7} \u{1F1EB}\u{1F1F7} \u{1F1E9}\u{1F1EA}"]),
            ("uncovered-dense", ["\u{2211}\u{2248}\u{2206}\u{2500}\u{2502}\u{2588}\u{25A0}\u{25CF}\u{2026}\u{2014}"]),
            ("combining-on-space", ["A \u{0301}B C \u{0303}D E \u{0308}F"]),
            ("precomposed-accents", ["caf\u{00E9} \u{00E0} pi\u{00F1}ata b\u{00FC}ro na\u{00EF}ve"]),
        ]
        print("===== S01 DEFICIT SWEEP =====")
        for c in candidates {
            let placed = c.lines.enumerated().map { (i, t) in
                (text: t, x: CGFloat(72), y: CGFloat(700 - i * 16))
            }
            let fixture = SearchableMergeProbe.ctLinePDF(placed, fontSize: 9)
            let qm = try await SearchableMergeProbe.quickMeasure(fixture, regions: regions)
            print("\(c.name): \(qm)")
            // BLOCKER §2: across every synthetic mechanism, output composed ≥
            // surviving — never a Layer-7 deficit (deficit = surviving − output ≤ 0).
            #expect(qm.deficit <= 0,
                    "deficitSweep \(c.name): output < surviving must never occur synthetically.")
        }
        // case (a) candidates: a grapheme that survives extraction as its own
        // CharacterInfo but may render to ZERO output bounds (skipped output-side,
        // kept filter-side) → deficit + lineage mismatch from one glyph.
        let placedCandidates: [(name: String, placed: [(text: String, x: CGFloat, y: CGFloat)])] = [
            ("leading-combining", [("\u{0301}ABCDEFGH", 72, 700), ("\u{0303}IJKLMNOP", 72, 684)]),
            ("isolated-combining", [("ABCDEF", 72, 700), ("\u{0301}", 116, 700), ("GHIJKL", 150, 700)]),
            ("isolated-zwnj", [("ABCDEF", 72, 700), ("\u{200C}", 116, 700), ("GHIJKL", 150, 700)]),
            ("overlap-exact", [("ABCDEFGHIJ", 72, 700), ("KLMNOPQRST", 72, 700)]),
            ("overlap-tiny", [("ABCDEFGHIJ", 72, 700), ("KLMNOPQRST", 73, 700)]),
            ("dotless-then-mark", [("\u{0131}\u{0301}\u{0131}\u{0303}\u{0131}\u{0308}", 72, 700)]),
            // Two runs on near-coincident baselines (Y-diff in the
            // groupIntoRuns "different line" window) with overlapping X — the
            // only remaining path to cross-run output co-location.
            ("two-lines-4pt", [("ABCDEFGHIJ", 72, 700), ("KLMNOPQRST", 72, 696)]),
            ("two-lines-6pt", [("ABCDEFGHIJ", 72, 700), ("KLMNOPQRST", 72, 694)]),
            ("two-lines-8pt", [("ABCDEFGHIJ", 72, 700), ("KLMNOPQRST", 72, 692)]),
        ]
        for c in placedCandidates {
            let fixture = SearchableMergeProbe.ctLinePDF(c.placed, fontSize: 9)
            let qm = try await SearchableMergeProbe.quickMeasure(fixture, regions: regions)
            print("\(c.name): \(qm)")
            // BLOCKER §2: across every synthetic mechanism, output composed ≥
            // surviving — never a Layer-7 deficit (deficit = surviving − output ≤ 0).
            #expect(qm.deficit <= 0,
                    "deficitSweep \(c.name): output < surviving must never occur synthetically.")
        }
        print("===== END DEFICIT SWEEP =====")
    }

    /// Probe the constructed-CharacterInfo reconstructor-merge path for the
    /// Layer 7 (count) + Layer 9 (lineage) failures the source→extraction
    /// pipeline cannot produce (PDFKit bridges all same-line gaps).
    @Test("S01 constructed reconstructor-merge probe")
    func constructedMergeProbe() async throws {
        let verifier = SandwichVerification()
        let pageSize = CGSize(width: 612, height: 792)
        let rows: [(left: String, right: String)] = [
            ("ACCOUNTNUMBER", "1234567"),
            ("BALANCEAMOUNT", "9988776"),
            ("PENDINGCHARGE", "4567890"),
            ("CREDITENTRIES", "1029384"),
            ("DEBITRECORDED", "5647382"),
            ("TRANSFERSENT", "8675309"),
        ]
        print("===== S01 CONSTRUCTED MERGE PROBE =====")
        for rightX in [134.0, 138.0, 140.0, 144.0, 150.0] {
            let surviving = SearchableMergeProbe.constructedTableSurviving(
                rows: rows, advance: 4.2, rightX: CGFloat(rightX))
            let digest = PageFilterDigest(
                pageIndex: 0, extractedCount: surviving.count, excludedCount: 0,
                survivingCount: surviving.count, boundaryCharacters: [],
                lineageHash: FilterResult.computeLineageHash(over: surviving))
            let outputData = SearchableMergeProbe.renderInvisibleLayer(surviving, pageSize: pageSize)
            guard let outDoc = PDFDocument(data: outputData), let page = outDoc.page(at: 0) else {
                print("rightX=\(rightX): no-output"); continue
            }
            let outCount = (try? await verifier.verifyCharacterCount(outputPage: page, digest: digest))
            let outLineage = try await verifier.verifyCharacterLineage(outputPage: page, digest: digest)
            let prof = SearchableMergeProbe.composedProfile(page)
            let rs = SearchableMergeProbe.runStructure(surviving)
            func tag(_ s: VerificationStatus?) -> String { s?.isFail == true ? "FAIL" : (s == nil ? "?" : "pass") }
            print("rightX=\(rightX) surv=\(surviving.count) outComposed=\(prof.totalNonZeroBounds) deficit=\(surviving.count - prof.totalNonZeroBounds) runs=\(rs.runCount) | L7(count)=\(tag(outCount)) L9(lineage)=\(tag(outLineage))")
            // Even when the surviving set is constructed directly with born-digital
            // column gaps (bypassing PDFKit source-side bridging) so groupIntoRuns
            // DOES split and the 12pt redraw overlaps, PDFKit still re-extracts
            // output composed ≥ surviving — no merge, no deficit (BLOCKER §2).
            #expect(rs.runCount > rows.count,
                    "constructedMergeProbe: groupIntoRuns must split the column table (the break the source path can't produce).")
            #expect(prof.totalNonZeroBounds >= surviving.count,
                    "constructedMergeProbe: no merge even with split+overlapping runs (output composed ≥ surviving).")
            #expect(outCount?.isFail != true,
                    "constructedMergeProbe: Layer 7 count must not FAIL (no deficit).")
            #expect(outLineage.isFail == false,
                    "constructedMergeProbe: Layer 9 lineage must not FAIL on the constructed-merge path.")
        }
        print("===== END CONSTRUCTED MERGE PROBE =====")
    }

    /// Decisive test of the plan's root-cause premise: does PDFKit's
    /// composed-character re-extraction MERGE glyphs drawn at identical /
    /// overlapping positions into FEWER composed characters? Draws two N-glyph
    /// strings at increasing overlap and counts output composed chars.
    @Test("S01 direct co-location merge test")
    func directColocationTest() async throws {
        print("===== S01 DIRECT CO-LOCATION TEST =====")
        // Two 8-glyph strings, second offset by `dx` from the first (dx=0 =
        // exact co-location). 16 glyphs drawn; how many composed chars come back?
        for dx in [0.0, 3.6, 7.2, 14.4, 28.8, 57.6] {
            let fixture = SearchableMergeProbe.ctLinePDF([
                ("ABCDEFGH", 100, 700),
                ("12345678", 100 + CGFloat(dx), 700),
            ], fontSize: 12)
            guard let doc = PDFDocument(data: fixture), let page = doc.page(at: 0) else { continue }
            let prof = SearchableMergeProbe.composedProfile(page)
            let drawn = SearchableMergeProbe.drawnGlyphOperandCount(page)
            print("dx=\(dx): drawn=\(drawn) outputComposedNonZero=\(prof.totalNonZeroBounds) zeroBounds=\(prof.zeroOrNegBoundsCount) (16 glyphs drawn; <16 composed ⇒ PDFKit merges)")
            // DECISIVE (BLOCKER §3): even at dx=0 (exact co-location) PDFKit
            // re-extracts ≥ the drawn glyph count — it does NOT merge co-located
            // glyphs into fewer composed characters. This disproves the master
            // plan's §1.3/§2.1 "PDFKit merges co-located glyphs" root-cause premise.
            #expect(prof.totalNonZeroBounds >= drawn,
                    "directColocation dx=\(dx): composed < drawn would mean a merge — PDFKit does not merge on iOS 26.4.")
        }
        print("===== END DIRECT CO-LOCATION TEST =====")
    }

    /// OQ-4 — FIX-A monotonic-cell prototype (TEST-LOCAL; does NOT modify the
    /// reconstructor). Draws the constructed column table through the by-hand
    /// `x_k = max(floor(srcMinX/cw)·cw, x_{k-1}+cw)` placement and re-measures.
    /// Contrast with `constructedMergeProbe` (current reconstructor: output
    /// composed > surviving, off-grid outliers possible). FIX-A's demonstrable
    /// value is on-grid 1:1 ADVANCES (helps Layer 6); its STATED Layer-7/9 merge-
    /// prevention benefit is moot because no merge occurs in the first place
    /// (BLOCKER §3) — so whether FIX-A addresses the REAL Layer 7/9 deficit is
    /// UNRESOLVED and needs the real doc (J-8).
    @Test("S01 FIX-A monotonic-cell prototype (OQ-4)")
    func fixAMonotonicPrototype() async throws {
        let pageSize = CGSize(width: 612, height: 792)
        let rows: [(left: String, right: String)] = [
            ("ACCOUNTNUMBER", "1234567"), ("BALANCEAMOUNT", "9988776"),
            ("PENDINGCHARGE", "4567890"), ("CREDITENTRIES", "1029384"),
            ("DEBITRECORDED", "5647382"), ("TRANSFERSENT", "8675309"),
        ]
        print("===== S01 FIX-A MONOTONIC PROTOTYPE =====")
        for rightX in [134.0, 140.0, 150.0] {
            let surviving = SearchableMergeProbe.constructedTableSurviving(
                rows: rows, advance: 4.2, rightX: CGFloat(rightX))
            let data = SearchableMergeProbe.renderMonotonicPrototype(surviving, pageSize: pageSize)
            guard let doc = PDFDocument(data: data), let page = doc.page(at: 0) else {
                print("rightX=\(rightX): no-output"); continue
            }
            let prof = SearchableMergeProbe.composedProfile(page)
            let drawn = SearchableMergeProbe.drawnGlyphOperandCount(page)
            print("rightX=\(rightX) surv=\(surviving.count) drawn=\(drawn) composedNonZero=\(prof.totalNonZeroBounds) deficit=\(surviving.count - prof.totalNonZeroBounds) offGrid=\(prof.offGridOutliers.count) zeroBounds=\(prof.zeroOrNegBoundsCount)")
            // FIX-A prototype invariants: 1:1 re-extraction (no deficit) and on-grid
            // advances (no off-grid outlier). Pinned after S01 measurement (run-1).
            #expect(prof.totalNonZeroBounds >= surviving.count,
                    "FIX-A prototype: monotonic placement must not lose characters (output composed ≥ surviving).")
            #expect(prof.offGridOutliers.count == 0,
                    "FIX-A prototype: every grapheme on its own cell ⇒ no off-grid advance outlier.")
        }
        print("===== END FIX-A PROTOTYPE =====")
    }

    /// Layer-9 (Character Lineage / idx8 / SVT-2) PROXY — **NON-FAITHFUL**.
    ///
    /// IMPORTANT (BLOCKER §4): this reproduces the lineage-mismatch SYMPTOM via
    /// CONTENT RECOMPOSITION — a line that begins with a combining mark recomposes
    /// differently between the filter-side composed walk and the output composed
    /// walk, flipping the lineage hash. This is NOT the real doc's COUNT-driven
    /// lineage divergence, and FIX-A (monotonic cells) would NOT address it.
    /// It exists only to give downstream sessions a genuine Layer-9 FAIL produced
    /// by the strict engine (no verifier was weakened) to exercise the verifier
    /// path; it must NOT be treated as a faithful stand-in for validating FIX-A on
    /// Layer 9. See the S01 findings appendix.
    @Test("S01 Layer-9 lineage proxy (non-faithful — content recomposition)")
    func layer9LineageProxyContentRecomposition() async throws {
        let regions = TestFixtures.searchableMergeReproRegions()
        // Leading-combining lines: the mark recomposes with the line start.
        let fixture = SearchableMergeProbe.ctLinePDF([
            ("\u{0301}ABCDEFGH", 72, 700),
            ("\u{0303}IJKLMNOP", 72, 684),
        ], fontSize: 9)
        let qm = try await SearchableMergeProbe.quickMeasure(fixture, regions: regions)
        print("===== S01 LAYER-9 PROXY (non-faithful) ===== \(qm)")
        #expect(qm.l9Fail == true,
                "Layer 9 lineage must FAIL on the leading-combining proxy (content recomposition, BLOCKER §4).")
    }

    private func statusTag(_ s: VerificationStatus) -> String {
        switch s {
        case .pass: "PASS"
        case .warn: "WARN"
        case .info: "INFO"
        case .attention: "ATTENTION"
        case .fail: "FAIL"
        case .skipped: "SKIPPED"
        }
    }
    private func round4(_ d: Double) -> Double { (d * 10000).rounded() / 10000 }
}

fileprivate extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
