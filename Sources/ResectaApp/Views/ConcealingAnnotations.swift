import CoreGraphics
import Foundation
import PDFKit
import RedactionEngine

/// Annotations in a received PDF that can sit over page content — a black
/// square, a stamp, an unapplied redaction mark — and the text under them.
/// The on-screen view draws an annotation; the exported file is rebuilt
/// from the page content, which does not include annotations, so text an
/// annotation covered appears in the export unless a redaction box covers
/// it too. The share confirm names the pages where that is the case, on
/// every verdict (the checks read the output, where the annotation is
/// gone and the text is ordinary page text).
enum ConcealingAnnotations {

    /// Annotation subtypes that can cover content (`PDFAnnotation.type`).
    /// Links, notes, pop-ups, text markup and form widgets are excluded:
    /// they do not hide what is under them.
    static let concealingSubtypes: Set<String> = ["Square", "Circle", "Polygon", "Ink", "Stamp", "FreeText", "Redact"]

    /// 0-based pages of `document` where a concealing annotation covers
    /// text that the page's redaction boxes do not cover. Empty for no
    /// document.
    static func pages(in document: PDFDocument?, regions: [Int: [RedactionRegion]]) -> [Int] {
        guard let document else { return [] }
        var out: [Int] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let crop = page.bounds(for: .cropBox)
            guard crop.width > 0, crop.height > 0 else { continue }
            let boxes = regions[index] ?? []
            for annotation in page.annotations where concealingSubtypes.contains(annotation.type ?? "") {
                let area = annotation.bounds.intersection(crop)
                guard !area.isNull, area.width > 0, area.height > 0,
                      let text = page.selection(for: area)?.string,
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                let normalized = CGRect(x: (area.minX - crop.minX) / crop.width, y: (area.minY - crop.minY) / crop.height,
                                        width: area.width / crop.width, height: area.height / crop.height)
                if !covered(normalized, by: boxes) {
                    out.append(index)
                    break
                }
            }
        }
        return out
    }

    /// Whether `rect` (normalized page space) lies under the boxes: every
    /// point of a 12 × 4 grid inside a rectangle box. A polygon box is not
    /// counted (its rect is only its bounding box), so a partly covered
    /// annotation is still named.
    static func covered(_ rect: CGRect, by boxes: [RedactionRegion]) -> Bool {
        guard !boxes.isEmpty else { return false }
        for row in 0..<4 {
            for column in 0..<12 {
                let point = CGPoint(x: rect.minX + rect.width * (CGFloat(column) + 0.5) / 12,
                                    y: rect.minY + rect.height * (CGFloat(row) + 0.5) / 4)
                if !boxes.contains(where: { ($0.vertices?.count ?? 0) < 3 && $0.normalizedRect.contains(point) }) {
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
