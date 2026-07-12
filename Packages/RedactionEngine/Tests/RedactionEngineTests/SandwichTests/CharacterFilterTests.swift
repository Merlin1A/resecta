import Testing
import PDFKit
import CoreGraphics
@testable import RedactionEngine

// Tests for ENGINE §5B — character filtering and coordinate conversion.

@Suite("Character Filtering")
struct CharacterFilterTests {

    // MARK: - normalizedToPDFPageCoordinates (ENGINE §5B.1a)

    @Test("Coordinate conversion with zero-origin page")
    func coordinateConversionZeroOrigin() {
        let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792)
        let normalized = CGRect(x: 0.5, y: 0.5, width: 0.25, height: 0.25)

        let result = normalizedToPDFPageCoordinates(normalized, pageRect: pageRect)

        #expect(abs(result.origin.x - 306) < 0.01)
        #expect(abs(result.origin.y - 396) < 0.01)
        #expect(abs(result.width - 153) < 0.01)
        #expect(abs(result.height - 198) < 0.01)
    }

    @Test("Coordinate conversion with non-zero-origin page")
    func coordinateConversionNonZeroOrigin() {
        // Source page with cropBox starting at (100, 100)
        let pageRect = CGRect(x: 100, y: 100, width: 400, height: 600)
        let normalized = CGRect(x: 0.0, y: 0.0, width: 1.0, height: 1.0)

        let result = normalizedToPDFPageCoordinates(normalized, pageRect: pageRect)

        // Full page should map to the full cropBox
        #expect(abs(result.origin.x - 100) < 0.01)
        #expect(abs(result.origin.y - 100) < 0.01)
        #expect(abs(result.width - 400) < 0.01)
        #expect(abs(result.height - 600) < 0.01)
    }

    @Test("Coordinate conversion maps corners correctly")
    func coordinateConversionCorners() {
        let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792)

        let topRight = normalizedToPDFPageCoordinates(
            CGRect(x: 0.75, y: 0.75, width: 0.25, height: 0.25),
            pageRect: pageRect
        )
        #expect(abs(topRight.maxX - 612) < 0.01)
        #expect(abs(topRight.maxY - 792) < 0.01)

        let bottomLeft = normalizedToPDFPageCoordinates(
            CGRect(x: 0, y: 0, width: 0.25, height: 0.25),
            pageRect: pageRect
        )
        #expect(abs(bottomLeft.origin.x) < 0.01)
        #expect(abs(bottomLeft.origin.y) < 0.01)
    }

    // MARK: - filterCharacters (ENGINE §5B.2)

    @Test("Characters inside redaction region are excluded")
    func charactersInsideRedactionExcluded() async throws {
        // Place characters with gaps so safety margin doesn't catch distant ones.
        // A at x=50, then B-C-D at x=100-145, then E at x=200.
        let chars = [
            CharacterInfo(character: "A", bounds: CGRect(x: 50, y: 400, width: 15, height: 15), stringIndex: 0),
            CharacterInfo(character: "B", bounds: CGRect(x: 100, y: 400, width: 15, height: 15), stringIndex: 1),
            CharacterInfo(character: "C", bounds: CGRect(x: 115, y: 400, width: 15, height: 15), stringIndex: 2),
            CharacterInfo(character: "D", bounds: CGRect(x: 130, y: 400, width: 15, height: 15), stringIndex: 3),
            CharacterInfo(character: "E", bounds: CGRect(x: 200, y: 400, width: 15, height: 15), stringIndex: 4),
        ]
        // Redaction covers characters B, C, D (x=100–145, y=398–418)
        let redactionRect = CGRect(x: 100, y: 398, width: 45, height: 20)

        let result = try await filterCharacters(
            characters: chars, redactionRects: [redactionRect]
        )

        let surviving = result.surviving.map(\.character).joined()
        #expect(!surviving.contains("B"))
        #expect(!surviving.contains("C"))
        #expect(!surviving.contains("D"))
        // A at x=50-65 is safely outside expanded rect (x=98–147)
        #expect(surviving.contains("A"))
        // E at x=200-215 is safely outside
        #expect(surviving.contains("E"))
    }

    @Test("Safety margin excludes characters near boundary")
    func safetyMarginExclusion() async throws {
        // Character at x=98, 2 points from redaction edge at x=100
        let chars = [
            CharacterInfo(character: "X", bounds: CGRect(x: 97, y: 400, width: 10, height: 15), stringIndex: 0),
            CharacterInfo(character: "Y", bounds: CGRect(x: 200, y: 400, width: 10, height: 15), stringIndex: 1),
        ]
        let redactionRect = CGRect(x: 100, y: 395, width: 50, height: 20)

        // With 2pt safety margin, X at x=97 with width=10 (maxX=107) should intersect
        // expanded rect at (98, 393, 54, 24)
        let result = try await filterCharacters(
            characters: chars, redactionRects: [redactionRect], safetyMargin: 2.0
        )

        let surviving = result.surviving.map(\.character).joined()
        #expect(!surviving.contains("X"), "Character within safety margin should be excluded")
        #expect(surviving.contains("Y"), "Character far from redaction should survive")
    }

    @Test("Full-page redaction excludes all characters")
    func fullPageRedactionExcludesAll() async throws {
        let chars = makeTestCharacters("Hello World", startX: 100, y: 400, charWidth: 15)
        // Full page rect covers everything
        let redactionRect = CGRect(x: 0, y: 0, width: 612, height: 792)

        let result = try await filterCharacters(
            characters: chars, redactionRects: [redactionRect]
        )

        #expect(result.surviving.isEmpty)
        #expect(result.excludedCount == chars.count)
    }

    @Test("No redaction preserves all characters")
    func noRedactionPreservesAll() async throws {
        let chars = makeTestCharacters("Hello", startX: 100, y: 400, charWidth: 15)

        let result = try await filterCharacters(
            characters: chars, redactionRects: []
        )

        #expect(result.surviving.count == chars.count)
        #expect(result.excludedCount == 0)
    }

    @Test("Surviving + excluded equals total")
    func survivesPlusExcludedEqualsTotal() async throws {
        let chars = makeTestCharacters("ABCDEFGHIJ", startX: 100, y: 400, charWidth: 15)
        let redactionRect = CGRect(x: 130, y: 395, width: 60, height: 20)

        let result = try await filterCharacters(
            characters: chars, redactionRects: [redactionRect]
        )

        #expect(result.surviving.count + result.excludedCount == result.totalCharacters)
    }

    // MARK: - FilterResult.toDigest (ENGINE §5B.2)

    @Test("Digest preserves same counts as FilterResult")
    func digestPreservesCounts() async throws {
        let chars = makeTestCharacters("ABCDEFGHIJ", startX: 100, y: 400, charWidth: 15)
        let redactionRect = CGRect(x: 130, y: 395, width: 60, height: 20)

        let result = try await filterCharacters(
            characters: chars, redactionRects: [redactionRect]
        )
        let digest = result.toDigest(
            pageIndex: 0,
            redactionRects: [redactionRect],
            safetyMargin: 2.0
        )

        #expect(digest.extractedCount == result.totalCharacters)
        #expect(digest.excludedCount == result.excludedCount)
        #expect(digest.survivingCount == result.surviving.count)
        #expect(digest.pageIndex == 0)
    }

    // MARK: - minEdgeDistance

    @Test("Edge distance for non-overlapping rects")
    func edgeDistanceNonOverlapping() {
        let char = CGRect(x: 100, y: 100, width: 10, height: 15)
        let rect = CGRect(x: 120, y: 100, width: 50, height: 20)

        let dist = minEdgeDistance(char, to: rect)
        #expect(abs(dist - 10.0) < 0.01)  // 120 - 110 = 10
    }

    @Test("Edge distance for overlapping rects is zero")
    func edgeDistanceOverlapping() {
        let char = CGRect(x: 100, y: 100, width: 30, height: 15)
        let rect = CGRect(x: 110, y: 100, width: 50, height: 20)

        let dist = minEdgeDistance(char, to: rect)
        #expect(dist == 0)
    }

    // MARK: - Integration with PDFKit

    @Test("Extract and filter characters from text layer PDF",
          .timeLimit(.minutes(1)))
    func extractAndFilter() async throws {
        let data = TestFixtures.textLayerPDF(text: "ABCDEFGHIJ KLMNOPQRST")
        let doc = try #require(PDFDocument(data: data))
        let page = try #require(doc.page(at: 0))

        let extractor = TextLayerExtractor()
        let characters = try await extractor.extractCharacters(from: page)
        #expect(!characters.isEmpty, "Should extract characters from text layer PDF")

        // Redact a region covering some characters
        let pageBounds = page.bounds(for: .cropBox)
        let normalizedRedaction = CGRect(x: 0.1, y: 0.85, width: 0.2, height: 0.1)
        let redactionInPoints = normalizedToPDFPageCoordinates(
            normalizedRedaction, pageRect: pageBounds
        )

        let result = try await filterCharacters(
            characters: characters,
            redactionRects: [redactionInPoints]
        )

        #expect(result.surviving.count < characters.count,
                "Some characters should be excluded by redaction")
        #expect(result.surviving.count + result.excludedCount == result.totalCharacters)
    }

    // MARK: - Boundary Character Test (TEST §3.6)

    @Test("Boundary character at exact safety margin edge",
          .timeLimit(.minutes(1)))
    func boundaryCharacterExcluded() async throws {
        let data = TestFixtures.boundaryCharacterPDF()
        let doc = try #require(PDFDocument(data: data))
        let page = try #require(doc.page(at: 0))

        let extractor = TextLayerExtractor()
        let characters = try await extractor.extractCharacters(from: page)
        #expect(characters.count >= 8, "Should extract all 8 characters from ABCDEFGH")

        // Find D and F bounds to construct redaction rect covering D-F
        let charMap = Dictionary(uniqueKeysWithValues: characters.map { ($0.character, $0.bounds) })
        guard let dBounds = charMap["D"], let fBounds = charMap["F"] else {
            Issue.record("Could not find D and F characters")
            return
        }

        let redactionRect = CGRect(
            x: dBounds.minX, y: dBounds.minY,
            width: fBounds.maxX - dBounds.minX,
            height: max(dBounds.height, fBounds.height)
        )

        let result = try await filterCharacters(
            characters: characters,
            redactionRects: [redactionRect],
            safetyMargin: 2.0
        )

        let survivingChars = result.surviving.map(\.character).joined()
        #expect(!survivingChars.contains("D"), "D must be excluded")
        #expect(!survivingChars.contains("E"), "E must be excluded")
        #expect(!survivingChars.contains("F"), "F must be excluded")
        #expect(survivingChars.contains("A"), "A should survive")
        #expect(survivingChars.contains("B"), "B should survive")
        #expect(survivingChars.contains("H"), "H should survive")
    }

    // MARK: - H2: Polygon Safety Margin via Char-Bounds Expansion

    @Test("Polygon halo character is excluded (H2)")
    func polygonHaloCharExcluded() async throws {
        // Square polygon at (100,400)-(150,450). Bounding rect 100..150 x 400..450,
        // safety-margin-expanded to 97..153 x 397..453.
        //   "X" sits 2pt outside the polygon's right edge — inside the 3pt halo.
        //   "Y" sits 10pt outside — outside the halo.
        //   "Z" sits inside the polygon.
        // Pre-H2: rectIntersectsPolygon(char.bounds, vertices) used the
        //   *un-expanded* char vs the *un-expanded* polygon, so X survived
        //   despite being inside the halo.
        // Post-H2: rectIntersectsPolygon(expandedChar, vertices) where
        //   expandedChar = char.bounds.insetBy(-3, -3) restores the halo.
        let polygonRect = CGRect(x: 100, y: 400, width: 50, height: 50)
        let polygonVerts: [CGPoint] = [
            CGPoint(x: 100, y: 400),
            CGPoint(x: 150, y: 400),
            CGPoint(x: 150, y: 450),
            CGPoint(x: 100, y: 450),
        ]
        let shape = RegionShape(
            expandedBounds: polygonRect.insetBy(
                dx: -safetyMarginPoints, dy: -safetyMarginPoints
            ),
            polygonVertices: polygonVerts
        )

        let chars = [
            CharacterInfo(character: "X",
                          bounds: CGRect(x: 152, y: 415, width: 5, height: 10),
                          stringIndex: 0),
            CharacterInfo(character: "Y",
                          bounds: CGRect(x: 160, y: 415, width: 5, height: 10),
                          stringIndex: 1),
            CharacterInfo(character: "Z",
                          bounds: CGRect(x: 110, y: 415, width: 5, height: 10),
                          stringIndex: 2),
        ]

        let result = try await filterCharacters(characters: chars, regionShapes: [shape])
        let surviving = result.surviving.map(\.character).joined()

        #expect(!surviving.contains("X"),
                "H2: char within 3pt of polygon edge must be excluded")
        #expect(!surviving.contains("Z"),
                "char inside polygon must be excluded")
        #expect(surviving.contains("Y"),
                "char well outside polygon halo should survive")
    }

    @Test("Polygon halo does not double-expand rect-only regions (H2)")
    func polygonHaloRectOnlyRegionUnchanged() async throws {
        // Rect-only RegionShape (polygonVertices == nil). The fix must not
        // alter rect-path behaviour — expandedBounds already carries the
        // 3pt halo and the un-expanded char.bounds suffices.
        let rect = CGRect(x: 100, y: 400, width: 50, height: 50)
        let shape = RegionShape(
            expandedBounds: rect.insetBy(
                dx: -safetyMarginPoints, dy: -safetyMarginPoints
            ),
            polygonVertices: nil
        )

        let chars = [
            CharacterInfo(character: "A",
                          bounds: CGRect(x: 152, y: 415, width: 5, height: 10),
                          stringIndex: 0),
            CharacterInfo(character: "B",
                          bounds: CGRect(x: 160, y: 415, width: 5, height: 10),
                          stringIndex: 1),
        ]

        let result = try await filterCharacters(characters: chars, regionShapes: [shape])
        let surviving = result.surviving.map(\.character).joined()
        // A at x=152 sits 2pt outside the rect (right edge at x=150), inside
        // the 3pt halo — must be excluded by the bounding rect overlap alone.
        #expect(!surviving.contains("A"))
        // B at x=160 sits outside the halo — survives.
        #expect(surviving.contains("B"))
    }

    // MARK: - Helpers

    /// Create test CharacterInfo array with predictable positions.
    private func makeTestCharacters(
        _ text: String, startX: CGFloat, y: CGFloat, charWidth: CGFloat
    ) -> [CharacterInfo] {
        text.enumerated().map { (i, char) in
            CharacterInfo(
                character: String(char),
                bounds: CGRect(x: startX + CGFloat(i) * charWidth, y: y,
                               width: charWidth, height: 15),
                stringIndex: i
            )
        }
    }

    // MARK: - CAT-366: CropBox-local end-to-end (D-34 canonical coordinate contract)

    @Test("CAT-366: a zero-origin output region redacts non-zero-origin source text",
          .timeLimit(.minutes(1)))
    func nonZeroCropBoxCharacterFilter() async throws {
        let data = TestFixtures.nonZeroOriginDiscriminatingPDF()
        let doc = try #require(PDFDocument(data: data))
        let page = try #require(doc.page(at: 0))
        let cropBox = page.bounds(for: .cropBox)

        let chars = try await TextLayerExtractor().extractCharacters(from: page)
        #expect(!chars.isEmpty, "fixture must yield extractable characters")

        // The region is given in zero-origin OUTPUT-page normalized coordinates
        // and converted through the rasterizer's POST-CAT-366 basis
        // (CGRect(origin: .zero, size: effectiveSize)) — exactly what
        // PageRasterizer feeds the filter once the basis is switched. It covers
        // the text's cropBox-LOCAL position (x ≈ [0,214], y ≈ [396,594]).
        // Pre-fix the extracted characters are still absolute (x ≈ 220, y ≈ 700)
        // and escape this zero-origin region → red. After CAT-366 they are local
        // and fall inside it → green.
        let effectiveSize = cropBox.size
        let regionRect = normalizedToPDFPageCoordinates(
            CGRect(x: 0, y: 0.5, width: 0.35, height: 0.25),
            pageRect: CGRect(origin: .zero, size: effectiveSize))
        let result = try await filterCharacters(
            characters: chars, redactionRects: [regionRect])
        #expect(result.surviving.isEmpty,
                "text under the zero-origin output region must be filtered out")
        #expect(result.excludedCount == chars.count,
                "every extracted character lies under the region post-CAT-366")
    }

    @Test("CAT-366: the lineage digest is translation-invariant across cropBox origins",
          .timeLimit(.minutes(1)))
    func nonZeroCropBoxDigestTranslationInvariant() async throws {
        // Two fixtures with identical text but different cropBox origins. The
        // lineage hash is coordinate-free ((character, globalPos) in band
        // order), so CAT-366's uniform coordinate shift cannot perturb it.
        func extract(_ data: Data) async throws -> [CharacterInfo] {
            let doc = try #require(PDFDocument(data: data))
            let page = try #require(doc.page(at: 0))
            return try await TextLayerExtractor().extractCharacters(from: page)
        }
        let a = try await extract(TestFixtures.nonZeroOriginPDF())
        let b = try await extract(TestFixtures.nonZeroOriginDiscriminatingPDF())
        #expect(!a.isEmpty && !b.isEmpty, "both fixtures must yield characters")

        let hashA = FilterResult.computeLineageHash(over: a)
        let hashB = FilterResult.computeLineageHash(over: b)
        #expect(hashA == hashB,
                "identical text at different cropBox origins must hash identically")
    }
}
