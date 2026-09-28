import Testing
import Foundation
import CoreGraphics
import PDFKit
import UIKit
import RedactionEngine
@testable import ResectaApp

// The manual-region text identity (the third origin joins the term
// layers): at run entry the words fully inside every `.manual` region on
// a rich-text-layer page are captured through the engine's word-span
// primitive and join the sensitive-term set — a multi-word region as one
// substring term plus its single tokens boundary-required; a single-word
// region as that one boundary-required token. Regions on pages whose text
// layer is not rich are counted, not captured (Layer 3 names them);
// whole-page regions are skipped (the whole-page rule); every other origin is untouched.

@Suite("Manual-region term capture")
struct ManualTermsCaptureTests {

    private enum TestError: Error { case failed }

    /// One page, Helvetica 24: "John Smith" on the upper line, "Springfield"
    /// on the lower one — a rich text layer with word boxes PDFKit reports.
    private static func textPDF() -> PDFDocument {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
        let data = renderer.pdfData { ctx in
            ctx.beginPage()
            let attrs: [NSAttributedString.Key: Any] = [.font: UIFont(name: "Helvetica", size: 24)!,
                                                        .foregroundColor: UIColor.black]
            ("John Smith" as NSString).draw(at: CGPoint(x: 72, y: 80), withAttributes: attrs)
            ("Springfield" as NSString).draw(at: CGPoint(x: 72, y: 180), withAttributes: attrs)
        }
        return PDFDocument(data: data)!
    }

    private static let unit = CGRect(x: 0, y: 0, width: 1, height: 1)

    /// Every word's normalized rect on page 0, keyed by text.
    private static func wordRects(_ doc: PDFDocument) throws -> [String: CGRect] {
        guard let page = doc.page(at: 0) else { throw TestError.failed }
        return Dictionary(TextLayerSpans.words(fullyInside: unit, on: page).map { ($0.text, $0.normalizedRect) },
                          uniquingKeysWith: { a, _ in a })
    }

    private static func manual(_ rect: CGRect, vertices: [CGPoint]? = nil) -> RedactionRegion {
        RedactionRegion(id: UUID(), normalizedRect: rect, source: .manual, vertices: vertices)
    }

    /// A one-point halo around a rect (in normalized units of a 612 × 792 page).
    private static func padded(_ rect: CGRect) -> CGRect {
        rect.insetBy(dx: -1 / 612, dy: -1 / 792)
    }

    private static func table(_ set: SensitiveTermSet) -> [String: Bool] {
        Dictionary(uniqueKeysWithValues: set.terms.map { ($0.text, $0.requiresTokenBoundary) })
    }

    @Test("Two manual rects on a rich page: the joined term plus the boundary-required tokens; a single word is one bounded token")
    func richPageCapturesWords() throws {
        let doc = Self.textPDF()
        let rects = try Self.wordRects(doc)
        let john = try #require(rects["John"]); let smith = try #require(rects["Smith"])
        let springfield = try #require(rects["Springfield"])
        let set = PipelineCoordinator.sensitiveTermSet(
            applied: [],
            manualRegions: [0: [Self.manual(Self.padded(john.union(smith))), Self.manual(Self.padded(springfield))]],
            in: doc, textLayerStatus: [0: .rich])
        #expect(Self.table(set) == ["John Smith": false, "John": true, "Smith": true, "Springfield": true])
        #expect(set.terms.map(\.text) == set.terms.map(\.text).sorted())
        #expect(set.manualRegionsWithoutText == 0)
    }

    @Test("A manual rect on a page whose text layer is not rich is counted, not captured",
          arguments: [TextLayerStatus.none, .sparse])
    func nonRichPageIsCounted(status: TextLayerStatus) throws {
        let doc = Self.textPDF()
        let rects = try Self.wordRects(doc)
        let john = try #require(rects["John"])
        let set = PipelineCoordinator.sensitiveTermSet(
            applied: [SensitiveTerm(text: "Delia Hartwell")],
            manualRegions: [0: [Self.manual(Self.padded(john))]],
            in: doc, textLayerStatus: [0: status])
        #expect(set.terms == [SensitiveTerm(text: "Delia Hartwell")])
        #expect(set.manualRegionsWithoutText == 1)
    }

    @Test("A page with no status entry is not rich")
    func missingStatusIsNotRich() throws {
        let doc = Self.textPDF()
        let john = try #require(try Self.wordRects(doc)["John"])
        let set = PipelineCoordinator.sensitiveTermSet(
            applied: [], manualRegions: [0: [Self.manual(Self.padded(john))]], in: doc, textLayerStatus: [:])
        #expect(set.terms.isEmpty)
        #expect(set.manualRegionsWithoutText == 1)
    }

    @Test("A whole-page region adds no term and is not counted, on any page")
    func wholePageRegionIsSkipped() throws {
        let doc = Self.textPDF()
        let whole = Self.manual(CGRect(x: 0, y: 0, width: 1, height: 1))
        let nearlyWhole = Self.manual(CGRect(x: 0.01, y: 0.01, width: 0.98, height: 0.98))
        for status in [TextLayerStatus.rich, .none] {
            let set = PipelineCoordinator.sensitiveTermSet(
                applied: [], manualRegions: [0: [whole, nearlyWhole]], in: doc, textLayerStatus: [0: status])
            #expect(set.terms.isEmpty, "\(status)")
            #expect(set.manualRegionsWithoutText == 0, "\(status)")
        }
    }

    @Test("Only `.manual` regions are captured; a search-match or detected region is untouched")
    func otherOriginsAreUntouched() throws {
        let doc = Self.textPDF()
        let rects = try Self.wordRects(doc)
        let john = try #require(rects["John"]); let smith = try #require(rects["Smith"])
        let search = RedactionRegion(id: UUID(), normalizedRect: Self.padded(john.union(smith)), source: .searchMatch(term: "John"))
        let detected = RedactionRegion(id: UUID(), normalizedRect: Self.padded(rects["Springfield"]!), source: .detectedPII(kind: .name))
        let set = PipelineCoordinator.sensitiveTermSet(
            applied: [SensitiveTerm(text: "John")], manualRegions: [0: [search, detected]],
            in: doc, textLayerStatus: [0: .rich])
        #expect(set.terms == [SensitiveTerm(text: "John")])
        #expect(set.manualRegionsWithoutText == 0)
        // And on an image-only page they are not counted either.
        let none = PipelineCoordinator.sensitiveTermSet(
            applied: [], manualRegions: [0: [search, detected]], in: doc, textLayerStatus: [0: .none])
        #expect(none.manualRegionsWithoutText == 0)
    }

    @Test("Dedup with the applied set keeps the least restrictive discipline")
    func dedupKeepsSubstringMatching() throws {
        let doc = Self.textPDF()
        let springfield = try #require(try Self.wordRects(doc)["Springfield"])
        // A detected region already contributed "Springfield" as a plain
        // substring term; the manual capture's boundary-required token folds into it.
        let set = PipelineCoordinator.sensitiveTermSet(
            applied: [SensitiveTerm(text: "Springfield"), SensitiveTerm(text: "Delia Hartwell")],
            manualRegions: [0: [Self.manual(Self.padded(springfield))]],
            in: doc, textLayerStatus: [0: .rich])
        #expect(Self.table(set) == ["Springfield": false, "Delia Hartwell": false])
    }

    @Test("A polygon region captures only the words whose centre lies inside it")
    func polygonNarrowsTheRect() throws {
        let doc = Self.textPDF()
        let rects = try Self.wordRects(doc)
        let john = try #require(rects["John"]); let smith = try #require(rects["Smith"])
        let bounds = Self.padded(john.union(smith))
        // A triangle over the left part of the line: John's centre inside, Smith's outside.
        let triangle = [
            CGPoint(x: bounds.minX, y: bounds.minY),
            CGPoint(x: john.maxX + (smith.minX - john.maxX) / 2, y: bounds.minY),
            CGPoint(x: bounds.minX, y: bounds.maxY),
        ]
        let set = PipelineCoordinator.sensitiveTermSet(
            applied: [], manualRegions: [0: [Self.manual(bounds, vertices: triangle)]],
            in: doc, textLayerStatus: [0: .rich])
        #expect(Self.table(set) == ["John": true])
    }

    @Test("A rich-page manual region over no words is counted like a region without text")
    func richPageRegionOverBlankSpaceIsCounted() throws {
        let doc = Self.textPDF()
        let set = PipelineCoordinator.sensitiveTermSet(
            applied: [], manualRegions: [0: [Self.manual(CGRect(x: 0.6, y: 0.6, width: 0.2, height: 0.1))]],
            in: doc, textLayerStatus: [0: .rich])
        #expect(set.terms.isEmpty)
        #expect(set.manualRegionsWithoutText == 1)
    }

    @Test("SensitiveTermSet is one value; the empty set has no terms and no count")
    func sensitiveTermSetIsAValue() {
        let a = SensitiveTermSet(terms: [SensitiveTerm(text: "x")], manualRegionsWithoutText: 2)
        let b = SensitiveTermSet(terms: [SensitiveTerm(text: "x")], manualRegionsWithoutText: 2)
        #expect(a == b)
        #expect(SensitiveTermSet.empty.terms.isEmpty)
        #expect(SensitiveTermSet.empty.manualRegionsWithoutText == 0)
        #expect(SensitiveTermSet(terms: []) == .empty)
    }

    @Test("The coordinator's run-entry set joins the applied terms and the manual capture")
    @MainActor
    func coordinatorCollectsTheSet() async throws {
        let coord = makeCoordinator()
        let doc = Self.textPDF()
        coord.documentState.sourceDocument = doc
        coord.documentState.textLayerStatus = [0: .rich]
        let rects = try Self.wordRects(doc)
        let springfield = try #require(rects["Springfield"])
        coord.redactionState.regions[0] = [Self.manual(Self.padded(springfield))]
        let set = await coord.collectSensitiveTermSet()
        #expect(set.terms == [SensitiveTerm(text: "Springfield", requiresTokenBoundary: true)])
        #expect(set.manualRegionsWithoutText == 0)
        // Without a document the set is the applied terms alone.
        coord.documentState.sourceDocument = nil
        #expect(await coord.collectSensitiveTermSet() == .empty)
    }
}
