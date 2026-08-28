import Testing
import Foundation
import PDFKit
import CoreGraphics
import CryptoKit
#if canImport(UIKit)
import UIKit
#endif
@testable import RedactionEngine

// Pipeline measurement helpers for `PacketSearchableProbeTests`.
//
// Operates on a committed synthetic fixture (the parameterized
// fixture-plus-regions pipeline probe; the fixture payload is `Data`).
// Logging scope for the document under test: per-glyph data only —
// Unicode scalar values (hex), UTF-16 offsets, bounds/geometry, font and
// subset names, page numbers. NEVER running text (words/lines/sentences).
// Content strings are held internally for sequence alignment; everything
// printed goes through `scalarHex`, counts, or geometry. Production code's
// logging rules (never document content, file paths, or redaction
// coordinates) are untouched — this file is test-only measurement.

// MARK: - Records

/// One composed unit of an output page's full `page.string` walk — NO skip
/// conditions applied, so the three verifier skip classes (nil selection,
/// zero/negative bounds, whitespace) are all observable per unit.
struct RealDocOutputUnit {
    let utf16Offset: Int
    let string: String
    let hasSelection: Bool
    let bounds: CGRect
    let family: String
    let pointSize: Double
    var positiveBounds: Bool { hasSelection && bounds.width > 0 && bounds.height > 0 }
}

/// Everything one pipeline pass produces (config-scoped). The output
/// document is URL-backed (Layer 0's /AcroForm walk needs `documentURL`;
/// a data-backed document degrades it to WARN) — callers remove
/// `outputURL` when finished.
struct RealDocPipelineRun {
    let outputURL: URL
    let outputDocument: PDFDocument
    let digests: [PageFilterDigest?]
    let layers: [Int: LayerResult]
    let surviving: [[CharacterInfo]]
}

// MARK: - Harness

enum RealDocProbe {

    /// Simulator runtime version string, e.g. "26.4.0" — per-runtime results
    /// in the printed reports key off this.
    static var runtimeTag: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    /// Full pipeline pass + all 10 verification layers on the fixture.
    /// Caller removes `outputURL` when finished with the run.
    static func run(
        _ fixture: Data, regions: [Int: [RedactionRegion]]
    ) async throws -> RealDocPipelineRun {
        let url = try await TestPipeline.processAndExport(
            fixture, mode: .searchableRedaction, regions: regions, dpi: 150)
        let digests = try await TestPipeline.searchableDigests(fixture, regions: regions)
        let surviving = try await SearchableMergeProbe.survivingPerPage(fixture, regions: regions)
        guard let outDoc = PDFDocument(url: url) else { throw ProbeMeasureError.noOutput }
        let perPageModes = [PipelineMode](
            repeating: PipelineMode.searchableRedaction, count: outDoc.pageCount)
        let layers = await SearchableMergeProbe.runLayers(
            outputDocument: SendablePDFDocument(outDoc),
            sourcePageCount: outDoc.pageCount,
            regions: regions, digests: digests, perPageModes: perPageModes)
        return RealDocPipelineRun(
            outputURL: url, outputDocument: outDoc, digests: digests,
            layers: layers, surviving: surviving)
    }

    // MARK: Walks

    /// Full composed-unit walk of an output page (no skip conditions).
    static func outputUnits(_ page: PDFPage) -> [RealDocOutputUnit] {
        guard let text = page.string else { return [] }
        let ns = text as NSString
        let total = page.numberOfCharacters
        var units: [RealDocOutputUnit] = []
        var offset = 0
        while offset < total {
            let range = ns.rangeOfComposedCharacterSequence(at: offset)
            defer { offset += max(range.length, 1) }
            let sub = ns.substring(with: range)
            guard let sel = page.selection(for: range) else {
                units.append(RealDocOutputUnit(
                    utf16Offset: range.location, string: sub, hasSelection: false,
                    bounds: .null, family: "", pointSize: 0))
                continue
            }
            let b = sel.bounds(for: page)
            var family = ""
            var pointSize = 0.0
            if let attr = sel.attributedString, attr.length > 0,
               let font = attr.attribute(.font, at: 0, effectiveRange: nil) as? UIFont {
                #if canImport(UIKit)
                family = font.familyName
                #else
                family = font.familyName ?? font.fontName
                #endif
                pointSize = Double(font.pointSize)
            }
            units.append(RealDocOutputUnit(
                utf16Offset: range.location, string: sub, hasSelection: true,
                bounds: b, family: family, pointSize: pointSize))
        }
        return units
    }

    // MARK: Formatting (per-glyph scope only — never running text)

    /// "U+0041" form for every scalar of a grapheme.
    static func scalarHex(_ s: String) -> String {
        s.unicodeScalars.map { String(format: "U+%04X", $0.value) }.joined(separator: " ")
    }
    static func r4(_ d: Double) -> Double { (d * 10000).rounded() / 10000 }
}
