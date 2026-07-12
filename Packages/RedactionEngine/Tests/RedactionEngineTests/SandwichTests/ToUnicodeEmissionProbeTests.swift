import Testing
import Foundation
import PDFKit
import CoreGraphics
import CoreText
@testable import RedactionEngine

// S01 — EXP-E6.1 / OQ-3: when does CGPDFContext emit a /ToUnicode CMap, and
// does an EXPLICITLY-created Menlo avoid it? This selects the Layer-8 fix
// branch the master plan (00-PLAN.md §4.2/§4.3) defers to S01:
//
//   • Branch A — explicit accepted fallback does NOT emit /ToUnicode → ship the
//     fix in the reconstructor (FIX-B: draw Courier-uncovered graphemes in an
//     explicitly-created Menlo), SVT-4 + RT-4 untouched. PREFERRED.
//   • Branch B — every non-Courier subset carries /ToUnicode regardless → the
//     reconstructor route cannot avoid the CMap; resolve via a maintainer-gated SVT-4
//     verifier refinement (FIX-B′, J-5/J-6) + RT-4 re-pointing.
//
// ARCH §12.2: emit only font *resource* names, booleans, counts, and advances
// in points — never document content. The probe strings are synthetic.

// MARK: - /ToUnicode emission probe builders (CGPDFContext + CTLineDraw)

enum ToUnicodeProbe {

    /// Draw each entry's text with its OWN CTFont via CTLineDraw into a single-
    /// page CGPDFContext (the same writer the reconstructor uses). Returns PDF
    /// data. This is what lets us compare explicit-Courier vs explicit-Menlo vs
    /// auto-substituted font emission.
    static func pdf(_ entries: [(text: String, x: CGFloat, y: CGFloat, font: CTFont)]) -> Data {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tuprobe_\(UUID().uuidString).pdf")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { return Data() }
        ctx.beginPDFPage(nil)
        for e in entries {
            let attrs: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): e.font
            ]
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(string: e.text, attributes: attrs))
            ctx.textPosition = CGPoint(x: e.x, y: e.y)
            CTLineDraw(line, ctx)
        }
        ctx.endPDFPage()
        ctx.closePDF()
        defer { try? FileManager.default.removeItem(at: url) }
        return (try? Data(contentsOf: url)) ?? Data()
    }

    /// FIX-B segmentation: per grapheme, draw in `courier` when Courier covers
    /// it, otherwise in an EXPLICITLY-created `menlo` — never letting CoreText
    /// auto-substitute. Returns per-grapheme draw entries on one line.
    static func segmentedEntries(
        _ s: String, x0: CGFloat, y: CGFloat,
        courier: CTFont, menlo: CTFont, advance: CGFloat
    ) -> [(text: String, x: CGFloat, y: CGFloat, font: CTFont)] {
        var out: [(text: String, x: CGFloat, y: CGFloat, font: CTFont)] = []
        var x = x0
        for g in s {
            let grapheme = String(g)
            let utf16 = Array(grapheme.utf16)
            var glyphs = [CGGlyph](repeating: 0, count: max(utf16.count, 1))
            let covered = !utf16.isEmpty
                && CTFontGetGlyphsForCharacters(courier, utf16, &glyphs, utf16.count)
            out.append((text: grapheme, x: x, y: y, font: covered ? courier : menlo))
            x += advance
        }
        return out
    }

    /// Open `data` and return its first page's font *resource* report.
    static func report(_ data: Data) -> [FontResourceInfo] {
        guard let doc = PDFDocument(data: data), let page = doc.page(at: 0) else { return [] }
        return SearchableMergeProbe.fontReport(page)
    }
}

// MARK: - EXP-E6.1 measurement

@Suite("ToUnicode emission probe", .tags(.sandwich))
struct ToUnicodeEmissionProbeTests {

    @Test("EXP-E6.1 — /ToUnicode emission by font choice (OQ-3)")
    func toUnicodeEmissionByFontChoice() async throws {
        let courier = CTFontCreateWithName("Courier" as CFString, 12.0, nil)
        let menlo = CTFontCreateWithName("Menlo-Regular" as CFString, 12.0, nil)
        let ascii = "ABCDEFGHIJ KLMNOP 0123456789"                 // Courier-covered
        // Precomposed Latin-1 accents (é à ñ ü). Per CTFontGetGlyphsForCharacters
        // these are actually COURIER-covered on iOS 26.4, so a coverage-aware
        // segmentation keeps them in Courier (no substitution) — confirming Latin-1
        // is NOT the /ToUnicode source; the bug comes from glyphs covered by neither.
        let courierCoveredLatin1 = "caf\u{00E9} \u{00E0}\u{00F1}\u{00FC}"
        // Covered by NEITHER accepted family (math + box-drawing: ∑ ∆ █ ─).
        let neitherCovered = "\u{2211}\u{2206}\u{2588}\u{2500}"

        func anyToUnicode(_ infos: [FontResourceInfo]) -> Bool { infos.contains { $0.hasToUnicode } }
        func dump(_ label: String, _ infos: [FontResourceInfo]) {
            print("\(label): fonts=\(infos.count) anyToUnicode=\(anyToUnicode(infos))")
            for f in infos { print("    base=\(f.baseFont) hasToUnicode=\(f.hasToUnicode)") }
        }

        // Build each scenario's PDF once (reused for font report + SVT-4 verdict).
        let d1 = ToUnicodeProbe.pdf([(ascii, 72, 700, courier)])
        let d2 = ToUnicodeProbe.pdf([(ascii, 72, 700, menlo)])
        let d3 = ToUnicodeProbe.pdf([(courierCoveredLatin1 + " " + neitherCovered, 72, 700, courier)])
        let seg4 = ToUnicodeProbe.segmentedEntries(
            ascii + " " + courierCoveredLatin1, x0: 72, y: 700,
            courier: courier, menlo: menlo, advance: 7.2)
        let d4 = ToUnicodeProbe.pdf(seg4)
        let seg5 = ToUnicodeProbe.segmentedEntries(
            ascii + " " + neitherCovered, x0: 72, y: 700,
            courier: courier, menlo: menlo, advance: 7.2)
        let d5 = ToUnicodeProbe.pdf(seg5)

        let s1 = ToUnicodeProbe.report(d1)
        let s2 = ToUnicodeProbe.report(d2)
        let s3 = ToUnicodeProbe.report(d3)
        let s4 = ToUnicodeProbe.report(d4)
        let s5 = ToUnicodeProbe.report(d5)

        print("===== EXP-E6.1 /ToUnicode EMISSION PROBE =====")
        dump("(1) explicit Courier + ASCII", s1)
        dump("(2) explicit Menlo + ASCII   [Branch A/B discriminator]", s2)
        dump("(3) auto-substituted (single Courier CTLine; CoreText substitutes)", s3)
        dump("(4) coverage-aware seg of Latin-1 accents (Courier covers → stay Courier)", s4)
        dump("(5) coverage-aware seg of neither-covered glyphs (residual)", s5)

        // Menlo advance vs SVT-1 tolerance (Branch-A viability for Layer 6).
        let menloAdvance = SearchableMergeProbe.courierHorizontalAdvance(
            of: "M", font: menlo)
        let expected = Double(SearchableMergeProbe.courierPerPt) * 12.0
        let menloWithinTol = abs(menloAdvance - expected) <= Double(SearchableMergeProbe.advanceTol)
        print("Menlo 'M' advance@12pt=\(round4(menloAdvance)) expected=\(round4(expected)) "
            + "withinSVT1Tol(0.25)=\(menloWithinTol)")

        // SVT-4 verifier verdict (the real Layer-8 check) on each scenario.
        let verifier = SandwichVerification()
        func svt4Fail(_ data: Data) async throws -> Bool {
            guard let doc = PDFDocument(data: data), let page = doc.page(at: 0) else { return false }
            return try await verifier.verifyFontsAreMonospace(outputPage: page, pageIndex: 0).isFail
        }
        let v1 = try await svt4Fail(d1)
        let v2 = try await svt4Fail(d2)
        let v3 = try await svt4Fail(d3)
        let v4 = try await svt4Fail(d4)
        let v5 = try await svt4Fail(d5)
        print("SVT-4 verdict isFail: (1)=\(v1) (2)=\(v2) (3)=\(v3) (4)=\(v4) (5)=\(v5)")
        print("===== END EXP-E6.1 =====")

        // --- Pins (regression-locked branch decision) ---
        // EMISSION pins measure the WRITER and are unchanged by any verifier
        // edit; SVT-4 VERDICT pins v3/v5 flipped with the J-5 refinement
        // (S05 phase A, 2026-06-09): the substituted subsets carry accepted
        // Courier/Menlo BaseFont names, so their writer-emitted CMaps are
        // tolerated. Unaccepted BaseFonts still FAIL (re-pointed RT-4).
        #expect(anyToUnicode(s1) == false,
                "(1) explicit Courier + ASCII must NOT emit /ToUnicode (EXP-E5.1 re-confirm).")
        #expect(v1 == false, "(1) SVT-4 must PASS on explicit Courier + ASCII.")
        #expect(anyToUnicode(s3) == true,
                "(3) auto-substituted fallback MUST emit /ToUnicode (writer emission, EXP-E6.1 mechanism).")
        #expect(v3 == false,
                "(3) refined SVT-4 tolerates the substituted subsets' CMaps (accepted BaseFonts, J-5).")

        // BRANCH DECISION = A: an EXPLICITLY-created accepted fallback (Menlo)
        // drawing glyphs IT COVERS emits NO /ToUnicode, and its advance is within
        // SVT-1 tolerance — so the Layer-8 fix can live in the reconstructor
        // (FIX-B) with SVT-4 and RT-4 untouched.
        #expect(anyToUnicode(s2) == false,
                "(2) explicit Menlo + ASCII: no /ToUnicode → Branch A viable.")
        #expect(v2 == false, "(2) SVT-4 must PASS on explicit Menlo + ASCII.")
        #expect(menloWithinTol,
                "Menlo advance must be within SVT-1 tolerance (Branch A keeps Layer 6 passing).")

        // COVERAGE GATE: the segmentation routes each grapheme by Courier coverage.
        // Latin-1 accents (é à ñ ü) are Courier-COVERED on iOS 26.4, so they stay in
        // Courier and emit no /ToUnicode — confirming the coverage gate is correct and
        // Latin-1 is not the bug source. (The explicit-Menlo path itself is shown
        // clean for ASCII by scenario 2.)
        #expect(anyToUnicode(s4) == false,
                "(4) coverage-aware segmentation keeps Courier-covered Latin-1 in Courier: no /ToUnicode.")
        #expect(v4 == false, "(4) SVT-4 must PASS on the coverage-aware Latin-1 segmentation.")

        // RESIDUAL: graphemes covered by NEITHER accepted family force a SECOND
        // CoreText substitution, so /ToUnicode persists even under the FIX-B
        // segmentation — the EXP-E6.2 mechanism (encoding-driven emission)
        // subsumed this observation and retired Branch A entirely. The
        // emitted subsets still carry accepted Courier/Menlo names, so the
        // J-5-refined SVT-4 tolerates them (verdict pin below); the
        // emission pin is writer behavior and stays.
        #expect(anyToUnicode(s5) == true,
                "(5) segmentation of neither-covered glyphs: /ToUnicode persists (writer emission).")
        #expect(v5 == false,
                "(5) refined SVT-4 tolerates the accepted-BaseFont subsets' CMaps (J-5).")
    }

    private func round4(_ d: Double) -> Double { (d * 10000).rounded() / 10000 }
}

// MARK: - EXP-E6.2 (S04, 2026-06-09) — encoding-driven /ToUnicode

// S04 additions. EXP-E6.1's scenarios drew only simple-encodable content
// (ASCII + MacRoman Latin-1), which bounded its conclusions: probe F
// (RealDocProbeTests) measured the Branch-A segmented-explicit shape against
// the REAL document and the /ToUnicode picture did not move. These probes
// isolate the mechanism: CGPDFContext emits a /ToUnicode-bearing subset for
// any glyph OUTSIDE its simple 8-bit encoding — explicit font creation and
// full glyph coverage do not matter — and the subset persists on later
// pages' resource dictionaries once registered.

extension ToUnicodeProbe {

    /// Multi-page variant of `pdf` — one entry list per page (the EXP-E6.2
    /// cross-page stickiness probe).
    static func multiPagePDF(
        _ pages: [[(text: String, x: CGFloat, y: CGFloat, font: CTFont)]]
    ) -> Data {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tuprobe_\(UUID().uuidString).pdf")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { return Data() }
        for entries in pages {
            ctx.beginPDFPage(nil)
            for e in entries {
                let attrs: [NSAttributedString.Key: Any] = [
                    NSAttributedString.Key(kCTFontAttributeName as String): e.font
                ]
                let line = CTLineCreateWithAttributedString(
                    NSAttributedString(string: e.text, attributes: attrs))
                ctx.textPosition = CGPoint(x: e.x, y: e.y)
                CTLineDraw(line, ctx)
            }
            ctx.endPDFPage()
        }
        ctx.closePDF()
        defer { try? FileManager.default.removeItem(at: url) }
        return (try? Data(contentsOf: url)) ?? Data()
    }

    /// Font report for an arbitrary page of `data`.
    static func report(_ data: Data, page index: Int) -> [FontResourceInfo] {
        guard let doc = PDFDocument(data: data),
              let page = doc.page(at: index) else { return [] }
        return SearchableMergeProbe.fontReport(page)
    }
}

@Suite("ToUnicode encoding probe — EXP-E6.2", .tags(.sandwich))
struct ToUnicodeEncodingProbeTests {

    @Test("EXP-E6.2 — /ToUnicode is encoding-driven, not substitution-driven")
    func toUnicodeEncodingDriven() async throws {
        let courier = CTFontCreateWithName("Courier" as CFString, 12.0, nil)
        let menlo = CTFontCreateWithName("Menlo-Regular" as CFString, 12.0, nil)

        func anyTU(_ infos: [FontResourceInfo]) -> Bool { infos.contains { $0.hasToUnicode } }
        func dump(_ label: String, _ infos: [FontResourceInfo]) {
            print("\(label): fonts=\(infos.count) anyToUnicode=\(anyTU(infos))")
            for f in infos { print("    base=\(f.baseFont) hasToUnicode=\(f.hasToUnicode)") }
        }
        func covered(_ s: String, _ font: CTFont) -> Bool {
            let utf16 = Array(s.utf16)
            var glyphs = [CGGlyph](repeating: 0, count: utf16.count)
            return CTFontGetGlyphsForCharacters(font, utf16, &glyphs, utf16.count)
        }

        print("===== EXP-E6.2 ENCODING-DRIVEN /ToUnicode =====")
        // (6a) U+00D7 (×) is Courier-COVERED on the iOS 26 runtimes — no
        // substitution occurs anywhere in this draw — but sits OUTSIDE the
        // writer's simple 8-bit encoding. One explicit-Courier line.
        let d7Covered = covered("\u{00D7}", courier)
        let d6a = ToUnicodeProbe.pdf([("RATE \u{00D7} FACTOR", 72, 700, courier)])
        let s6a = ToUnicodeProbe.report(d6a)
        print("U+00D7 courierCovered=\(d7Covered)")
        dump("(6a) explicit Courier + covered encoding-external U+00D7", s6a)

        // (6c) U+2713 (✓) is Menlo-COVERED (S03 probe D); explicit Menlo —
        // the EXP-E6.1 scenario-2 shape, with encoding-external content.
        let m13Covered = covered("\u{2713}", menlo)
        let d6c = ToUnicodeProbe.pdf([("OK \u{2713}", 72, 700, menlo)])
        let s6c = ToUnicodeProbe.report(d6c)
        print("U+2713 menloCovered=\(m13Covered)")
        dump("(6c) explicit Menlo + covered encoding-external U+2713", s6c)

        // (6b) cross-page stickiness: clean ASCII / ×-bearing / clean ASCII.
        let d6b = ToUnicodeProbe.multiPagePDF([
            [("CLEANPAGEONE", 72, 700, courier)],
            [("RATE \u{00D7} TWO", 72, 700, courier)],
            [("CLEANPAGETHREE", 72, 700, courier)],
        ])
        for pi in 0..<3 {
            dump("(6b) page\(pi + 1)", ToUnicodeProbe.report(d6b, page: pi))
        }
        print("===== END EXP-E6.2 =====")

        // Pins (measured 2026-06-09, S04). Mechanism (b): the CMap follows
        // the writer's encoding capability, not CoreText substitution. This
        // bounds EXP-E6.1 scenarios 1/2/4 (simple-encodable content only)
        // and is WHY the Branch-A shape cannot clear SVT-4 on the real
        // document (probe F reproduces the baseline 20/23 exactly).
        #expect(d7Covered,
                "U+00D7 must be Courier-covered so 6a isolates encoding from substitution.")
        #expect(anyTU(s6a),
                "(6a) explicit, fully covered Courier draw still emits /ToUnicode for U+00D7.")
        #expect(m13Covered,
                "U+2713 must be Menlo-covered so 6c isolates encoding from substitution.")
        #expect(anyTU(s6c),
                "(6c) explicit, fully covered Menlo draw still emits /ToUnicode for U+2713.")
        #expect(anyTU(ToUnicodeProbe.report(d6b, page: 0)) == false,
                "(6b) clean ASCII page 1 carries no /ToUnicode.")
        #expect(anyTU(ToUnicodeProbe.report(d6b, page: 1)),
                "(6b) the U+00D7-bearing page 2 emits /ToUnicode.")
        // STICKY (measured 2026-06-09): once the TU-bearing subset is
        // registered, later pages reference it even when their own content
        // is simple-encodable ASCII — which is why real-doc pages with no
        // anomalous glyphs (7/8/9/16/19/22) still carry the CMap.
        #expect(anyTU(ToUnicodeProbe.report(d6b, page: 2)),
                "(6b) clean ASCII page 3, drawn after the U+00D7 page, still references the TU-bearing subset.")
    }
}
