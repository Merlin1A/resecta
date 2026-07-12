import Foundation
import PDFKit

// PDFKit annotation analysis and profile classification.
// Uses PDFKit (PDFDocument, PDFAnnotation), NOT CGPDFDocument.
// Profile detection is conservative — defaults to .unredacted (OQ-4).

/// Analyzes PDF annotations for profile classification and annotation detection.
/// Stateless, nonisolated struct.
public struct AnnotationAnalyzer: Sendable {

    public init() {}

    /// Enumerate all annotations across all pages.
    /// Returns findings and profile classification.
    @concurrent
    public func analyze(document: PDFDocument) async
        -> (findings: [PDFFinding], profile: DocumentProfile)
    {
        var typeCounts: [String: (count: Int, pages: Set<Int>)] = [:]
        var redactMarkCount = 0
        var blackSquareCount = 0

        for i in 0..<document.pageCount {
            guard let page = document.page(at: i) else { continue }
            let annotations = page.annotations

            for annotation in annotations {
                let subtype = annotation.type ?? "Unknown"

                // Skip widget annotations — form fields are reported via /AcroForm
                if subtype == "Widget" { continue }

                // Track counts per type
                var entry = typeCounts[subtype, default: (count: 0, pages: [])]
                entry.count += 1
                entry.pages.insert(i)
                typeCounts[subtype] = entry

                // Profile detection (OQ-4, conservative):
                if subtype == "Redact" {
                    redactMarkCount += 1
                } else if isBlackFilledSquare(annotation) {
                    blackSquareCount += 1
                }
            }
        }

        // Build findings — one per annotation type found
        var findings: [PDFFinding] = []
        for (subtype, info) in typeCounts.sorted(by: { $0.key < $1.key }) {
            let pageList = info.pages.sorted()
            let pageDesc = pageList.count <= 3
                ? pageList.map { "page \($0 + 1)" }.joined(separator: ", ")
                : "\(pageList.count) pages"
            findings.append(PDFFinding(
                id: "annotation-\(subtype.lowercased())",
                summary: "\(info.count) \(subtype.lowercased()) annotation\(info.count == 1 ? "" : "s") found across \(pageDesc)",
                severity: severity(for: subtype),
                pageIndices: pageList
            ))
        }

        // Determine profile
        let totalRedactionMarks = redactMarkCount + blackSquareCount
        let profile: DocumentProfile = totalRedactionMarks > 0
            ? .redacted(markCount: totalRedactionMarks)
            : .unredacted

        return (findings, profile)
    }

    // MARK: - Private

    /// Check if an annotation looks like a black-filled square/rect used as a
    /// fake redaction. Criteria: Square or FreeText type with black interior fill
    /// and no meaningful text content.
    private func isBlackFilledSquare(_ annotation: PDFAnnotation) -> Bool {
        let subtype = annotation.type ?? ""
        guard subtype == "Square" || subtype == "FreeText" else { return false }

        guard let interior = annotation.interiorColor else { return false }

        // Check if fill is black or very dark
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        #if canImport(UIKit)
        interior.getRed(&r, green: &g, blue: &b, alpha: &a)
        #else
        // macOS tooling destination: PDFAnnotation.color is NSColor, whose
        // getRed throws on non-RGB colorspaces (UIColor converts implicitly).
        guard let rgb = interior.usingColorSpace(.extendedSRGB) else { return false }
        rgb.getRed(&r, green: &g, blue: &b, alpha: &a)
        #endif
        let isDark = r < 0.1 && g < 0.1 && b < 0.1 && a > 0.5

        guard isDark else { return false }

        // If it has text content, it's not a redaction mark
        if let contents = annotation.contents, !contents.trimmingCharacters(in: .whitespaces).isEmpty {
            return false
        }

        return true
    }

    /// Determine finding severity based on annotation subtype.
    private func severity(for subtype: String) -> PDFFinding.Severity {
        switch subtype {
        case "Link", "URI":
            return .info
        case "Redact":
            return .warning
        case "FileAttachment", "RichMedia", "Screen", "Sound", "Movie":
            return .critical
        default:
            return .info
        }
    }
}
