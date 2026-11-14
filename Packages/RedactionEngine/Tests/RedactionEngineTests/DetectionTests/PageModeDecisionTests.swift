import Testing
import Foundation
import CoreGraphics
import PDFKit
@testable import RedactionEngine

// The one per-page mode decision (`PageModeDecision.decide`) that the app's
// run inputs and the verification corpus's runner both call: its arms in
// order, the page facts read only when a box needs them, the runner's seeds
// marked as placed from the page's text, and the trigger check called from
// that one place.

@Suite("Page mode decision")
struct PageModeDecisionTests {

    typealias Reason = TextLayerDetector.FallbackReason

    static let notPlain = PageContentFacts(reachesImage: true, drawsInlineImage: false, showsInvisibleText: false, usesType3Font: false)
    static let plain = PageContentFacts(reachesImage: false, drawsInlineImage: false, showsInvisibleText: false, usesType3Font: false)
    static let box = CGRect(x: 0.2, y: 0.5, width: 0.1, height: 0.02)

    static func region(anchored: Bool) -> RedactionRegion {
        RedactionRegion(id: UUID(), normalizedRect: box, source: anchored ? .searchMatch(term: "fox") : .manual,
                        textAnchored: anchored)
    }

    static func typedPage() throws -> PDFPage {
        try #require(PDFDocument(data: TestFixtures.textLayerPDF(text: "The quick brown fox jumps over the lazy dog"))?.page(at: 0))
    }

    /// Four distinct characters over at least fifty: the low-diversity trigger.
    static func triggerPage() throws -> PDFPage {
        try #require(PDFDocument(data: TestFixtures.textLayerPDF(text: String(repeating: "ababa cbcbc ", count: 6), fontSize: 12))?.page(at: 0))
    }

    struct Row {
        let name: String
        let mode: PipelineMode
        let status: TextLayerStatus
        let page: PDFPage
        let regions: [RedactionRegion]
        let inkPlanCovers: Bool
        let facts: PageContentFacts
        let expected: (PipelineMode, Reason?)
    }

    @Test("the arms in order: the other mode, no rich text, a trigger, an unanchored box, then Searchable")
    func table() throws {
        let typed = try Self.typedPage()
        let rows = [
            Row(name: "a run in the other mode", mode: .secureRasterization, status: .rich, page: typed,
                regions: [Self.region(anchored: false)], inkPlanCovers: false, facts: Self.notPlain,
                expected: (.secureRasterization, nil)),
            Row(name: "a page without rich text", mode: .searchableRedaction, status: .sparse, page: typed,
                regions: [Self.region(anchored: true)], inkPlanCovers: false, facts: Self.plain,
                expected: (.secureRasterization, .noExtractableText)),
            Row(name: "a trigger", mode: .searchableRedaction, status: .rich, page: try Self.triggerPage(),
                regions: [Self.region(anchored: true)], inkPlanCovers: false, facts: Self.plain,
                expected: (.secureRasterization, .unresolvedEncoding)),
            Row(name: "an unanchored box on a page that is not plain", mode: .searchableRedaction, status: .rich, page: typed,
                regions: [Self.region(anchored: false)], inkPlanCovers: false, facts: Self.notPlain,
                expected: (.secureRasterization, .unanchoredRegion)),
            Row(name: "the same, with an ink plan that covers it", mode: .searchableRedaction, status: .rich, page: typed,
                regions: [Self.region(anchored: false)], inkPlanCovers: true, facts: Self.notPlain,
                expected: (.searchableRedaction, nil)),
            Row(name: "an unanchored box on a plain page", mode: .searchableRedaction, status: .rich, page: typed,
                regions: [Self.region(anchored: false)], inkPlanCovers: false, facts: Self.plain,
                expected: (.searchableRedaction, nil)),
            Row(name: "an anchored box on a page that is not plain", mode: .searchableRedaction, status: .rich, page: typed,
                regions: [Self.region(anchored: true)], inkPlanCovers: false, facts: Self.notPlain,
                expected: (.searchableRedaction, nil)),
        ]
        #expect(rows.count == 7)
        for row in rows {
            let got = PageModeDecision.decide(
                effectiveMode: row.mode, textLayerStatus: row.status, page: row.page,
                pageRegions: row.regions, inkPlanCovers: row.inkPlanCovers, readFacts: { _ in row.facts })
            #expect(got.mode == row.expected.0, "\(row.name): mode \(got.mode)")
            #expect(got.fallbackReason == row.expected.1, "\(row.name): reason \(String(describing: got.fallbackReason))")
        }
    }

    @Test("the page's facts are not read when every box is anchored")
    func factsNotReadWhenAnchored() throws {
        let page = try Self.typedPage()
        var reads = 0
        let read: (CGPDFPage?) -> PageContentFacts = { _ in reads += 1; return Self.notPlain }
        let anchored = PageModeDecision.decide(
            effectiveMode: .searchableRedaction, textLayerStatus: .rich, page: page,
            pageRegions: [Self.region(anchored: true), Self.region(anchored: true)], inkPlanCovers: false, readFacts: read)
        #expect(reads == 0)
        #expect(anchored.mode == .searchableRedaction)
        _ = PageModeDecision.decide(
            effectiveMode: .searchableRedaction, textLayerStatus: .rich, page: page,
            pageRegions: [Self.region(anchored: true), Self.region(anchored: false)], inkPlanCovers: false, readFacts: read)
        #expect(reads == 1, "control: one unanchored box reads the facts once")
    }

    @Test("the corpus runner: a page that is not plain, with a seed, stays Searchable")
    func runnerSeedOnAPageThatIsNotPlainStaysSearchable() throws {
        let doc = try PageContentFactsTests.page("q 60 0 0 30 480 740 cm /Im1 Do Q\n" + PageContentFactsTests.text,
                                                 resources: "/Font << /F1 5 0 R >> /XObject << /Im1 6 0 R >>",
                                                 extra: [PDFObject(id: 6, content: PageContentFactsTests.image)])
        #expect(!PageContentFacts.read(try #require(doc.page(at: 0)).pageRef).isPlain, "the page reaches an image")
        let seed = VerificationCorpusRunnerTests.RegionSeed(
            gtId: "gt-1", value: "Delia Hartwell", category: "name", page: 0, rect: Self.box)
        let region = try #require(VerificationCorpusRunnerTests.region(from: seed, polygon: false))
        #expect(region.textAnchored)
        let pages = VerificationCorpusRunnerTests.buildPages(
            doc: doc, effectiveMode: .searchableRedaction, regionsByPage: [0: [region]],
            textLayerStatus: [0: .rich], hasHiddenOCG: false)
        let page = try #require(pages.first)
        #expect(pages.count == 1)
        #expect(page.pipelineMode == .searchableRedaction)
        #expect(page.fallbackReason == nil)
    }

    /// Until the fence set holds it: outside the detector and the detector's
    /// own tests, the trigger check is called in one file, the decision's.
    /// `RotatedPageCoordinateTests` is a test of the detector on rotated
    /// pages; comment lines are not calls.
    @Test("the trigger check is called in one file outside the detector and its tests")
    func triggerCheckCalledInOneFile() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // DetectionTests
            .deletingLastPathComponent()   // RedactionEngineTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // <package root>
        let repoRoot = packageRoot.deletingLastPathComponent().deletingLastPathComponent()
        let detectorFiles: Set<String> = ["TextLayerDetector.swift", "TextLayerDetectorTests.swift", "RotatedPageCoordinateTests.swift"]
        let trees = [packageRoot.appendingPathComponent("Sources"), packageRoot.appendingPathComponent("Tests"),
                     repoRoot.appendingPathComponent("Sources"), repoRoot.appendingPathComponent("Tests")]
        let call = "checkFallbackTriggers" + "("   // split, so this file holds no call
        var callers: Set<String> = []
        var read = 0
        for tree in trees {
            let walker = try #require(FileManager.default.enumerator(at: tree, includingPropertiesForKeys: nil),
                                      "\(tree.path) is not readable")
            for case let url as URL in walker where url.pathExtension == "swift" {
                read += 1
                guard !detectorFiles.contains(url.lastPathComponent) else { continue }
                let text = try String(contentsOf: url, encoding: .utf8)
                let calls = text.split(separator: "\n").contains { line in
                    let code = line.trimmingCharacters(in: .whitespaces)
                    return !code.hasPrefix("//") && code.contains(call)
                }
                if calls { callers.insert(url.lastPathComponent) }
            }
        }
        #expect(read > 100, "the walk read \(read) Swift files")
        #expect(callers == ["PageModeDecision.swift"], "\(callers.sorted())")
    }
}
