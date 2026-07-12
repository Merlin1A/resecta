import Testing
import Foundation
import PDFKit
import CoreGraphics
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
@testable import RedactionEngine

// SV-4 — PD-7 line-aware character filter, PD-8 writer↔verifier spatial
// contract, and the VH-1 Layer-7 count domain.
//
// The filter's safety-margin halo (±3pt) is larger than the inter-line gap
// of dense tabular layouts (measured 0.22–0.25pt on the sample statement),
// so a single-line region used to reach into neighboring lines it never
// touched — blanking spans there and swallowing whole label blocks at block
// scale (RC-2). PD-7 gates the halo on the region's un-expanded rect
// intersecting the character's LINE BAND while keeping an unconditional 0pt
// floor; within a region's own lines the halo is unchanged. Layer 6 enforces
// the same two tiers on read-back characters, skipping synthesized
// whitespace (PD-8), and Layer 7 counts non-whitespace on both sides (VH-1).
//
// The sample-statement fixture is FULLY SYNTHETIC with a public value set
// (see TestHelpers), so test diagnostics MAY reference matched text (the W2
// logging exemption). Production logging rules (ARCH §12.2) are unchanged.

@Suite("Line-aware filter and verifier lockstep", .tags(.sandwich), .serialized)
struct LineAwareFilterTests {

    // MARK: - Geometry helpers (pure CharacterInfo — no PDFKit variance)

    /// A line of 10pt-wide, 10pt-tall characters at `y`, one per index.
    private func makeLine(
        _ text: String, lineIndex: Int, y: CGFloat,
        startX: CGFloat = 100, charWidth: CGFloat = 10, height: CGFloat = 10
    ) -> [CharacterInfo] {
        text.enumerated().map { (i, char) in
            CharacterInfo(
                character: String(char),
                bounds: CGRect(x: startX + CGFloat(i) * charWidth, y: y,
                               width: charWidth, height: height),
                stringIndex: i,
                lineIndex: lineIndex
            )
        }
    }

    /// Two lines with a 0.25pt inter-line gap (the F2 table geometry):
    /// line A "AAAAAAAAAA" at y 400–410 (lineIndex 0), line B "BBBBBBBBBB"
    /// at y 410.25–420.25 (lineIndex 1). Chars sit at x 100+10i.
    private func twoCloseLines() -> [CharacterInfo] {
        makeLine("AAAAAAAAAA", lineIndex: 0, y: 400)
            + makeLine("BBBBBBBBBB", lineIndex: 1, y: 410.25)
    }

    /// Region over line-A chars 3–5 (x 131–159, y 400–410): overlaps A3–A5
    /// at 0pt; its ±3pt halo reaches A2/A6 on the same line AND crosses the
    /// 0.25pt gap into line B (y-expanded to 413).
    private let lineARegion = CGRect(x: 131, y: 400, width: 28, height: 10)

    // MARK: - PD-7: rect overload

    @Test("Halo does not cross a sub-point line gap (rect)")
    func haloDoesNotCrossLineGapRect() async throws {
        let chars = twoCloseLines()
        let result = try await filterCharacters(
            characters: chars, redactionRects: [lineARegion]
        )
        let survivorsByLine = Dictionary(grouping: result.surviving, by: \.lineIndex)

        // Line B survives whole: the region's un-expanded rect (maxY 410)
        // does not touch line B's band (minY 410.25), so the halo tier is
        // gated off there — even though every B char above the region
        // intersects the y-expanded rect.
        #expect(survivorsByLine[1]?.count == 10,
                "all line-B characters must survive a line-A region")

        // Line A keeps today's halo: A3–A5 excluded at 0pt, A2/A6 excluded
        // in the 3pt halo (gap 1pt), A0/A1/A7–A9 survive (gap ≥ 11pt).
        let lineAIndexes = Set(survivorsByLine[0]?.map(\.stringIndex) ?? [])
        #expect(lineAIndexes == [0, 1, 7, 8, 9],
                "line-A survivors must be exactly the out-of-halo characters; got \(lineAIndexes.sorted())")
    }

    @Test("Region spanning both bands excludes on both (rect)")
    func regionSpanningBothBandsExcludesBoth() async throws {
        let chars = twoCloseLines()
        // Same x-range, but y 405–415 genuinely crosses the gap: both
        // lines' bands intersect the un-expanded rect, so floor + halo
        // apply on both lines.
        let spanning = CGRect(x: 131, y: 405, width: 28, height: 10)
        let result = try await filterCharacters(
            characters: chars, redactionRects: [spanning]
        )
        let survivorsByLine = Dictionary(grouping: result.surviving, by: \.lineIndex)
        let lineAIndexes = Set(survivorsByLine[0]?.map(\.stringIndex) ?? [])
        let lineBIndexes = Set(survivorsByLine[1]?.map(\.stringIndex) ?? [])
        #expect(lineAIndexes == [0, 1, 7, 8, 9],
                "spanning region must exclude line-A chars 2–6; got \(lineAIndexes.sorted())")
        #expect(lineBIndexes == [0, 1, 7, 8, 9],
                "spanning region must exclude line-B chars 2–6; got \(lineBIndexes.sorted())")
    }

    @Test("Default lineIndex keeps the whole-page halo (rect)")
    func defaultLineIndexKeepsWholePageHalo() async throws {
        // The same two-line geometry constructed WITHOUT line information:
        // every char shares lineIndex 0, the band is the whole page, and
        // the halo applies everywhere — the pre-PD-7 exclusion set. Pins
        // the compatibility contract for callers that construct
        // CharacterInfo directly.
        let chars = makeLine("AAAAAAAAAA", lineIndex: 0, y: 400)
            + makeLine("BBBBBBBBBB", lineIndex: 0, y: 410.25)
        let result = try await filterCharacters(
            characters: chars, redactionRects: [lineARegion]
        )
        let survivorsByLine = Dictionary(
            grouping: result.surviving, by: \.bounds.minY)
        let lineBIndexes = Set(survivorsByLine[410.25]?.map(\.stringIndex) ?? [])
        #expect(lineBIndexes == [0, 1, 7, 8, 9],
                "without line info the halo must keep its whole-page reach; got \(lineBIndexes.sorted())")
    }

    @Test("Multiple regions keep floor/halo rects paired (rect)")
    func multipleRegionsKeepRectsPaired() async throws {
        // One region per line, at different x — exercises the minY sort
        // that pairs each expanded rect with its un-expanded source.
        let chars = twoCloseLines()
        let onA = CGRect(x: 131, y: 400, width: 8, height: 10)     // A3
        let onB = CGRect(x: 171, y: 410.25, width: 8, height: 10)  // B7
        let result = try await filterCharacters(
            characters: chars, redactionRects: [onB, onA]  // unsorted input
        )
        let survivorsByLine = Dictionary(grouping: result.surviving, by: \.lineIndex)
        let lineAIndexes = Set(survivorsByLine[0]?.map(\.stringIndex) ?? [])
        let lineBIndexes = Set(survivorsByLine[1]?.map(\.stringIndex) ?? [])
        // A: 0pt on A3, halo on A2/A4 (1pt gaps); B: 0pt on B7, halo B6/B8.
        #expect(lineAIndexes == [0, 1, 5, 6, 7, 8, 9],
                "line-A region must exclude A2–A4 only; got \(lineAIndexes.sorted())")
        #expect(lineBIndexes == [0, 1, 2, 3, 4, 5, 9],
                "line-B region must exclude B6–B8 only; got \(lineBIndexes.sorted())")
    }

    // MARK: - PD-7: polygon overload

    /// RegionShape for a rectangle-shaped polygon over `rect`.
    private func polygonShape(_ rect: CGRect) -> RegionShape {
        RegionShape(
            expandedBounds: rect.insetBy(
                dx: -safetyMarginPoints, dy: -safetyMarginPoints),
            polygonVertices: [
                CGPoint(x: rect.minX, y: rect.minY),
                CGPoint(x: rect.maxX, y: rect.minY),
                CGPoint(x: rect.maxX, y: rect.maxY),
                CGPoint(x: rect.minX, y: rect.maxY),
            ],
            bounds: rect
        )
    }

    @Test("Halo does not cross a sub-point line gap (polygon)")
    func haloDoesNotCrossLineGapPolygon() async throws {
        let chars = twoCloseLines()
        let result = try await filterCharacters(
            characters: chars, regionShapes: [polygonShape(lineARegion)]
        )
        let survivorsByLine = Dictionary(grouping: result.surviving, by: \.lineIndex)
        #expect(survivorsByLine[1]?.count == 10,
                "all line-B characters must survive a line-A polygon region")
        let lineAIndexes = Set(survivorsByLine[0]?.map(\.stringIndex) ?? [])
        #expect(lineAIndexes == [0, 1, 7, 8, 9],
                "line-A survivors must be exactly the out-of-halo characters; got \(lineAIndexes.sorted())")
    }

    @Test("Polygon floor holds at 0pt regardless of band gate")
    func polygonFloorUnconditional() async throws {
        // A one-char "line" whose band the region rect happens to intersect
        // only AT the char itself: the 0pt floor must exclude it even if
        // the halo tier would be gated off for every other line.
        let chars = twoCloseLines()
        let result = try await filterCharacters(
            characters: chars, regionShapes: [polygonShape(lineARegion)]
        )
        // A3–A5 are inside the polygon at 0pt — they must never survive.
        let insidePolygon = result.surviving.filter {
            $0.lineIndex == 0 && (3...5).contains($0.stringIndex)
        }
        #expect(insidePolygon.isEmpty,
                "characters inside the polygon must be excluded at 0pt")
    }

    // MARK: - Extractor line partition (PDFKit-real)

    @Test("Extractor stamps the newline partition", .timeLimit(.minutes(1)))
    func extractorStampsNewlinePartition() async throws {
        // Two raw text runs on separate baselines: PDFKit synthesizes a
        // line separator between them in `page.string`; the extractor's
        // lineIndex must partition the entries accordingly.
        let stream = """
            BT /F1 12 Tf 100 700 Td (LINEONE) Tj ET
            BT /F1 12 Tf 100 680 Td (LINETWO) Tj ET
            """
        let data = buildRawPDF(objects: [
            PDFObject(id: 1, content: "<< /Type /Catalog /Pages 2 0 R >>"),
            PDFObject(id: 2, content: "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
            PDFObject(id: 3, content: """
                << /Type /Page /Parent 2 0 R \
                /MediaBox [0 0 612 792] \
                /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>
                """),
            PDFObject(id: 4, content: "<< /Length \(stream.utf8.count) >>\nstream\n\(stream)\nendstream"),
            PDFObject(id: 5, content: "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>"),
        ], rootId: 1)
        let doc = try #require(PDFDocument(data: data))
        let page = try #require(doc.page(at: 0))
        let pageText = try #require(page.string)
        let hasSeparator = pageText.contains(where: \.isNewline)
        #expect(hasSeparator,
                "fixture must produce a synthesized line separator")

        let entries = try await TextLayerExtractor().extractCharacters(from: page)
        let lineOne = entries.filter { entry in
            "LINEONE".contains(entry.character)
                && entry.bounds.minY > 690
        }
        let lineTwo = entries.filter { entry in
            "LINETWO".contains(entry.character)
                && entry.bounds.minY < 690
        }
        #expect(!lineOne.isEmpty && !lineTwo.isEmpty,
                "both runs must extract")
        #expect(Set(lineOne.map(\.lineIndex)).count == 1,
                "first run must share one lineIndex")
        #expect(Set(lineTwo.map(\.lineIndex)).count == 1,
                "second run must share one lineIndex")
        #expect(lineOne.first?.lineIndex != lineTwo.first?.lineIndex,
                "runs on different baselines must carry different lineIndexes")
    }

    @Test("Sample p1 lineIndex matches the page.string newline count",
          .timeLimit(.minutes(1)))
    func sampleLineIndexMatchesNewlineCount() async throws {
        let data = try TestFixtures.sampleStatementPDF()
        let doc = try #require(PDFDocument(data: data))
        let page = try #require(doc.page(at: 0))
        let entries = try await TextLayerExtractor().extractCharacters(from: page)
        let pageText = try #require(page.string)

        // Composed walk mirroring the extractor: count line-separator units.
        let ns = pageText as NSString
        var separators = 0
        var offset = 0
        while offset < ns.length {
            let range = ns.rangeOfComposedCharacterSequence(at: offset)
            if ns.substring(with: range).contains(where: \.isNewline) {
                separators += 1
            }
            offset += max(range.length, 1)
        }
        let maxLine = entries.map(\.lineIndex).max() ?? -1
        #expect(maxLine <= separators,
                "lineIndex can never exceed the separator count")
        // The last text run follows the final mid-page separator; PDFKit
        // may or may not synthesize a trailing separator after it.
        #expect(maxLine >= separators - 1,
                "every mid-page separator must advance the partition (max \(maxLine), separators \(separators))")
    }

    // MARK: - PD-8: sample-doc writer↔verifier contract

    /// Region rects for the two uppercase DELIA HARTWELL row occurrences on
    /// sample page 1, derived from the fixture's own glyph bounds (the same
    /// bounds a match region is produced from). Returned in page points
    /// (zero-origin) plus normalized form.
    private static func hartwellRowRegions(
        page: PDFPage, entries: [CharacterInfo]
    ) throws -> (rects: [CGRect], normalized: [CGRect]) {
        let pageText = try #require(page.string)
        let ns = pageText as NSString
        let pageBounds = page.bounds(for: .cropBox)
        var rects: [CGRect] = []
        var search = NSRange(location: 0, length: ns.length)
        while true {
            let found = ns.range(of: "DELIA HARTWELL", options: [], range: search)
            guard found.location != NSNotFound else { break }
            let member = entries.filter {
                !FilterResult.isLineageWhitespace($0.character)
                    && $0.stringIndex >= found.location
                    && $0.stringIndex < found.location + found.length
            }
            let union = member.dropFirst().reduce(member.first?.bounds ?? .zero) {
                $0.union($1.bounds)
            }
            if !union.isEmpty { rects.append(union) }
            let next = found.location + found.length
            search = NSRange(location: next, length: ns.length - next)
        }
        let normalized = rects.map {
            CGRect(x: $0.minX / pageBounds.width,
                   y: $0.minY / pageBounds.height,
                   width: $0.width / pageBounds.width,
                   height: $0.height / pageBounds.height)
        }
        return (rects, normalized)
    }

    @Test("Sample-doc PD-8 contract — rescued neighbors, Layer 6/7/9 pass",
          .timeLimit(.minutes(2)))
    func sampleDocContract() async throws {
        let fixture = try TestFixtures.sampleStatementPDF()
        let srcDoc = try #require(PDFDocument(data: fixture))
        let srcPage = try #require(srcDoc.page(at: 0))
        let extractor = TextLayerExtractor()
        let srcEntries = try await extractor.extractCharacters(from: srcPage)

        let (rects, normalized) = try Self.hartwellRowRegions(
            page: srcPage, entries: srcEntries)
        #expect(rects.count == 2,
                "sample page 1 carries two uppercase DELIA HARTWELL rows")

        let regions = [0: normalized.map {
            RedactionRegion(id: UUID(), normalizedRect: $0, source: .manual)
        }]
        let url = try await TestPipeline.processAndExport(
            fixture, mode: .searchableRedaction, regions: regions, dpi: 150)
        defer { try? FileManager.default.removeItem(at: url) }
        let digests = try await TestPipeline.searchableDigests(
            fixture, regions: regions)

        let outDoc = try #require(PDFDocument(url: url))
        let outPage = try #require(outDoc.page(at: 0))
        let outText = try #require(outPage.string)

        // Redacted content is out of the text layer; the un-redacted tail
        // of the same line survives outside the halo.
        #expect(!outText.contains("DELIA") && !outText.contains("HARTWELL"),
                "region content must not reach the output text layer")
        #expect(outText.contains("ID:9100004821"),
                "same-line content outside the halo must survive")
        // The neighbor line 0.22pt above the region — blanked by the
        // whole-page halo before PD-7 — is present in full.
        #expect(outText.contains("NORTHLINE LOGISTICS DIRECT DEP"),
                "neighbor-line content must survive a single-line region")
        // The holder-block name row (mixed case, different lines) is intact.
        #expect(outText.contains("Delia R. Hartwell"),
                "content on unrelated lines must be untouched")

        // Layer 6 with the PRODUCTION two-tier shapes (un-expanded floor +
        // margin halo) passes on the engine's own output.
        let outBounds = outPage.bounds(for: .cropBox)
        let outRects = normalized.map {
            normalizedToPDFPageCoordinates($0, pageRect: outBounds)
        }
        let shapes = outRects.map {
            RegionShape(
                expandedBounds: $0.insetBy(
                    dx: -safetyMarginPoints, dy: -safetyMarginPoints),
                polygonVertices: nil,
                bounds: $0
            )
        }
        let verifier = SandwichVerification()
        let layer6 = try await verifier.verifySpatialExclusion(
            outputPage: outPage, regionShapes: shapes, pageIndex: 0)
        #expect(layer6 == .pass,
                "Layer 6 must pass on the engine's own output; got \(layer6)")

        // Direct floor assertion (the written contract's first clause): no
        // non-whitespace read-back character's GLYPH-CORE box intersects a
        // region rect at 0pt. The core box is the selection box vertically
        // inset by the read-back font's descent fraction (PD-12) — the
        // same derivation Layer 6 applies.
        let nsOut = outText as NSString
        var offset = 0
        var floorViolations = 0
        while offset < outPage.numberOfCharacters {
            let range = nsOut.rangeOfComposedCharacterSequence(at: offset)
            defer { offset += max(range.length, 1) }
            guard !FilterResult.isLineageWhitespace(nsOut.substring(with: range)),
                  let sel = outPage.selection(for: range) else { continue }
            let bounds = sel.bounds(for: outPage)
            guard bounds.width > 0, bounds.height > 0 else { continue }
            var family: String?
            var pointSize: CGFloat = 0
            #if canImport(UIKit)
            if let attr = sel.attributedString, attr.length > 0,
               let font = attr.attribute(
                .font, at: 0, effectiveRange: nil) as? UIFont {
                family = font.familyName
                pointSize = font.pointSize
            }
            #else
            if let attr = sel.attributedString, attr.length > 0,
               let font = attr.attribute(
                .font, at: 0, effectiveRange: nil) as? NSFont {
                family = font.familyName ?? font.fontName
                pointSize = font.pointSize
            }
            #endif
            let fraction = SandwichVerification.descentFraction(
                family: family, pointSize: pointSize)
            let core = bounds.insetBy(dx: 0, dy: fraction * bounds.height)
            if outRects.contains(where: { core.intersects($0) }) {
                floorViolations += 1
            }
        }
        #expect(floorViolations == 0,
                "\(floorViolations) non-whitespace glyph-core boxes intersect a region rect at 0pt")

        // Layers 7 and 9 hold on the same run's digest.
        let digest = try #require(digests[0])
        let layer7 = try await verifier.verifyCharacterCount(
            outputPage: outPage, digest: digest)
        #expect(layer7 == .pass, "Layer 7 must pass; got \(layer7)")
        let layer9 = try await verifier.verifyCharacterLineage(
            outputPage: outPage, digest: digest)
        #expect(layer9 == .pass, "Layer 9 must pass; got \(layer9)")
    }

    // MARK: - VH-1: Layer 7 count-domain parity

    /// Non-whitespace, non-zero-bounds composed count of an output page —
    /// the Layer 7 output-side domain, recomputed independently here.
    private static func outputNonWhitespaceCount(_ page: PDFPage) -> Int {
        guard let text = page.string else { return 0 }
        let ns = text as NSString
        var count = 0
        var offset = 0
        while offset < page.numberOfCharacters {
            let range = ns.rangeOfComposedCharacterSequence(at: offset)
            defer { offset += max(range.length, 1) }
            guard !FilterResult.isLineageWhitespace(ns.substring(with: range)),
                  let sel = page.selection(for: range) else { continue }
            let bounds = sel.bounds(for: page)
            if bounds.width > 0, bounds.height > 0 { count += 1 }
        }
        return count
    }

    @Test("Layer 7 exact parity on sample and packet",
          .timeLimit(.minutes(5)))
    func layer7ExactParity() async throws {
        // Both committed corpus fixtures, full-page text layers (empty
        // regions): the output-side non-whitespace count equals the
        // digest's non-whitespace surviving count EXACTLY on every page —
        // the measurement that motivates the pinned small-constant excess
        // tolerance (`characterCountExcessTolerance`).
        let verifier = SandwichVerification()
        for (label, fixture) in [
            ("sample", try TestFixtures.sampleStatementPDF()),
            ("packet", try TestFixtures.loanPacketPDF()),
        ] {
            let url = try await TestPipeline.processAndExport(
                fixture, mode: .searchableRedaction, regions: [:], dpi: 150)
            defer { try? FileManager.default.removeItem(at: url) }
            let digests = try await TestPipeline.searchableDigests(
                fixture, regions: [:])
            let outDoc = try #require(PDFDocument(url: url))
            for pageIndex in 0..<outDoc.pageCount {
                guard let digest = digests[pageIndex],
                      let page = outDoc.page(at: pageIndex) else { continue }
                let outputCount = Self.outputNonWhitespaceCount(page)
                #expect(
                    outputCount == digest.survivingNonWhitespaceCount,
                    "\(label) page \(pageIndex + 1): output \(outputCount) != surviving \(digest.survivingNonWhitespaceCount)")
                let layer7 = try await verifier.verifyCharacterCount(
                    outputPage: page, digest: digest)
                #expect(layer7 == .pass,
                        "\(label) page \(pageIndex + 1): Layer 7 must pass; got \(layer7)")
            }
        }
    }
}
