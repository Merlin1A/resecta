import Foundation
import PDFKit
import Testing
#if canImport(UIKit)
import UIKit
#endif
@testable import RedactionEngine

// Scan-simulation fixture support.
//
// Born-digital and scanned PDFs exercise Vision OCR differently. The in-repo
// PDF-to-raster builder that once lived here was superseded by the sd
// (sample-doc) repo's cross-repo Python scan-sim pipeline, which produces the
// committed scan-sim fixture PDFs directly; `FixtureError.unreadableSource`
// remains as the shared "fixture failed to load" signal `RealDocOCRQualityTests`
// throws when reading those shipped fixtures.

enum ScanSimulatorFixtureBuilder {

    enum FixtureError: Error {
        case unreadableSource
    }
}

// MARK: - Synthetic small-text fixture (minimumTextHeight adversarial)

/// Builds a deterministic 3-page letter-size document — one page per font
/// size (7 pt, 8 pt, 9 pt), the tax-form box-label sizes this suite
/// targets. One size per page makes per-size attribution trivial (page
/// index), with no rect-band bookkeeping. All content is synthetic
/// (G8-style fake identifiers); safe to log.
enum SmallTextFixtureBuilder {

    /// Page i carries fontSizes[i] exclusively.
    static let fontSizes: [CGFloat] = [7, 8, 9]
    /// Structurally VALID fake SSN — must pass SSNStructuralValidator
    /// (the Woolworth SSN 078-05-1120 is rejected by its Rule 6, which
    /// silently zeroed this fixture's SSN row on the first baseline run).
    static let ssnToken = "536-22-4918"

    /// Rasterized variant: each text page is rendered to a JPEG raster and
    /// re-assembled without a text layer, so detection must OCR it — the
    /// born-digital variant would ride the embedded-text path in production
    /// while the harness forces OCR for both; the raster variant is the
    /// honest scan analogue.
    static func buildDocument() -> Data {
        let letter = CGRect(x: 0, y: 0, width: 612, height: 792)
        let renderer = UIGraphicsPDFRenderer(bounds: letter)
        return renderer.pdfData { context in
            for size in fontSizes {
                context.beginPage()
                let font = UIFont.systemFont(ofSize: size)
                let attrs: [NSAttributedString.Key: Any] = [.font: font]
                // Form-box style label + value rows, mimicking 1099/W-2
                // box labels.
                let rows = [
                    "Box 1a Employer identification number EIN 12-3456789",
                    "Box 1b Recipient social security number SSN \(ssnToken)",
                    "Box 1c Routing number 021000021 Account number 000123456789",
                    "Form 1099-INT taxpayer identification recipient copy B",
                ]
                var y: CGFloat = 72
                for row in rows {
                    (row as NSString).draw(
                        at: CGPoint(x: 72, y: y), withAttributes: attrs
                    )
                    y += size * 2.4
                }
            }
        }
    }
}

// MARK: - Synthetic 20-page memory/latency document

/// Deterministic 20-page letter-size text document for the memory revert
/// criterion ("peak memory during detection … on a 20-page
/// letter-page document") and the latency budget run. Body text at 11 pt
/// with sparse synthetic PII tokens — content is constant across runs so
/// 150-vs-200 DPI deltas isolate the render/OCR cost.
enum TwentyPageFixtureBuilder {

    static let pageCount = 20

    static func buildDocument() -> Data {
        let letter = CGRect(x: 0, y: 0, width: 612, height: 792)
        let renderer = UIGraphicsPDFRenderer(bounds: letter)
        let body = UIFont.systemFont(ofSize: 11)
        let attrs: [NSAttributedString.Key: Any] = [.font: body]
        return renderer.pdfData { context in
            for page in 0..<pageCount {
                context.beginPage()
                var y: CGFloat = 60
                for line in 0..<40 {
                    // Deterministic filler with occasional PII-shaped rows.
                    let text: String
                    if line % 13 == 5 {
                        text = "Account statement reference SSN 536-22-4918 page \(page + 1)"
                    } else if line % 13 == 9 {
                        text = "Wire routing number 021000021 institution First Example Bank"
                    } else {
                        text = "Paragraph \(page + 1).\(line) — standard disclosure text for layout density."
                    }
                    (text as NSString).draw(at: CGPoint(x: 54, y: y), withAttributes: attrs)
                    y += 16.5
                }
            }
        }
    }
}
