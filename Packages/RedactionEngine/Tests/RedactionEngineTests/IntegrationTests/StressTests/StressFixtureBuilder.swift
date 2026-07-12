import CoreGraphics
import Foundation
import PDFKit
#if canImport(UIKit)
import UIKit
#endif

// PERF-7 — Programmatic PDFKit stress-fixture builder.
//
// Produces a deterministic, seed-reproducible synthetic PDF for the
// 500-page stress corpus. Each page renders a form-template-like layout
// (header, labeled fields, body paragraph) using a small fixed lexicon
// so the output is reproducible from `(pageCount, seed)` alone.
//
// The output PDF is gitignored at test-runtime (see `.gitignore` entry
// `stress-corpus-*.pdf`). The committed artifact is the result JSON
// produced by `StressCorpusTests`, not the fixture itself.
//
// Design notes:
//   - Uses `UIGraphicsPDFRenderer` (the same path `RawPDFBuilder` uses)
//     because it produces a real text layer the engine pipeline can
//     parse. Pure `CGContext` writers can produce text-as-glyph-outlines
//     and miss the text-extraction codepath.
//   - Page geometry is US Letter (612 x 792 pt) to match the canonical
//     test fixtures and the default `cropBox` assumptions in
//     `PageRasterizer`.
//   - A locally-seeded LCG drives word selection so a given
//     `(pageCount, seed)` pair always emits byte-identical pages. The
//     LCG is intentionally minimal — this is fixture-determinism, not
//     a cryptographic RNG.
//   - Target text density: roughly 500 word-tokens per page mixed
//     with form-field labels. The renderer truncates at the page edge,
//     so a few extra tokens past 500 are harmless.

enum StressFixtureBuilder {

    /// Build a deterministic synthetic stress-test PDF.
    ///
    /// - Parameters:
    ///   - pageCount: number of pages (default 500 per the PERF-7 plan).
    ///   - seed: LCG seed; identical seeds produce identical bytes
    ///     within the same Swift runtime. Default 42 matches the
    ///     plan body's reproducibility target.
    ///   - directory: destination directory; defaults to a per-call
    ///     UUID subdirectory under the test bundle's temporary path.
    /// - Returns: file URL of the generated fixture. The caller owns
    ///   cleanup; tests typically `removeItem(at:)` in a `defer` block.
    static func buildStressFixture(
        pageCount: Int = 500,
        seed: UInt64 = 42,
        directory: URL? = nil
    ) throws -> URL {
        let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792)
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect)

        // Per-call UUID subdirectory so parallel test runs (Swift
        // Testing runs `@Test` cases concurrently within a suite by
        // default) do not race over the same file path.
        let parentDir = directory ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("StressFixtures", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: parentDir, withIntermediateDirectories: true
        )
        let fixtureURL = parentDir.appendingPathComponent(
            "stress-corpus-\(pageCount)-\(seed).pdf"
        )

        var rng = SeededLCG(seed: seed)

        try renderer.writePDF(to: fixtureURL) { context in
            for pageIndex in 0..<pageCount {
                context.beginPage()
                Self.drawSyntheticFormPage(
                    pageIndex: pageIndex, rng: &rng, in: pageRect
                )
            }
        }

        return fixtureURL
    }

    // MARK: - Page Composition

    /// Lay out a single page: header band, labeled-field block, body paragraph.
    /// The mix is chosen so each page contains both short label-like text
    /// (typical of form templates) and longer paragraph text (typical of
    /// narrative report sections) — both shapes the engine pipeline
    /// exercises during text-layer extraction.
    private static func drawSyntheticFormPage(
        pageIndex: Int,
        rng: inout SeededLCG,
        in pageRect: CGRect
    ) {
        let margin: CGFloat = 54   // 0.75 inch
        let lineHeight: CGFloat = 14
        let bodyFont = UIFont.systemFont(ofSize: 10)
        let headerFont = UIFont.boldSystemFont(ofSize: 14)
        let labelFont = UIFont.systemFont(ofSize: 11, weight: .semibold)

        // Header band — page number plus a fixed pseudo-title token.
        let header = "Synthetic Form Template — Page \(pageIndex + 1)"
        Self.drawText(
            header, font: headerFont, color: .black,
            at: CGPoint(x: margin, y: margin)
        )

        // Labeled-field block — six rows of "Label: value" pairs. The
        // values are drawn from the lexicon so they look like form
        // entries but contain no real PII.
        var y = margin + 28
        for _ in 0..<6 {
            let label = StressLexicon.label(&rng) + ":"
            let value = StressLexicon.fieldValue(&rng)
            Self.drawText(
                label, font: labelFont, color: .black,
                at: CGPoint(x: margin, y: y)
            )
            Self.drawText(
                value, font: bodyFont, color: .black,
                at: CGPoint(x: margin + 130, y: y + 1)
            )
            y += lineHeight + 4
        }

        // Body paragraph(s) — densest text region. ~500 words split
        // across roughly 50 lines of ~10 words each. We break lines
        // greedily so word wrap matches the available column width.
        y += lineHeight
        let bodyOriginY = y
        let maxLineWidth = pageRect.width - 2 * margin
        let wordsPerPage = 500
        var lineBuffer = ""
        var emittedLines = 0
        var emittedWords = 0
        let maxLines = Int((pageRect.height - bodyOriginY - margin) / lineHeight)

        while emittedWords < wordsPerPage && emittedLines < maxLines {
            let word = StressLexicon.bodyWord(&rng)
            let candidate = lineBuffer.isEmpty ? word : "\(lineBuffer) \(word)"
            let candidateWidth = (candidate as NSString).size(withAttributes: [
                .font: bodyFont
            ]).width
            if candidateWidth > maxLineWidth, !lineBuffer.isEmpty {
                Self.drawText(
                    lineBuffer, font: bodyFont, color: .black,
                    at: CGPoint(
                        x: margin,
                        y: bodyOriginY + CGFloat(emittedLines) * lineHeight
                    )
                )
                emittedLines += 1
                lineBuffer = word
            } else {
                lineBuffer = candidate
            }
            emittedWords += 1
        }
        if !lineBuffer.isEmpty, emittedLines < maxLines {
            Self.drawText(
                lineBuffer, font: bodyFont, color: .black,
                at: CGPoint(
                    x: margin,
                    y: bodyOriginY + CGFloat(emittedLines) * lineHeight
                )
            )
        }
    }

    private static func drawText(
        _ text: String, font: UIFont, color: UIColor, at point: CGPoint
    ) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color
        ]
        (text as NSString).draw(at: point, withAttributes: attrs)
    }
}

// MARK: - Deterministic Lexicon

/// Fixed-size word lists driving page content. The lists are deliberately
/// short (under 100 entries each) so the LCG modulus has tight cycles —
/// the goal is reproducibility, not natural-language coverage.
enum StressLexicon {
    static let labels: [String] = [
        "Patient", "Provider", "Account", "Reference", "Specimen",
        "Diagnosis", "Procedure", "Encounter", "Episode", "Plan",
        "Authorization", "Subscriber", "Insurance", "Group", "Member",
        "Visit", "Service", "Facility", "Department", "Clinician"
    ]

    static let fieldValueTokens: [String] = [
        "A1B2C3", "X9Y8Z7", "M0N1P2", "Q3R4S5", "T6U7V8",
        "AB-1234", "CD-5678", "EF-9012", "GH-3456", "IJ-7890",
        "Pending", "Approved", "Denied", "Submitted", "Resolved",
        "Sample", "Synthetic", "Placeholder", "Draft", "Final"
    ]

    static let bodyWords: [String] = [
        "the", "patient", "record", "indicates", "a", "consultation",
        "with", "an", "internal", "review", "team", "regarding",
        "policy", "compliance", "documentation", "and", "follow-up",
        "appointments", "scheduled", "for", "the", "subsequent",
        "billing", "cycle", "consistent", "with", "department",
        "guidance", "and", "facility", "operational", "procedures",
        "synthetic", "data", "elements", "stand", "in", "for",
        "protected", "identifiers", "throughout", "this", "block",
        "to", "exercise", "text-layer", "extraction", "without",
        "introducing", "real", "world", "personal", "information",
        "into", "the", "test", "corpus", "while", "preserving",
        "realistic", "token", "density", "and", "line", "wrapping",
        "characteristics", "across", "page", "boundaries", "for",
        "the", "stress", "fixture", "builder", "used", "by",
        "the", "regression", "baseline", "harness", "managed", "by",
        "the", "continuous", "integration", "workflow"
    ]

    static func label(_ rng: inout SeededLCG) -> String {
        labels[Int(rng.next() % UInt64(labels.count))]
    }

    static func fieldValue(_ rng: inout SeededLCG) -> String {
        // Compose two tokens to give variety without doubling the
        // base list size.
        let a = fieldValueTokens[Int(rng.next() % UInt64(fieldValueTokens.count))]
        let b = fieldValueTokens[Int(rng.next() % UInt64(fieldValueTokens.count))]
        return "\(a) \(b)"
    }

    static func bodyWord(_ rng: inout SeededLCG) -> String {
        bodyWords[Int(rng.next() % UInt64(bodyWords.count))]
    }
}

// MARK: - Seeded RNG

/// Minimal linear congruential generator. Constants are the Numerical
/// Recipes LCG (Park-Miller-style modulus is overkill here — this is
/// fixture-reproducibility, not statistical randomness). The generator
/// is intentionally NOT `SystemRandomNumberGenerator` because the goal
/// is byte-identical re-runs across processes and machines.
struct SeededLCG {
    private var state: UInt64

    init(seed: UInt64) {
        // Avoid the zero-fixed-point of pure multiplicative LCGs.
        self.state = seed == 0 ? 0xDEAD_BEEF_CAFE_F00D : seed
    }

    mutating func next() -> UInt64 {
        // a, c values from Numerical Recipes (Press et al., 2nd ed.).
        state = state &* 1664525 &+ 1013904223
        return state
    }
}
