import CoreGraphics
import Foundation
import PDFKit
import RedactionEngine

/// Annotations in a received PDF that can sit over page content — a black
/// square, a stamp, an unapplied redaction mark, a watermark, a form field
/// or a highlight drawn opaque — and the text under them.
/// The on-screen view draws an annotation; the exported file is rebuilt
/// from the page content, which does not include annotations, so text an
/// annotation covered appears in the export unless a redaction box covers
/// it too. The share confirm names the pages where that is the case, on
/// every verdict (the checks read the output, where the annotation is
/// gone and the text is ordinary page text).
enum ConcealingAnnotations {

    /// Annotation subtypes that can cover content (`PDFAnnotation.type`).
    /// Links, notes, pop-ups and the other text markup are excluded: they
    /// do not hide what is under them. A form widget and a highlight
    /// conceal only when they draw an opaque cover (`coverWhenOpaqueSubtypes`).
    nonisolated static let concealingSubtypes: Set<String> = [
        "Square", "Circle", "Polygon", "Ink", "Stamp", "FreeText", "Redact", "Watermark",
    ]

    /// Subtypes that conceal when they draw an opaque cover
    /// (`drawsOpaqueCover`): an empty black form field used as a redaction,
    /// a highlight painted over the text instead of multiplied with it.
    nonisolated static let coverWhenOpaqueSubtypes: Set<String> = ["Widget", "Highlight"]

    /// Whether `annotation`'s own drawing hides what is under it: a widget
    /// with a dark opaque background colour (`/MK /BG`, luminance under
    /// one half), or a drawing that decides at least 60 % of its rect
    /// (`hiddenFraction`). A white or light field background is left to
    /// the drawing; whether it hides anything is the content test's call
    /// (`areaOverContent`), as an ordinary form's fields sit on blank
    /// boxes. A field that draws only its value or a border does not count
    /// (its value is the import notice's filled-field sentence), nor does a
    /// light highlight multiplied over the text.
    nonisolated static func drawsOpaqueCover(_ annotation: PDFAnnotation) -> Bool {
        if annotation.type == "Widget", let background = annotation.backgroundColor,
           isDarkAndOpaque(background.cgColor) {
            return true
        }
        return hiddenFraction(of: annotation) >= 0.6
    }

    /// Whether `color` is at least half opaque with a relative luminance
    /// (sRGB) under one half.
    nonisolated private static func isDarkAndOpaque(_ color: CGColor) -> Bool {
        guard color.alpha > 0.5,
              let sRGB = CGColorSpace(name: CGColorSpace.sRGB),
              let converted = color.converted(to: sRGB, intent: .defaultIntent, options: nil),
              let components = converted.components, components.count >= 3 else { return false }
        return 0.2126 * components[0] + 0.7152 * components[1] + 0.0722 * components[2] < 0.5
    }

    /// The part of `annotation` on the page's crop box, when page content
    /// lies beneath it: on a page whose text layer reads (`readsText`),
    /// text a selection of that area reads; on a sparse or empty page,
    /// where the printed content is in the page image, any such part. Nil
    /// otherwise. The import count and the share confirm both ask it, so
    /// they name the same annotations.
    nonisolated static func areaOverContent(
        _ annotation: PDFAnnotation, on page: PDFPage, crop: CGRect, readsText: Bool
    ) -> CGRect? {
        let area = annotation.bounds.intersection(crop)
        guard !area.isNull, area.width > 0, area.height > 0 else { return nil }
        if readsText {
            guard let text = page.selection(for: area)?.string,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        }
        return area
    }

    /// Whether the page's text layer reads: its import status is rich, or,
    /// with no status, it carries text.
    nonisolated static func readsText(_ page: PDFPage, status: TextLayerStatus?) -> Bool {
        status.map { $0 == .rich } ?? !(page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The share of `annotation`'s rect where its drawing decides the pixel
    /// whatever lies beneath: drawn once over white and once over black
    /// (48 × 16 samples), the two results differ there by less than a
    /// quarter of full scale. An opaque fill decides its pixels, whatever
    /// the colour; a multiplied highlight leaves black text black, unless
    /// the highlight is itself dark. Zero for an empty rect.
    nonisolated private static func hiddenFraction(of annotation: PDFAnnotation) -> Double {
        let width = 48, height = 16
        guard let overWhite = rendered(annotation, over: 1, width: width, height: height),
              let overBlack = rendered(annotation, over: 0, width: width, height: height) else { return 0 }
        var hidden = 0
        for pixel in 0..<(width * height) {
            var difference = 0
            for channel in 0..<3 {
                difference += abs(Int(overWhite[pixel * 4 + channel]) - Int(overBlack[pixel * 4 + channel]))
            }
            if difference / 3 < 64 { hidden += 1 }
        }
        return Double(hidden) / Double(width * height)
    }

    /// `annotation` drawn over a grey fill of `gray` (0 black, 1 white),
    /// its rect scaled to `width` × `height` RGBA pixels. Nil for an empty
    /// rect.
    nonisolated private static func rendered(
        _ annotation: PDFAnnotation, over gray: CGFloat, width: Int, height: Int
    ) -> [UInt8]? {
        let bounds = annotation.bounds
        guard bounds.width > 0, bounds.height > 0,
              let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.setFillColor(gray: gray, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: CGFloat(width) / bounds.width, y: CGFloat(height) / bounds.height)
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        annotation.draw(with: .mediaBox, in: context)
        guard let data = context.data else { return nil }
        return Array(UnsafeBufferPointer(start: data.bindMemory(to: UInt8.self, capacity: width * height * 4),
                                         count: width * height * 4))
    }

    /// Form widgets in `document` that lie over page content
    /// (`areaOverContent`) and draw an opaque cover (`drawsOpaqueCover`),
    /// counted at import for the notice: the analyzer skips widgets, and
    /// the export does not draw them. `textLayerStatus` is the import's
    /// per-page status; the content test runs first, so only the fields
    /// over content are drawn.
    nonisolated static func coverWidgetCount(
        in document: PDFDocument, textLayerStatus: [Int: TextLayerStatus] = [:]
    ) -> Int {
        var count = 0
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let crop = page.bounds(for: .cropBox)
            guard crop.width > 0, crop.height > 0 else { continue }
            let reads = readsText(page, status: textLayerStatus[index])
            count += page.annotations.count {
                $0.type == "Widget"
                    && areaOverContent($0, on: page, crop: crop, readsText: reads) != nil
                    && drawsOpaqueCover($0)
            }
        }
        return count
    }

    /// `drawsOpaqueCover`, kept per annotation for the share tap: the
    /// annotations of the open document do not change, and the keys are
    /// held weakly, so the entries go with the document.
    private static let opaqueCoverCache = NSMapTable<PDFAnnotation, NSNumber>.weakToStrongObjects()

    private static func cachedDrawsOpaqueCover(_ annotation: PDFAnnotation) -> Bool {
        if let known = opaqueCoverCache.object(forKey: annotation) { return known.boolValue }
        let draws = drawsOpaqueCover(annotation)
        opaqueCoverCache.setObject(NSNumber(value: draws), forKey: annotation)
        return draws
    }

    /// 0-based pages of `document` where a concealing annotation covers
    /// content that the page's redaction boxes do not cover. On a page whose
    /// text layer is rich, the annotation must have text under it. On a
    /// sparse or empty page (`textLayerStatus`, the import's per-page
    /// status) the printed content is in the page image, where no selection
    /// reads it, so any uncovered concealing annotation is named. A page
    /// with no status counts as rich when it carries text. The cheap tests
    /// run first (the subtype, the content beneath, the boxes), so only a
    /// widget or highlight still in question is drawn, once per annotation
    /// (`cachedDrawsOpaqueCover`). Empty for no document.
    static func pages(
        in document: PDFDocument?, regions: [Int: [RedactionRegion]],
        textLayerStatus: [Int: TextLayerStatus] = [:]
    ) -> [Int] {
        guard let document else { return [] }
        var out: [Int] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let crop = page.bounds(for: .cropBox)
            guard crop.width > 0, crop.height > 0 else { continue }
            let reads = readsText(page, status: textLayerStatus[index])
            let boxes = regions[index] ?? []
            for annotation in page.annotations {
                let subtype = annotation.type ?? ""
                let whenOpaque = coverWhenOpaqueSubtypes.contains(subtype)
                guard whenOpaque || concealingSubtypes.contains(subtype),
                      let area = areaOverContent(annotation, on: page, crop: crop, readsText: reads),
                      let normalized = displayNormalized(area, crop: crop, rotation: page.rotation),
                      !covered(normalized, by: boxes) else { continue }
                // The drawing test last: it draws the annotation twice.
                if whenOpaque && !cachedDrawsOpaqueCover(annotation) { continue }
                out.append(index)
                break
            }
        }
        return out
    }

    /// `rect` (page space: unrotated, with the crop box's origin) in the
    /// space the redaction boxes live in: the displayed page after its
    /// /Rotate, normalized 0–1 with a bottom-left origin. The transform is
    /// the search's own (`DocumentSearcher.boundingRect(for:page:)`), so a
    /// box a search placed over a match compares with the annotation in one
    /// space on a rotated page too. Nil for an empty page.
    static func displayNormalized(_ rect: CGRect, crop: CGRect, rotation: Int) -> CGRect? {
        let local = rect.offsetBy(dx: -crop.minX, dy: -crop.minY)
        let w = crop.width, h = crop.height
        let visual: CGRect
        switch ((rotation % 360) + 360) % 360 {
        case 90:  visual = CGRect(x: local.minY, y: w - local.maxX, width: local.height, height: local.width)
        case 180: visual = CGRect(x: w - local.maxX, y: h - local.maxY, width: local.width, height: local.height)
        case 270: visual = CGRect(x: h - local.maxY, y: local.minX, width: local.height, height: local.width)
        default:  visual = local
        }
        let turned = rotation % 180 != 0
        let effectiveWidth = turned ? h : w, effectiveHeight = turned ? w : h
        guard effectiveWidth > 0, effectiveHeight > 0 else { return nil }
        return CGRect(x: visual.minX / effectiveWidth, y: visual.minY / effectiveHeight,
                      width: visual.width / effectiveWidth, height: visual.height / effectiveHeight)
    }

    /// Whether `rect` (normalized page space) lies under the boxes: every
    /// point of a 12 × 4 grid inside a box.
    static func covered(_ rect: CGRect, by boxes: [RedactionRegion]) -> Bool {
        guard !boxes.isEmpty else { return false }
        for row in 0..<4 {
            for column in 0..<12 {
                let point = CGPoint(x: rect.minX + rect.width * (CGFloat(column) + 0.5) / 12,
                                    y: rect.minY + rect.height * (CGFloat(row) + 0.5) / 4)
                if !boxes.contains(where: { $0.normalizedRect.contains(point) }) {
                    return false
                }
            }
        }
        return true
    }

    /// The share-confirm line (new public copy). Pages are 0-based storage,
    /// displayed 1-based through the row model's page phrase.
    static func confirmLine(pages: [Int]) -> String {
        let one = pages.count == 1
        let location = VerificationRowModel.pageLocation(pages) ?? "in the PDF"
        return (one ? "An annotation in the original covers text " : "Annotations in the original cover text ")
            + "\(location) that no redaction box covers. Annotations are not part of the page image, "
            + "so that text is visible in the exported PDF."
    }

    /// The title of the confirm when this is its only reason (new public copy).
    static let confirmTitle = "Share with covered text?"
}
