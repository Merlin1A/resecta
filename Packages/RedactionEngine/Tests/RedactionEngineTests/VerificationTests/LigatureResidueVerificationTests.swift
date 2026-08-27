import Testing
import Foundation
import PDFKit
import CoreGraphics
@testable import RedactionEngine

// Verification-side normalization parity with the search path.
//
// The search path normalizes page text through `TextNormalizer` (ligature
// expansion + NFKC) before matching. The verifier's text-space term checks
// and its byte automaton did not, so a residue the search could locate
// could be invisible to verification. Fixture facts measured on the macOS
// 26 host (2026-08-27): PDFKit's `page.string` decomposes U+FB01 (fi) and
// U+FB02 (fl) on its own but hands back U+FB00 (ff), U+FB03 (ffi), U+FB04
// (ffl) and fullwidth letters as authored, so the text-layer fixtures below
// use the `ffi` ligature and a fullwidth spelling. Foundation's
// case-insensitive search folds the Latin ligatures by itself (Unicode full
// case folding), so the text-space proof rests on the fullwidth form; the
// byte-space proof rests on the ligature scalar.

@Suite("Ligature and compatibility-form residue verification", .serialized)
struct LigatureResidueVerificationTests {

    private static let ligaturePage = "Main o\u{FB03}ce address"
    private static let fullwidthPage = "Main \u{FF4F}\u{FF46}\u{FF46}\u{FF49}\u{FF43}\u{FF45} address"

    private static func region(_ r: CGRect) -> RedactionRegion {
        RedactionRegion(id: UUID(), normalizedRect: r, source: .manual)
    }

    private static func hit(_ text: String, box: CGRect) -> VerificationEngine.OCRHit {
        VerificationEngine.OCRHit(box: box, wordBoxes: [], text: text, confidence: 0.9)
    }

    private static let pageRegion = region(CGRect(x: 0.6, y: 0.05, width: 0.3, height: 0.2))
    private static let outsideBox = CGRect(x: 0.05, y: 0.7, width: 0.4, height: 0.05)
    private static let insideBox = CGRect(x: 0.65, y: 0.10, width: 0.2, height: 0.1)

    private func searchCount(_ data: Data, term: String) async throws -> Int {
        let doc = try #require(PDFDocument(data: data))
        let searcher = DocumentSearcher()
        let stream = searcher.search(
            SendablePDFDocument(doc),
            mode: .text(term, options: SearchOptions(normalizeUnicode: true)),
            progress: { _, _ in })
        var count = 0
        for await _ in stream { count += 1 }
        return count
    }

    private func layer3Status(
        _ data: Data, term: String, mode: PipelineMode, prefix: String
    ) async throws -> LayerResult {
        let (doc, url) = try TestFixtures.writeTempPDF(data, prefix: prefix)
        defer { try? FileManager.default.removeItem(at: url) }
        return await VerificationEngine().runLayer(
            2, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 1, regions: [:],
            sensitiveTerms: [SensitiveTerm(text: term)],
            pipelineMode: mode, filterDigests: [nil], perPageModes: [mode])
    }

    // MARK: - The search-side premise

    @Test("Search locates the term on the ligature and fullwidth pages")
    func searchLocatesBothForms() async throws {
        let ligature = try await searchCount(
            TestFixtures.textLayerPDF(text: Self.ligaturePage), term: "office")
        #expect(ligature == 1, "search must locate the ffi-ligature spelling")
        let fullwidth = try await searchCount(
            TestFixtures.textLayerPDF(text: Self.fullwidthPage), term: "office")
        #expect(fullwidth == 1, "search must locate the fullwidth spelling")
    }

    // MARK: - Text-space checks

    @Test("Text-space term checks match the compatibility forms the search matches")
    func textChecksMatchCompatibilityForms() {
        // Fullwidth spelling in the text; plain term.
        #expect(VerificationEngine.containsTermCaseInsensitive(Self.fullwidthPage, "office"))
        #expect(VerificationEngine.containsTermCaseInsensitive(
            "\u{FF23}\u{FF2F}\u{FF2E}\u{FF26}\u{FF29}\u{FF24}\u{FF25}\u{FF2E}\u{FF34}\u{FF29}\u{FF21}\u{FF2C} report",
            "confidential"))
        // Ligature spelling in the text; ligature typed in the term.
        #expect(VerificationEngine.containsTermCaseInsensitive(Self.ligaturePage, "office"))
        #expect(VerificationEngine.containsTermCaseInsensitive("office", "o\u{FB03}ce"))
        // Boundary-required term: the adjacency test reads the normalized text.
        let bounded = SensitiveTerm(text: "office", requiresTokenBoundary: true)
        #expect(VerificationEngine.containsTerm(Self.fullwidthPage, bounded))
        #expect(!VerificationEngine.containsTerm(
            "Main \u{FF4F}\u{FF46}\u{FF46}\u{FF49}\u{FF43}\u{FF45}s address", bounded),
            "an embedded fullwidth occurrence stays embedded after normalization")
        // The diacritic rule is untouched: NFKC keeps diacritics.
        #expect(!VerificationEngine.containsTermCaseInsensitive("Mu\u{00F1}oz", "Munoz"))
    }

    @Test("The OCR leg raises the term signals on a compatibility form")
    func ocrLegRaisesTermSignals() {
        let terms = [SensitiveTerm(text: "office")]
        let outside = VerificationEngine.classifyPageOCR(
            hits: [Self.hit(Self.fullwidthPage, box: Self.outsideBox)],
            pageRegions: [Self.pageRegion], sensitiveTerms: terms)
        #expect(outside == .sensitiveTermOutsideRegions,
                "a fullwidth occurrence outside the regions must raise the term signal — got \(outside)")
        let inside = VerificationEngine.classifyPageOCR(
            hits: [Self.hit(Self.fullwidthPage, box: Self.insideBox)],
            pageRegions: [Self.pageRegion], sensitiveTerms: terms)
        #expect(inside == .sensitiveTermInRegion,
                "a fullwidth occurrence inside a region must FAIL — got \(inside)")
    }

    // MARK: - Byte-space checks

    @Test("The automaton built for a plain term matches its ligature bytes")
    func automatonMatchesLigatureBytes() {
        let automaton = AhoCorasick(patterns: AhoCorasick.encodeForSearch("confidential"))
        let utf8: [UInt8] = [0xFF] + Array("con\u{FB01}dential".utf8) + [0x00]
        let utf8Matches = utf8.withUnsafeBufferPointer { automaton.search($0) }
        #expect(!utf8Matches.isEmpty, "UTF-8 bytes of the fi-ligature spelling must match")
        let utf16BE: [UInt8] = [0xFF] + Array("con\u{FB01}dential".data(using: .utf16BigEndian)!) + [0x00]
        let utf16Matches = utf16BE.withUnsafeBufferPointer { automaton.search($0) }
        #expect(!utf16Matches.isEmpty, "UTF-16BE bytes of the fi-ligature spelling must match")
        let plain = Array("no such term here".utf8)
        #expect(plain.withUnsafeBufferPointer { automaton.search($0) }.isEmpty)
    }

    @Test("Layer 3's decoded-text pass reports a ligature-form residue")
    func decodedPassReportsLigatureResidue() async throws {
        let result = try await layer3Status(
            TestFixtures.textLayerPDF(text: Self.ligaturePage),
            term: "office", mode: .searchableRedaction, prefix: "lig_ffi_")
        guard case .attention = result.status else {
            Issue.record("the ffi-ligature residue must be reported as residual text — got \(result.status)")
            return
        }
        #expect(result.pageReferences == [0])
    }

    @Test("Layer 3's decoded-text pass reports a fullwidth residue")
    func decodedPassReportsFullwidthResidue() async throws {
        let result = try await layer3Status(
            TestFixtures.textLayerPDF(text: Self.fullwidthPage),
            term: "office", mode: .searchableRedaction, prefix: "lig_fw_")
        guard case .attention = result.status else {
            Issue.record("the fullwidth residue must be reported as residual text — got \(result.status)")
            return
        }
        #expect(result.pageReferences == [0])
    }

    @Test("Layer 3's structural pass reports a ligature-form term in the Info dictionary")
    func structuralPassReportsLigatureBytes() async throws {
        let composed = try await layer3Status(
            TestFixtures.withMetadata(["Title": "o\u{FB03}ce memo"]),
            term: "office", mode: .secureRasterization, prefix: "lig_meta_")
        #expect(composed.status.isFail,
                "the ligature-composed term in structural bytes must FAIL — got \(composed.status)")
        // Control: the plain spelling already FAILs; the expansion adds, never removes.
        let plain = try await layer3Status(
            TestFixtures.withMetadata(["Title": "office memo"]),
            term: "office", mode: .secureRasterization, prefix: "lig_meta_plain_")
        #expect(plain.status.isFail)
    }
}
