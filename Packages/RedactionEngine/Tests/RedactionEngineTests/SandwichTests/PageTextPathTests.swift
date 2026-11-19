import Testing
import Foundation
import PDFKit
import CoreText
@testable import RedactionEngine

@Suite("A Searchable page's one text path", .tags(.sandwich))
struct PageTextPathTests {

    // A page of invented words, made on the joined-glyph builder (named,
    // unembedded font; painted ink).
    static let lines = ["Alpha beta gamma", "delta epsilon"]

    static func entries() async throws -> (entries: [CharacterInfo], text: String, size: CGSize) {
        let document = try #require(PDFDocument(data: TestFixtures.joinedGlyphPDF(lines: lines)))
        let page = try #require(document.page(at: 0))
        let entries = try await TextLayerExtractor().extractCharacters(from: page, hasHiddenOCG: false)
        return (entries, try #require(page.string), page.bounds(for: .cropBox).size)
    }

    /// A region over the word "beta" on the first line, in page points.
    static func betaRegion(_ entries: [CharacterInfo]) throws -> CGRect {
        let letters = entries.filter { $0.lineIndex == 0 && "beta".contains($0.character) && $0.stringIndex >= 6 && $0.stringIndex <= 9 }
        #expect(letters.count == 4)
        return letters.map(\.bounds).reduce(letters[0].bounds) { $0.union($1) }
    }

    @Test("The text walk gives each entry its word by the page's one partition")
    func wordIndexFromThePartition() async throws {
        let (entries, text, _) = try await Self.entries()
        let indices = WordPartition.wordIndices(of: text)
        #expect(!entries.isEmpty)
        for entry in entries {
            #expect(entry.wordIndex == indices[entry.stringIndex], "\(entry.character) at \(entry.stringIndex)")
        }
        // Five words, so at least five indices among the letters.
        let letters = entries.filter { !$0.character.allSatisfy(\.isWhitespace) }
        #expect(Set(letters.map(\.wordIndex)).count == 5)
    }

    @Test("An entry carried into a turned page's source frame keeps its word")
    func sourceEntryKeepsItsWord() {
        let entry = CharacterInfo(character: "a", bounds: CGRect(x: 10, y: 20, width: 5, height: 8),
                                  stringIndex: 3, lineIndex: 1, wordIndex: 7)
        for rotation in [90, 180, 270] {
            let frame = PageFrame(rotation: rotation, displayedSize: CGSize(width: 792, height: 612))
            #expect(frame.sourceEntry(entry).wordIndex == 7)
        }
        #expect(CharacterInfo(character: "a", bounds: .zero, stringIndex: 0).wordIndex == 0)
    }

    @Test("With its real steps the path gives what the filter, the drawn-cell rule and the record give")
    func pathEqualsTheStepsComposed() async throws {
        let (entries, _, size) = try await Self.entries()
        let region = try Self.betaRegion(entries)
        let frame = PageFrame(rotation: 0, displayedSize: size)

        let filtered = try await filterCharacters(characters: entries, redactionRects: [region])
        let shapes = [RegionShape(expandedBounds: region.insetBy(dx: -safetyMarginPoints, dy: -safetyMarginPoints),
                                  bounds: region)]
        let validated = TextLayerReconstructor.validateSurvivors(filtered, regionShapes: shapes, frame: frame)
        let digest = validated.result.toDigest(
            pageIndex: 0, redactionRects: [region], safetyMargin: safetyMarginPoints,
            drawnCellRuleExcludedCount: validated.dropped, frame: frame)

        let path = try await PageTextPath.run(
            entries: entries, frame: frame,
            textPathRectangles: [TextPathRectangle(rect: region, kind: .ordinary)],
            paintedRectangles: [], pageIndex: 0)
        guard case .written(let written, let recorded, let rects) = path.outcome else {
            Issue.record("the page is written"); return
        }
        #expect(validated.settled)
        #expect(written.map(\.stringIndex) == validated.result.surviving.map(\.stringIndex))
        #expect(written.map(\.character) == validated.result.surviving.map(\.character))
        #expect(written.map(\.bounds) == validated.result.surviving.map(\.bounds))
        #expect(recorded.extractedCount == digest.extractedCount)
        #expect(recorded.excludedCount == digest.excludedCount)
        #expect(recorded.survivingCount == digest.survivingCount)
        #expect(recorded.lineageHash == digest.lineageHash)
        #expect(rects == [region])
        #expect(path.runsLeftOut == 0)
        #expect(path.drawnCellDropped == validated.dropped)
        // The filter took "beta".
        #expect(written.count < entries.count)
    }

    @Test("A rectangle under a widened box is read by no step of the path")
    func underWidenedBoxIsNotRead() async throws {
        let (entries, _, size) = try await Self.entries()
        let region = try Self.betaRegion(entries)
        let frame = PageFrame(rotation: 0, displayedSize: size)
        let plain = try await PageTextPath.run(
            entries: entries, frame: frame,
            textPathRectangles: [TextPathRectangle(rect: region, kind: .ordinary)],
            paintedRectangles: [], pageIndex: 0)
        let withWidened = try await PageTextPath.run(
            entries: entries, frame: frame,
            textPathRectangles: [TextPathRectangle(rect: region, kind: .ordinary),
                                 TextPathRectangle(rect: CGRect(x: 0, y: 0, width: 612, height: 792), kind: .underWidenedBox)],
            paintedRectangles: [], pageIndex: 0)
        guard case .written(let a, let da, let ra) = plain.outcome,
              case .written(let b, let db, let rb) = withWidened.outcome else {
            Issue.record("both pages are written"); return
        }
        #expect(a.map(\.stringIndex) == b.map(\.stringIndex))
        #expect(da.lineageHash == db.lineageHash)
        #expect(ra == rb)
    }

    @Test("The fold and the alphabet marks change nothing until the alphabet fills them")
    func stubsChangeNothing() async throws {
        let (entries, _, _) = try await Self.entries()
        let folded = TextPathFold.fold(entries)
        #expect(folded.map(\.character) == entries.map(\.character))
        #expect(folded.map(\.stringIndex) == entries.map(\.stringIndex))
        #expect(TextPathAlphabetMarks.marks(entries) == .none)
    }

    /// The point sizes the drawn-cell rule's metrics are compared at.
    static let sizes: [CGFloat] = stride(from: 4.0, through: 30.0, by: 0.5).map { CGFloat($0) }

    @Test("The sizes compared are fifty-three")
    func sizesCount() {
        #expect(Self.sizes.count == 53)
    }

    @Test("The laid-out line is in the first of the three faces this system has, at its size, with Courier's own ascent and descent")
    func laidOutLineIsCourier() throws {
        for size in Self.sizes {
            let line = try #require(HiddenTextLine.layout("Report 12", size: size))
            let runs = CTLineGetGlyphRuns(line) as! [CTRun]
            #expect(runs.count == 1)
            let attributes = CTRunGetAttributes(runs[0]) as NSDictionary
            let font = attributes[kCTFontAttributeName as String] as! CTFont
            // Courier itself where the system has it; where the name maps
            // to Menlo, the first face the system does have.
            #expect(CTFontCopyPostScriptName(font) as String == HiddenTextFonts.faces.first?.name)
            #expect(CTFontGetSize(font) == size)
            var ascent: CGFloat = 0, descent: CGFloat = 0
            CTLineGetTypographicBounds(line, &ascent, &descent, nil)
            let courier = CTFontCreateWithName("Courier" as CFString, size, nil)
            #expect(ascent == CTFontGetAscent(courier), "\(size)")
            #expect(descent == CTFontGetDescent(courier), "\(size)")
        }
    }

    /// Lines with a character Courier has no glyph for, which the system
    /// draws in a face of its own, and a line of only zero-width marks.
    static let mixedLines = ["Report \u{6F22} 12", "Report \u{F0B7} 12", "\u{200B}\u{FEFF}"]

    @Test("On a line with a run the system draws in another face, every cell keeps Courier's own height and centre",
          arguments: mixedLines)
    func mixedLineKeepsCourierCells(_ text: String) throws {
        var entries: [CharacterInfo] = []
        var word = 0
        for (i, scalar) in text.unicodeScalars.enumerated() {
            if scalar == " " { word += 1 }
            entries.append(CharacterInfo(
                character: String(scalar), bounds: CGRect(x: 72 + CGFloat(i) * 7.2, y: 700, width: 7.2, height: 12),
                stringIndex: i, lineIndex: 0, wordIndex: word))
        }
        let lines = TextLayerReconstructor.layoutLinesWithSources(entries, pageWidth: 612, redactionRects: [])
        try #require(lines.count == 1, "\(lines.map(\.line.text))")
        let line = lines[0].line
        let courier = CTFontCreateWithName("Courier" as CFString, line.fontSize, nil)
        let ascent = CTFontGetAscent(courier), descent = CTFontGetDescent(courier)
        if text.unicodeScalars.contains("\u{6F22}") {
            // The case has power: this line's own bounds are not Courier's,
            // so a cell measured by them would sit elsewhere.
            let laid = try #require(HiddenTextLine.layout(line.text, size: line.fontSize))
            var lineAscent: CGFloat = 0, lineDescent: CGFloat = 0
            CTLineGetTypographicBounds(laid, &lineAscent, &lineDescent, nil)
            #expect(lineAscent + lineDescent > ascent + descent + 0.2,
                    "line \(lineAscent)+\(lineDescent), Courier \(ascent)+\(descent)")
        }
        // The base formula's centre: the cell from the baseline less
        // Courier's descent, Courier's ascent plus descent tall.
        let centreY = line.origin.y - descent + (ascent + descent) / 2
        let strip = CGRect(x: 0, y: centreY - 0.05, width: 612, height: 0.1)
        let found = TextLayerReconstructor.drawnCellHits(
            entries: entries, pageWidth: 612,
            regionShapes: [RegionShape(expandedBounds: strip, bounds: strip)])
        #expect(found.laidOut)
        #expect(found.hits == IndexSet(entries.indices), "\(text.debugDescription): hit \(Array(found.hits)) of \(entries.count)")
    }

    struct Fault: Error {}

    @Test("A step that throws makes the path throw")
    func faultingStepThrows() async throws {
        let (entries, _, size) = try await Self.entries()
        var steps = PageTextPath.Steps.live
        steps.fold = { _ in throw Fault() }
        await #expect(throws: Fault.self) {
            try await PageTextPath.$steps.withValue(steps) {
                try await PageTextPath.run(
                    entries: entries, frame: PageFrame(rotation: 0, displayedSize: size),
                    textPathRectangles: [], paintedRectangles: [], pageIndex: 0)
            }
        }
    }

    @Test("A line that cannot be laid out makes the page a picture, with a region on it or none")
    func unlaidLineMakesAPicture() async throws {
        let (entries, _, size) = try await Self.entries()
        let frame = PageFrame(rotation: 0, displayedSize: size)
        let region = try Self.betaRegion(entries)
        for rectangles in [[], [TextPathRectangle(rect: region, kind: .ordinary)]] {
            let control = try await PageTextPath.run(
                entries: entries, frame: frame,
                textPathRectangles: rectangles, paintedRectangles: [], pageIndex: 0)
            guard case .written = control.outcome else {
                Issue.record("control with \(rectangles.count) region(s): \(control.outcome)")
                continue
            }
            let refused = try await HiddenTextLine.$refuses.withValue({ _ in true }) {
                try await PageTextPath.run(
                    entries: entries, frame: frame,
                    textPathRectangles: rectangles, paintedRectangles: [], pageIndex: 0)
            }
            guard case .picture(let reason) = refused.outcome else {
                Issue.record("with \(rectangles.count) region(s): \(refused.outcome)")
                continue
            }
            #expect(reason == .extractionFailed, "with \(rectangles.count) region(s)")
        }
        let found = HiddenTextLine.$refuses.withValue({ _ in true }) {
            TextLayerReconstructor.drawnCellHits(entries: entries, pageWidth: size.width, regionShapes: [])
        }
        #expect(!found.laidOut)
        #expect(found.hits.isEmpty)
    }

    @Test("The whole-word closure leaves each marked word out whole and counts it")
    func closureOverMarkedWords() async throws {
        let (entries, _, _) = try await Self.entries()
        let result = FilterResult(surviving: entries, totalCharacters: entries.count, excludedCount: 0)
        #expect(PageTextPath.closeOverMarkedWords(result, marked: []).surviving.count == entries.count)
        let beta = entries.filter { $0.stringIndex >= 6 && $0.stringIndex <= 9 }.map(\.wordIndex)
        let marked = Set(beta)
        #expect(marked.count == 1)
        let closed = PageTextPath.closeOverMarkedWords(result, marked: marked)
        #expect(closed.surviving.allSatisfy { !marked.contains($0.wordIndex) })
        let left = entries.filter { marked.contains($0.wordIndex) }.count
        #expect(closed.excludedCount == left)
        #expect(closed.surviving.count == entries.count - left)
    }

    @Test("A page the alphabet rule leaves with no word is a picture with its count; one the boxes empty is written empty")
    func pageLeftWithNoWord() async throws {
        let (entries, _, size) = try await Self.entries()
        let frame = PageFrame(rotation: 0, displayedSize: size)
        var steps = PageTextPath.Steps.live
        let every = Set(entries.map(\.wordIndex))
        steps.alphabetMarks = { _ in
            TextPathAlphabetMarks.Marks(wordIndices: every, runsLeftOut: 5, reasonIfNoWordLeft: .noExtractableText)
        }
        let marked = try await PageTextPath.$steps.withValue(steps) {
            try await PageTextPath.run(entries: entries, frame: frame, textPathRectangles: [],
                                       paintedRectangles: [], pageIndex: 0)
        }
        guard case .picture(let reason) = marked.outcome else { Issue.record("a picture"); return }
        #expect(reason == .noExtractableText)
        #expect(marked.runsLeftOut == 5)

        let whole = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        let boxed = try await PageTextPath.run(
            entries: entries, frame: frame,
            textPathRectangles: [TextPathRectangle(rect: whole, kind: .ordinary)],
            paintedRectangles: [], pageIndex: 0)
        guard case .written(let left, _, _) = boxed.outcome else { Issue.record("written"); return }
        #expect(left.isEmpty)
        #expect(boxed.runsLeftOut == 0)
    }

    @Test("A page's output carries its count of runs left out, zero unless given")
    func pageOutputCarriesTheCount() throws {
        let context = try #require(CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        #expect(PageOutput(image: image, size: .zero, textLayerEntries: nil).runsLeftOut == 0)
        #expect(PageOutput(image: image, size: .zero, textLayerEntries: [], runsLeftOut: 3).runsLeftOut == 3)
    }
}
