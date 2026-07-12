import Testing
import PDFKit
import CoreGraphics
import CoreText
#if canImport(UIKit)
import UIKit
#endif
@testable import RedactionEngine

// Tests for ENGINE §5C — invisible text layer reconstruction.
// J-12 layout contract (2026-06-09): each Y-sweep band draws at ONE pitch —
// sum-matched to the band's source glyph widths, capped at the band's
// median glyph height, quantized to 0.5pt — with same-band groups bridged
// into one CTLine by whole-cell spaces (never across a redaction rect) and
// an assembled-line fit clamp. The 12pt-era grid model (`groupIntoRuns`,
// `snappedOrigin`, `cellWidth`) remains the shared run definition and is
// pinned below as the legacy view.

@Suite("Text Layer Reconstruction")
struct TextLayerReconstructorTests {

    // MARK: - groupIntoRuns (ENGINE §5C.1 — shared run definition)

    @Test("Single character produces single run with grid-snapped origin")
    func singleCharacterRun() {
        let chars = [CharacterInfo(
            character: "A",
            bounds: CGRect(x: 100, y: 400, width: 15, height: 20),
            stringIndex: 0
        )]

        let runs = TextLayerReconstructor.groupIntoRuns(chars)
        #expect(runs.count == 1)
        #expect(runs[0].text == "A")
        // Origin X must be a multiple of cellWidth (7.20…pt). For minX=100,
        // floor(100/7.2)=13, so the snapped origin is 13 × 7.2 = 93.6…
        let cellWidth = TextLayerReconstructor.cellWidth
        let snappedX = floor(100 / cellWidth) * cellWidth
        #expect(runs[0].origin.x == snappedX,
                "Run origin X must snap to the cell grid")
        // Y is left unsnapped — vertical line geometry tracks the source.
        #expect(runs[0].origin.y == 400)
    }

    @Test("Adjacent characters on same line grouped into one run")
    func adjacentCharactersGrouped() {
        let chars = (0..<5).map { i in
            CharacterInfo(
                character: String(["H", "e", "l", "l", "o"][i]),
                bounds: CGRect(x: 100 + Double(i) * 14.4, y: 400, width: 14.4, height: 20),
                stringIndex: i
            )
        }

        let runs = TextLayerReconstructor.groupIntoRuns(chars)
        #expect(runs.count == 1)
        #expect(runs[0].text == "Hello")
        let cellWidth = TextLayerReconstructor.cellWidth
        let snappedX = floor(100 / cellWidth) * cellWidth
        #expect(runs[0].origin.x == snappedX,
                "Group origin X is the snap of the first character's minX")
    }

    @Test("Characters on different lines produce separate runs")
    func differentLinesSeparateRuns() {
        let line1 = CharacterInfo(
            character: "A", bounds: CGRect(x: 100, y: 400, width: 15, height: 20), stringIndex: 0
        )
        let line2 = CharacterInfo(
            character: "B", bounds: CGRect(x: 100, y: 350, width: 15, height: 20), stringIndex: 1
        )

        let runs = TextLayerReconstructor.groupIntoRuns([line1, line2])
        #expect(runs.count == 2)
    }

    @Test("Wide gap between characters splits into separate runs")
    func wideGapSplitsRuns() {
        let a = CharacterInfo(
            character: "A", bounds: CGRect(x: 100, y: 400, width: 15, height: 20), stringIndex: 0
        )
        let b = CharacterInfo(
            character: "B", bounds: CGRect(x: 300, y: 400, width: 15, height: 20), stringIndex: 1
        )

        let runs = TextLayerReconstructor.groupIntoRuns([a, b])
        #expect(runs.count == 2)
        let cellWidth = TextLayerReconstructor.cellWidth
        let snappedA = floor(100 / cellWidth) * cellWidth
        let snappedB = floor(300 / cellWidth) * cellWidth
        #expect(runs[0].origin.x == snappedA)
        #expect(runs[1].origin.x == snappedB,
                "Each new run snaps its origin X independently")
    }

    @Test("Empty input produces no runs")
    func emptyInput() {
        let runs = TextLayerReconstructor.groupIntoRuns([])
        #expect(runs.isEmpty)
        #expect(TextLayerReconstructor.layoutLines(
            [], pageWidth: 612, redactionRects: []).isEmpty)
    }

    // MARK: - runMemberGroups: symmetric per-pair line height (CAT-375)

    /// Index of the group containing `member`, or nil.
    private func groupIndex(of member: Int, in groups: [[Int]]) -> Int? {
        groups.firstIndex { $0.contains(member) }
    }

    @Test("CAT-375: a tall heading glyph does not over-merge the small lines beneath it")
    func mixedFontSizeGroupingSeparatesSmallLines() {
        // A 24pt heading glyph sits well above two 8pt body glyphs that are on
        // adjacent (8pt-spaced) lines. The old grouping loop took its
        // same-line threshold from a single page-global height — the first
        // sorted glyph, here the tall heading — so `24 × 0.5 = 12` swallowed
        // the `8`-pt gap between the two small lines and merged them into one
        // group. The symmetric per-pair `min(height) × 0.5 = 4` keeps them
        // apart. CAT-375.
        let heading = CharacterInfo(
            character: "H", bounds: CGRect(x: 10, y: 200, width: 14, height: 24),
            stringIndex: 0)
        let small1 = CharacterInfo(
            character: "x", bounds: CGRect(x: 10, y: 100, width: 5, height: 8),
            stringIndex: 1)
        let small2 = CharacterInfo(
            character: "y", bounds: CGRect(x: 10, y: 92, width: 5, height: 8),
            stringIndex: 2)

        let groups = TextLayerReconstructor.runMemberGroups([heading, small1, small2])

        // Pre-fix: [[0], [1, 2]] (count 2). Post-fix: [[0], [1], [2]] (count 3).
        #expect(groups.count == 3,
                "tall heading must not inflate the same-line threshold for the two small lines")
        #expect(groupIndex(of: 1, in: groups) != groupIndex(of: 2, in: groups),
                "the two small-line glyphs must land in different groups")
    }

    @Test("CAT-375: a genuine mixed-size same-line pair still groups together")
    func mixedFontSizeGroupingKeepsSameLineTogether() {
        // A large cap and a smaller following glyph share a baseline (midY gap
        // 4 pt). The per-pair `min(18, 10) × 0.5 = 5` threshold still admits
        // them as one line, so the symmetric form does not over-split genuine
        // same-line runs. CAT-375.
        let big = CharacterInfo(
            character: "B", bounds: CGRect(x: 10, y: 100, width: 14, height: 18),
            stringIndex: 0)
        let small = CharacterInfo(
            character: "a", bounds: CGRect(x: 26, y: 100, width: 8, height: 10),
            stringIndex: 1)

        let groups = TextLayerReconstructor.runMemberGroups([big, small])
        #expect(groups.count == 1,
                "an adjacent mixed-size pair on the same baseline stays one group")
    }

    // MARK: - CAT-366: CropBox-local extraction (D-34 canonical coordinate contract)

    @Test("CAT-366: extractCharacters returns cropBox-local bounds on a non-zero-origin page")
    func nonZeroCropBoxOriginCorrection() async throws {
        let data = TestFixtures.nonZeroOriginDiscriminatingPDF()
        let doc = try #require(PDFDocument(data: data))
        let page = try #require(doc.page(at: 0))
        let cropBox = page.bounds(for: .cropBox)

        let chars = try await TextLayerExtractor().extractCharacters(from: page)
        let first = try #require(chars.first, "fixture must yield characters")
        // Post-fix the bounds are cropBox-local: text at user-space x ≈ 220
        // becomes local x ≈ 20, well below the source cropBox origin (200).
        // Pre-fix (absolute) it is ≈ 220 and this assertion is red.
        #expect(first.bounds.minX < cropBox.origin.x - 1,
                "first character must be cropBox-local (minX ≈ 20 < origin.x 200)")

        // Assembled line origins land inside the zero-origin output page box
        // (effective size = cropBox size for an un-rotated page).
        let lines = TextLayerReconstructor.layoutLines(
            chars, pageWidth: cropBox.width, redactionRects: [])
        for line in lines {
            #expect(line.origin.x >= -1 && line.origin.x <= cropBox.width + 1,
                    "line origin X must sit inside the output page box")
            #expect(line.origin.y >= -1 && line.origin.y <= cropBox.height + 1,
                    "line origin Y must sit inside the output page box")
        }
    }

    // MARK: - Reference-grid invariants (legacy 12pt-era model)

    @Test("Cell width is 0.60009765625 × baseFontSize")
    func cellWidthConstantMatchesPlan() {
        let expected = SandwichVerification.courierAdvancePerPoint
            * TextLayerReconstructor.baseFontSize
        #expect(TextLayerReconstructor.cellWidth == expected)
        // Plan §3.1 anchor value at 12pt base.
        #expect(abs(TextLayerReconstructor.cellWidth - 7.20117_1875) < 0.0001)
    }

    @Test("Base font size is the 12pt REFERENCE constant (J-12 derives band sizes)")
    func baseFontSizeIsConstant() {
        // [J-12 flip, 2026-06-09] The constant no longer pins the drawn
        // size — `layoutLines` derives one quantized pitch per band — but
        // it anchors the verifier's linear tolerance scaling
        // (`advanceWidthTolerancePerPoint × pointSize` == 0.25 at 12pt).
        #expect(TextLayerReconstructor.baseFontSize == 12.0)
        #expect(abs(SandwichVerification.advanceWidthTolerancePerPoint
                    * TextLayerReconstructor.baseFontSize - 0.25) < 1e-9)
    }

    @Test("snappedOrigin floors X to a multiple of cellWidth, leaves Y alone")
    func snappedOriginContract() {
        let cellWidth = TextLayerReconstructor.cellWidth
        let raw = CGPoint(x: 100, y: 400)
        let snapped = TextLayerReconstructor.snappedOrigin(raw)
        #expect(snapped.x == floor(100 / cellWidth) * cellWidth)
        #expect(snapped.y == 400, "Y is not modified by the grid snap")
        // Origin already on the grid is a no-op.
        let onGrid = CGPoint(x: cellWidth * 5, y: 400)
        #expect(TextLayerReconstructor.snappedOrigin(onGrid) == onGrid)
    }

    // MARK: - layoutLines (ENGINE §5C.1/§5C.2, J-12)

    @Test("layoutLines: band size is sum-matched, height-capped, quantized")
    func layoutLinesDerivedSizeLaw() {
        // Two 14pt-wide, 20pt-high glyphs: sum-matched raw size is
        // 28 / (2 × 0.60009765625) ≈ 23.33 — the height cap (median 20)
        // binds, and 20 is already on the 0.5pt quantization grid.
        let entries = [
            CharacterInfo(character: "A", bounds: CGRect(x: 72, y: 700, width: 14, height: 20), stringIndex: 0),
            CharacterInfo(character: "B", bounds: CGRect(x: 86, y: 700, width: 14, height: 20), stringIndex: 1),
        ]
        let lines = TextLayerReconstructor.layoutLines(
            entries, pageWidth: 612, redactionRects: [])
        #expect(lines.count == 1)
        #expect(lines[0].fontSize == 20.0,
                "Height cap binds and the size lands on the quantization grid")
        #expect(lines[0].text == "AB")
        let cw = SandwichVerification.courierAdvancePerPoint * 20.0
        #expect(lines[0].origin.x == floor(72 / cw) * cw,
                "Line origin snaps to the band's OWN grid")
        #expect(lines[0].origin.y == 700)

        // Narrow glyphs (5pt wide, 12pt high): width-derived sizing binds —
        // 10 / (2 × 0.6001) ≈ 8.33 → quantized 8.5.
        let narrow = [
            CharacterInfo(character: "x", bounds: CGRect(x: 72, y: 700, width: 5, height: 12), stringIndex: 0),
            CharacterInfo(character: "y", bounds: CGRect(x: 77, y: 700, width: 5, height: 12), stringIndex: 1),
        ]
        let narrowLines = TextLayerReconstructor.layoutLines(
            narrow, pageWidth: 612, redactionRects: [])
        #expect(narrowLines.first?.fontSize == 8.5,
                "Sum-matched sizing binds when under the height cap")
    }

    @Test("layoutLines: same-band gap bridges with spaces; a redaction rect splits the line")
    func layoutLinesBridgeAndRegionSplit() {
        // Two groups on one line separated by a ~50pt gap.
        let entries = [
            CharacterInfo(character: "A", bounds: CGRect(x: 100, y: 400, width: 6, height: 10), stringIndex: 0),
            CharacterInfo(character: "B", bounds: CGRect(x: 106, y: 400, width: 6, height: 10), stringIndex: 1),
            CharacterInfo(character: "C", bounds: CGRect(x: 160, y: 400, width: 6, height: 10), stringIndex: 2),
            CharacterInfo(character: "D", bounds: CGRect(x: 166, y: 400, width: 6, height: 10), stringIndex: 3),
        ]
        let bridged = TextLayerReconstructor.layoutLines(
            entries, pageWidth: 612, redactionRects: [])
        #expect(bridged.count == 1, "Same-band groups assemble into one line")
        if let line = bridged.first {
            #expect(line.text.hasPrefix("AB") && line.text.hasSuffix("CD"))
            let spaces = line.text.filter { $0 == " " }.count
            #expect(spaces >= 1, "The inter-group gap carries bridge spaces")
            #expect(!line.text.contains("BC"),
                    "Groups stay separated by at least one space")
        }

        // The same geometry with a redaction rect inside the gap: the
        // bridge would cross it, so the line splits into two.
        let region = CGRect(x: 120, y: 395, width: 30, height: 20)
        let split = TextLayerReconstructor.layoutLines(
            entries, pageWidth: 612, redactionRects: [region])
        #expect(split.count == 2,
                "A bridge never crosses a redaction rect — the line splits")
        #expect(split.first?.text == "AB")
        #expect(split.last?.text == "CD")
        if let second = split.last {
            let cw = SandwichVerification.courierAdvancePerPoint * second.fontSize
            #expect(second.origin.x == floor(160 / cw) * cw,
                    "The post-region line re-anchors at its own snapped origin")
        }
    }

    @Test("layoutLines: assembled line steps down to fit the page box")
    func layoutLinesFitClamp() {
        // 30 glyphs, 10pt wide each, 12pt high, starting at x=420: the
        // height-capped size (12 → cw 7.2) would end at ~636 on a 612pt
        // page; the clamp steps the band down until the assembled line
        // ends at least one cell inside the box.
        let entries = (0..<30).map { i in
            CharacterInfo(
                character: "N",
                bounds: CGRect(x: 420 + Double(i) * 10, y: 300, width: 10, height: 12),
                stringIndex: i)
        }
        let lines = TextLayerReconstructor.layoutLines(
            entries, pageWidth: 612, redactionRects: [])
        #expect(lines.count == 1)
        if let line = lines.first {
            #expect(line.fontSize < 12.0, "The fit clamp engaged")
            let cw = SandwichVerification.courierAdvancePerPoint * line.fontSize
            let font = CTFontCreateWithName("Courier" as CFString, line.fontSize, nil)
            let ctLine = CTLineCreateWithAttributedString(NSAttributedString(
                string: line.text,
                attributes: [NSAttributedString.Key.font: font]))
            let endX = line.origin.x
                + CGFloat(CTLineGetTypographicBounds(ctLine, nil, nil, nil))
            #expect(endX + cw <= 612,
                    "The assembled line ends at least one cell inside the page box")
        }
    }

    // MARK: - drawInvisibleTextLayer (ENGINE §5C.1)

    @Test("Drawing invisible text layer into PDF context produces selectable text",
          .timeLimit(.minutes(1)))
    func drawInvisibleTextProducesSelectableText() throws {
        let pageSize = CGSize(width: 612, height: 792)
        let entries = [
            CharacterInfo(character: "H", bounds: CGRect(x: 72, y: 700, width: 14, height: 20), stringIndex: 0),
            CharacterInfo(character: "i", bounds: CGRect(x: 86, y: 700, width: 14, height: 20), stringIndex: 1),
        ]

        // Create a PDF with invisible text
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_invisible_\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        var box = CGRect(origin: .zero, size: pageSize)
        guard let ctx = CGContext(tempURL as CFURL, mediaBox: &box, nil) else {
            Issue.record("Could not create PDF context")
            return
        }

        ctx.beginPDFPage(nil)

        // Draw white background
        #if canImport(UIKit)
        ctx.setFillColor(UIKit.UIColor.white.cgColor)
        #else
        ctx.setFillColor(UIColor.white.cgColor)
        #endif
        ctx.fill(box)

        // Draw invisible text layer
        TextLayerReconstructor.drawInvisibleTextLayer(
            context: ctx,
            entries: entries,
            pageWidth: pageSize.width
        )

        ctx.endPDFPage()
        ctx.closePDF()

        // Verify the text is selectable via PDFKit
        let doc = try #require(PDFDocument(url: tempURL))
        let page = try #require(doc.page(at: 0))
        let text = page.string ?? ""

        #expect(text.contains("Hi") || text.contains("H"),
                "Invisible text should be extractable by PDFKit")
    }

    @Test("Per-character UIFont pointSize in the output equals the band's derived size",
          .timeLimit(.minutes(1)))
    func outputFontPointSizeMatchesDerivedBandSize() throws {
        // [J-12 flip, 2026-06-09] Was: pointSize == the pinned 12pt
        // constant. Now: pointSize == the band's derived quantized size —
        // for these 14pt-wide / 20pt-high glyphs the height cap binds and
        // the drawn (and PDFKit-reported) size is 20pt.
        let pageSize = CGSize(width: 612, height: 792)
        let entries = [
            CharacterInfo(character: "A", bounds: CGRect(x: 72, y: 700, width: 14, height: 20), stringIndex: 0),
            CharacterInfo(character: "B", bounds: CGRect(x: 86, y: 700, width: 14, height: 20), stringIndex: 1),
        ]
        let expectedSize = TextLayerReconstructor.layoutLines(
            entries, pageWidth: pageSize.width, redactionRects: []
        ).first?.fontSize

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_fontsize_\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        var box = CGRect(origin: .zero, size: pageSize)
        guard let ctx = CGContext(tempURL as CFURL, mediaBox: &box, nil) else {
            Issue.record("Could not create PDF context")
            return
        }
        ctx.beginPDFPage(nil)
        #if canImport(UIKit)
        ctx.setFillColor(UIKit.UIColor.white.cgColor)
        #else
        ctx.setFillColor(UIColor.white.cgColor)
        #endif
        ctx.fill(box)
        TextLayerReconstructor.drawInvisibleTextLayer(
            context: ctx, entries: entries,
            pageWidth: pageSize.width
        )
        ctx.endPDFPage()
        ctx.closePDF()

        let doc = try #require(PDFDocument(url: tempURL))
        let page = try #require(doc.page(at: 0))
        let pageText = try #require(page.string)
        let nsText = pageText as NSString
        guard nsText.length > 0 else {
            Issue.record("Output page string is empty; cannot read font size")
            return
        }

        // Walk the first composed character that carries a font attribute
        // and assert its pointSize equals the band's derived size.
        let composedRange = nsText.rangeOfComposedCharacterSequence(at: 0)
        let sel = try #require(page.selection(for: composedRange))
        let attr = try #require(sel.attributedString)
        guard attr.length > 0 else {
            Issue.record("Selection attributedString is empty")
            return
        }
        let font = try #require(
            attr.attribute(.font, at: 0, effectiveRange: nil) as? UIFont
        )
        #expect(expectedSize == 20.0)
        #expect(font.pointSize == expectedSize,
                "Output font size equals the band's derived quantized size (J-12)")
    }
}
