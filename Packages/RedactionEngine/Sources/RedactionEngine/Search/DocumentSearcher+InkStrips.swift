import CoreGraphics
import Foundation
import PDFKit

// On a page whose text is an invisible layer over a picture of the page, the
// layer can sit to one side of the printed words, so a box over a printed word
// can leave that word's text outside the box. Before a Searchable run, each
// box on such a page is matched to the hidden words whose printed ink it
// covers (the ink fit, `DocumentSearcher+InkFit.swift`), and the hidden
// glyphs' boxes of those words are stripped with it, wherever they sit. A word
// near a box whose print could not be placed with confidence is stripped when
// the fit's own drift envelope for it meets the box (it may lose its
// searchable text; nothing covered survives within the bound). A word that
// could not be fitted at all leaves the page unplanned: it is written as an
// image only.

/// The hidden words found for the boxes on one page.
public struct InkStripPlan: Sendable, Equatable {
    /// Per region id: the hidden glyphs' boxes (page-normalized) of the words
    /// whose printed ink the region covers.
    public var strips: [UUID: [CGRect]]
    /// Per region id: those words' ranges in the page text, in reading order.
    public var words: [UUID: [NSRange]]
    /// A word that could lie under a box could not be matched to its print:
    /// the page takes the image-only floor.
    public var unsure: Bool
    /// Per region id: the paint the plan was made for. A region on the page
    /// that is not here with the same paint (drawn, moved or resized after
    /// the plan) has no plan: the page takes the floor.
    public var planned: [UUID: CGRect]

    public init(strips: [UUID: [CGRect]] = [:], words: [UUID: [NSRange]] = [:], unsure: Bool = false,
                planned: [UUID: CGRect] = [:]) {
        self.strips = strips
        self.words = words
        self.unsure = unsure
        self.planned = planned
    }

    /// Whether the plan covers every region now on the page with the paint it
    /// was made for (a whole-page box needs no plan) and is sure of every
    /// word that could lie under one.
    public func covers(_ regions: [RedactionRegion]) -> Bool {
        !unsure && regions.allSatisfy { $0.coversWholePage || planned[$0.id] == $0.normalizedRect }
    }
}

/// One hidden word as the planner reads it: its range, its hidden glyphs'
/// boxes (one per line it spans), and its printed ink's boxes, or nil when the
/// ink fit could not place it with confidence; then `envelope` is where the
/// fit says its ink can lie (its drift envelope), or nil when there was no fit
/// at all. Page-normalized boxes.
public struct HiddenWordInk: Sendable, Equatable {
    public var range: NSRange
    public var strip: [CGRect]
    public var ink: [CGRect]?
    public var envelope: [CGRect]?

    public init(range: NSRange, strip: [CGRect], ink: [CGRect]?, envelope: [CGRect]? = nil) {
        self.range = range
        self.strip = strip
        self.ink = ink
        self.envelope = envelope
    }
}

extension DocumentSearcher {

    /// Whether a hidden word could have its print under `paint`. Across its
    /// line a hidden word lies within `inkFitDriftAcross`, or one and a half
    /// line heights, of its print. Along the line the drift has no fixed
    /// bound (it grows with the distance from the line's start,
    /// `inkFitDriftPerPoint`), so every word on the region's band is a
    /// candidate. The band runs along the page's lines: across the page when
    /// they run across it (`horizontalLines`), down it otherwise.
    nonisolated static func isCandidate(
        _ hidden: CGRect, for paint: CGRect, pageSize: CGSize, horizontalLines: Bool = true
    ) -> Bool {
        let h = hidden.height * pageSize.height, w = hidden.width * pageSize.width
        let across = max(1.5 * (horizontalLines ? h : w), inkFitDriftAcross)
        if horizontalLines {
            let dy = across / pageSize.height
            return hidden.minY < paint.maxY + dy && paint.minY - dy < hidden.maxY
        }
        let dx = across / pageSize.width
        return hidden.minX < paint.maxX + dx && paint.minX - dx < hidden.maxX
    }

    /// Whether a page's lines run across it: unless most of its words of
    /// three characters or more are taller than wide. A short word's box
    /// ("in", "by") is often taller than wide on a line that runs across, so
    /// it says nothing either way.
    nonisolated static func linesRunAcross(_ words: [(length: Int, box: CGRect)], pageSize: CGSize) -> Bool {
        let longer = words.filter { $0.length >= 3 }
        let across = longer.filter { $0.box.width * pageSize.width >= $0.box.height * pageSize.height }.count
        return longer.isEmpty || 2 * across >= longer.count
    }

    /// The plan for `regions` from the page's candidate hidden words (pure).
    /// A region strips every word whose ink meets its paint with positive
    /// area, and names it; a word placed without confidence is stripped (not
    /// named) when its envelope meets the paint; a candidate word with no fit
    /// at all makes the page unsure. `regions`' paint is the pre-growth box
    /// the user placed.
    public nonisolated static func inkStripPlan(
        regions: [RedactionRegion], words: [HiddenWordInk], pageSize: CGSize, horizontalLines: Bool = true
    ) -> InkStripPlan {
        func meets(_ boxes: [CGRect], _ paint: CGRect) -> Bool {
            boxes.contains { let i = $0.intersection(paint); return !i.isNull && i.width > 0 && i.height > 0 }
        }
        var plan = InkStripPlan()
        for region in regions where !region.coversWholePage {
            let paint = region.normalizedRect
            plan.planned[region.id] = paint
            var strips: [CGRect] = []
            var ranges: [NSRange] = []
            for word in words where word.strip.contains(where: {
                isCandidate($0, for: paint, pageSize: pageSize, horizontalLines: horizontalLines)
            }) {
                if let ink = word.ink {
                    if meets(ink, paint) {
                        strips += word.strip
                        ranges.append(word.range)
                    }
                } else if let envelope = word.envelope {
                    if meets(envelope, paint) { strips += word.strip }
                } else {
                    plan.unsure = true
                }
            }
            if !strips.isEmpty {
                plan.strips[region.id] = strips
                plan.words[region.id] = ranges
            }
        }
        return plan
    }

    /// The plan for the regions on one page, or nil when the page's text is
    /// not a hidden layer over a picture of the page (there is nothing to
    /// match; the run's page-facts floor decides such a page). Reads the
    /// page's print once (`prepareInkFit`) and fits only the candidate words
    /// of each region. Nonisolated and async, so it runs off the main thread,
    /// where the fit would read only a cache and return the hidden box itself.
    public nonisolated static func inkStripPlan(regions: [RedactionRegion], page: PDFPage) async -> InkStripPlan? {
        guard let cgPage = page.pageRef, carriesHiddenTextOverImage(page, cgPage: cgPage) else { return nil }
        let boxes = regions.filter { !$0.coversWholePage }
        guard !boxes.isEmpty else { return InkStripPlan() }
        let size = effectiveBounds(page.bounds(for: .cropBox), rotation: page.rotation).size
        guard size.width > 0, size.height > 0, let source = EmbeddedTextSource.make(from: page) else {
            return InkStripPlan(unsure: true)
        }
        await prepareInkFit(page)
        let horizontal = linesRunAcross(source.wordBounds.map { (length: $0.range.length, box: $0.normalizedRect) },
                                        pageSize: size)
        let searcher = DocumentSearcher()
        var words: [HiddenWordInk] = []
        for word in source.wordBounds where boxes.contains(where: {
            isCandidate(word.normalizedRect, for: $0.normalizedRect, pageSize: size, horizontalLines: horizontal)
        }) {
            guard let fit = searcher.textLayerAndInkRects(for: word.range, page: page) else {
                words.append(HiddenWordInk(range: word.range, strip: [word.normalizedRect], ink: nil))
                continue
            }
            words.append(fit.degraded
                ? HiddenWordInk(range: word.range, strip: fit.strip, ink: nil, envelope: fit.paint)
                : HiddenWordInk(range: word.range, strip: fit.strip, ink: fit.paint))
        }
        return inkStripPlan(regions: boxes, words: words, pageSize: size, horizontalLines: horizontal)
    }
}
