import Foundation
import CoreGraphics
import PDFKit
@testable import RedactionEngine

// The seam between the frozen hidden-word cases (`HiddenWordInkPredicateCases`,
// `HiddenWordInkLayerCases`) and the check they are written for: a check that
// fails a Searchable run when a surviving hidden word's printed ink lies under
// a box, located by the source page's own print, not by the boxes the export
// stripped by.
//
// Until the check is built, every entry point here returns nil and every case
// that needs the check fails with "the check is not built". To build it, the
// engine lane replaces the bodies of the five entry points below (and only
// them) with calls into the check: `layer`, `verdict`, `runLayer`, and the
// alignment step's `align` and `pageVerdict` (`HiddenWordInkAlignCases`).
// The case files, and the shapes in this file, stay as they are: a case that
// cannot pass against them is a design question for the verification leader,
// not an edit.

/// One word as the check reads it: a text key, a box in the page's
/// normalized frame (bottom-left origin, the post-rotation crop-box frame
/// that `RedactionRegion.normalizedRect` uses), and a line id. Output words'
/// and source words' line ids are numbered independently.
struct InkCaseWord: Equatable, Sendable {
    var key: String
    var rect: CGRect
    var line: Int
}

/// What the check knows about the source page before it reads any word.
enum InkCasePageKind: Equatable, Sendable {
    /// Hidden text over an image of the page (an image object or an inline
    /// image of any size, with text drawn invisibly).
    case textOverImage
    /// No image object, no inline image, no invisible text, no Type 3 font:
    /// the text layer is its own ink.
    case plain
}

/// Why the check had nothing to check on a page.
enum InkCaseNotApplicable: Equatable, Sendable {
    case noText, plainSource, noRegions
}

/// A flagged word or an edge note: the page, the box, and the word's ink as the
/// check placed it. It carries no text.
struct InkCaseMark: Equatable, Sendable {
    var pageIndex: Int
    var regionID: UUID
    var inkRect: CGRect
}

/// The check's verdict for one page. Findings, edge notes and an
/// unplaceable word near a box can all hold on the same page.
struct InkCaseVerdict: Equatable, Sendable {
    /// A surviving word whose placed ink has its centre inside a box's
    /// pre-growth paint.
    var findings: [InkCaseMark] = []
    /// A surviving word whose placed ink crosses a box's edge, its centre
    /// outside.
    var edgeNotes: [InkCaseMark] = []
    /// A surviving word that could lie under a box could not be placed.
    var unplaceableNearBox = false
    var notApplicable: InkCaseNotApplicable?
}

/// One hidden character of the source's text layer, in `page.string` order,
/// in the normalized frame. Spaces are glyphs too.
struct InkCaseGlyph: Equatable, Sendable {
    var char: Character
    var rect: CGRect
    var line: Int
}

/// The direction text advances in the visual (post-rotation) frame.
enum InkCaseAxis: Equatable, Sendable {
    /// /Rotate 0, 90, 180, 270.
    case right, down, left, up
}

/// The source read the layer's dispatcher uses, made injectable. It counts
/// its calls and can be told to fail.
final class InkCaseReader: @unchecked Sendable {
    struct Failure: Error {}
    private let lock = NSLock()
    private var _calls = 0
    let words: [Int: [InkCaseWord]]
    let fails: Bool

    init(words: [Int: [InkCaseWord]] = [:], fails: Bool = false) {
        self.words = words
        self.fails = fails
    }

    var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }

    /// The source page's recognized words, or a thrown read error.
    func read(pageIndex: Int) throws -> [InkCaseWord] {
        lock.lock(); _calls += 1; lock.unlock()
        if fails { throw Failure() }
        return words[pageIndex] ?? []
    }
}

enum HiddenWordInkSeam {
    /// The check's `VerificationLayer` case. Not built: nil.
    static var layer: VerificationLayer? { nil }

    /// The check's pure predicate for page `pageIndex`. Not built: nil.
    static func verdict(
        pageIndex: Int, output: [InkCaseWord], sourceInk: [InkCaseWord],
        regions: [RedactionRegion], pageSize: CGSize, kind: InkCasePageKind
    ) -> InkCaseVerdict? {
        nil
    }

    /// The check's layer over an output document and its source, as the
    /// verifier runs it; `reader` nil is the production read (a fresh render
    /// of the source page and one recognition pass), otherwise the source
    /// read goes through `reader`. Not built: nil.
    static func runLayer(
        output: PDFDocument, source: PDFDocument?, regions: [Int: [RedactionRegion]],
        mode: PipelineMode, reader: InkCaseReader?
    ) async -> LayerResult? {
        nil
    }

    /// The alignment step: each export word's aligned source-glyph box (the
    /// union of its matched glyphs), or nil when it is unaligned or
    /// ambiguous; one entry per word, in order. Not built: nil.
    static func align(
        words: [InkCaseWord], glyphs: [InkCaseGlyph], pageSize: CGSize, axis: InkCaseAxis
    ) -> [CGRect?]? {
        nil
    }

    /// `align`, then the predicate on the aligned words, plus the handling of
    /// unaligned words. `verdict` keeps its meaning, with the axis taken as
    /// `.right`. Not built: nil.
    static func pageVerdict(
        pageIndex: Int, exportWords: [InkCaseWord], glyphs: [InkCaseGlyph], sourceInk: [InkCaseWord],
        regions: [RedactionRegion], pageSize: CGSize, kind: InkCasePageKind, axis: InkCaseAxis
    ) -> InkCaseVerdict? {
        nil
    }
}
