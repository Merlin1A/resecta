import Foundation
import CoreGraphics
import PDFKit
import Testing
import CryptoKit
@testable import RedactionEngine

// H2.2 support (2/2): evidence-record types, JSON/hash helpers, and
// the fixed region-set recipes (statement grid + the RawPDFBuilder
// adversarial factory set the plan names).

extension VerificationCorpusRunnerTests {

    // MARK: - Output records

    struct RegionRow: Encodable {
        let page: Int
        let rect: [Double]
        let polygon: Bool
        let gt_id: String?
        let value: String?
        let category: String?
    }

    struct TermRow: Encodable {
        let text: String
        let requires_token_boundary: Bool
    }

    struct RegionsJSON: Encodable {
        let schema_version: Int
        let generated_by: String
        let doc_id: String
        let mode: String
        let region_set: String
        let region_source: String
        let params: [String: Int]?
        let doc_sha256: String
        let page_count: Int
        let text_layer_status: [String]
        let has_hidden_ocg: Bool
        let regions: [RegionRow]
        let floor_dropped: [String]
        let sensitive_terms: [TermRow]
        let expected_visible_terms: [String]
        let notes: String
    }

    struct CellJSON: Encodable {
        let schema_version: Int
        let doc_id: String
        let mode: String
        let region_set: String
        let verify_only: Bool
        let n_verification_sweeps: Int
        let output_sha256: String
        let redaction_seconds: Double
        let per_page_modes: [String]
        let per_page_fallback_reasons: [String?]
        let overall_per_sweep: [String]
        let layer_status_per_sweep: [[String]]
        let non_ocr_layers_identical: Bool
        /// Per page (nil for a Secure page): extracted · excluded · surviving ·
        /// surviving_non_ws from the redaction's filter digest.
        let filter_digest_counts: [[Int]?]
        /// Per page (nil for a Secure page): survivors the writer-side
        /// drawn-cell rule dropped after the filter.
        let drawn_cell_rule_drops: [Int?]
        /// Per output page: the axis the spatial check read the text layer
        /// along — "x", "y-down" (`/Rotate 90`), "y-up" (`/Rotate 270`);
        /// nil for a page with no text layer or fewer than two measurable
        /// units. Pins "x on every unrotated page".
        let spatial_lattice_axes: [String?]
    }

    struct RunnerSummary: Encodable {
        let schema_version: Int
        let generated_by: String
        let platform_note: String
        let cells_run: [String]
        let cells_skipped: [String: String]
        let sha_mismatches: [String]
    }

    static func r6(_ v: Double) -> Double { (v * 1e6).rounded() / 1e6 }

    static func writeJSON<T: Encodable>(_ value: T, to path: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Duration-free identity tuple for the cross-sweep determinism check.
    /// Eight elements: name · status case · message · short · detail ·
    /// pages · review terms · the could-not-verify flag.
    static func layerIdentity(_ layer: LayerResult) -> String {
        let statusCase: String
        let message: String
        switch layer.status {
        case .pass: statusCase = "pass"; message = ""
        case .warn(let m): statusCase = "warn"; message = m
        case .info(let m): statusCase = "info"; message = m
        case .attention(let m): statusCase = "attention"; message = m
        case .fail(let m): statusCase = "fail"; message = m
        case .skipped: statusCase = "skipped"; message = ""
        }
        let pages = layer.pageReferences.map { $0.map(String.init).joined(separator: ",") } ?? "-"
        let terms = layer.reviewTermTexts?.joined(separator: "|") ?? "-"
        let flag = layer.couldNotVerify ? "could_not_verify" : "-"
        return [layer.name, statusCase, message, layer.shortDescription,
                layer.detailDescription, pages, terms, flag].joined(separator: "\u{1F}")
    }

    static func statusCaseName(_ status: VerificationStatus) -> String {
        switch status {
        case .pass: "pass"
        case .warn: "warn"
        case .info: "info"
        case .attention: "attention"
        case .fail: "fail"
        case .skipped: "skipped"
        }
    }

    // MARK: - Fixed region-set helpers (non-GT documents)

    static func fixedSet(
        _ name: String, seeds: [RegionSeed]
    ) -> RegionSetSpec {
        RegionSetSpec(name: name, seeds: seeds, polygon: false, params: nil)
    }

    static func seed(
        _ gtId: String, value: String = "", category: String = "",
        page: Int, x: Double, y: Double, w: Double, h: Double
    ) -> RegionSeed {
        RegionSeed(gtId: gtId, value: value, category: category, page: page,
                   rect: CGRect(x: x, y: y, width: w, height: h))
    }

    /// The statement carries no drawable GT (carried_stmt geometry is
    /// count-declared) — a deterministic per-page grid probes fill +
    /// placement + structure fidelity without term claims.
    static func statementGridSeeds(pageCount: Int) -> [RegionSeed] {
        (0..<pageCount).flatMap { p in
            [seed("grid_p\(p)_a", page: p, x: 0.10, y: 0.15, w: 0.35, h: 0.08),
             seed("grid_p\(p)_b", page: p, x: 0.55, y: 0.60, w: 0.30, h: 0.08)]
        }
    }

    /// The RawPDFBuilder adversarial set the plan names (§2 input assets):
    /// JavaScript, metadata, embedded file, annotations, rotation, OCG hidden
    /// layer, two-image page, GPS JPEG, incremental update, Bland kerning
    /// injection, fake redaction. Regions/terms per factory geometry.
    static func factoryInputs() -> [CellInput] {
        let fullPage = [seed("full-page", page: 0, x: 0, y: 0, w: 1, h: 1)]
        let centered = [seed("center-box", page: 0,
                             x: 0.25, y: 0.40, w: 0.50, h: 0.20)]
        func input(
            _ id: String, _ data: Data, seeds: [RegionSeed],
            terms: [(String, Bool)], expectedVisible: [String] = [],
            notes: String
        ) -> CellInput {
            CellInput(
                docId: id, data: data, docSHA: sha256Hex(data),
                regionSet: fixedSet("factory", seeds: seeds),
                regionSource: "factory",
                expectedVisible: expectedVisible,
                notes: notes,
                verifyOnly: false,
                termsOverride: terms.map {
                    SensitiveTerm(text: $0.0, requiresTokenBoundary: $0.1)
                })
        }
        return [
            input("factory-javascript", TestFixtures.withJavaScript(),
                  seeds: centered, terms: [],
                  notes: "catalog /JavaScript action; empty page"),
            input("factory-metadata",
                  TestFixtures.withMetadata(
                    ["Author": "Delia Hartwell", "Subject": "Loan File 4471"]),
                  seeds: centered,
                  terms: [("Delia Hartwell", false), ("Loan File 4471", false)],
                  notes: "/Info Author+Subject carry the terms; empty page"),
            input("factory-embedded-file",
                  TestFixtures.withEmbeddedFile(filename: "secret.txt"),
                  seeds: centered,
                  terms: [("hello world", false), ("secret.txt", false)],
                  notes: "/Names/EmbeddedFiles filespec + stream content"),
            input("factory-annotations",
                  TestFixtures.withAnnotations(
                    subtypes: [.square, .highlight, .link]),
                  seeds: centered, terms: [],
                  notes: "PDFKit annotations with appearance streams"),
            input("factory-rotated-text-90",
                  TestFixtures.rotatedTextPDF(rotation: 90),
                  seeds: fullPage,
                  terms: [("ANCHOR", false), ("MARKER", false)],
                  notes: "/Rotate 90 + asymmetric extractable text; full-page region sidesteps displayed-space mapping"),
            input("factory-ocg-hidden",
                  TestFixtures.ocgHiddenLayerPDF(),
                  seeds: fullPage,
                  terms: [("HIDDEN SECRET", false)],
                  notes: "OCG-off hidden layer text; full-page region"),
            input("factory-two-image",
                  TestFixtures.twoImageJPEGPagePDF(),
                  seeds: [seed("image-alpha", page: 0,
                               x: 50.0 / 612, y: 520.0 / 792,
                               w: 300.0 / 612, h: 150.0 / 792)],
                  terms: [("ALPHA", false)],
                  expectedVisible: ["BRAVO"],
                  notes: "two DCTDecode XObjects; only the upper (ALPHA) image is redacted — BRAVO must survive"),
            input("factory-gps-jpeg",
                  TestFixtures.gpsJPEGPagePDF(),
                  seeds: [seed("image-gps", page: 0,
                               x: 106.0 / 612, y: 246.0 / 792,
                               w: 400.0 / 612, h: 400.0 / 792)],
                  terms: [],
                  notes: "GPS EXIF JPEG page; oracle checks EXIF survival"),
            input("factory-incremental-update",
                  TestFixtures.incrementalUpdate(),
                  seeds: fullPage,
                  terms: [("ORIGINAL SECRET", false), ("REDACTED", false)],
                  notes: "appended second chunk after %%EOF (prior-revision surface)"),
            input("factory-kerning-injection",
                  TestFixtures.withBlandKerningInjection(),
                  seeds: [seed("kerned-run", page: 0,
                               x: 95.0 / 612, y: 693.0 / 792,
                               w: 110.0 / 612, h: 26.0 / 792)],
                  terms: [("ABCDEFGH", false)],
                  notes: "TJ kerning displacement (Bland-Iyer-Levchenko sim)"),
            input("factory-fake-redaction",
                  TestFixtures.fakeRedaction(),
                  seeds: [seed("covered-text", page: 0,
                               x: 70.0 / 612, y: 690.0 / 792,
                               w: 300.0 / 612, h: 40.0 / 792)],
                  terms: [("CLASSIFIED SECRET", false)],
                  notes: "black square annotation over live text; the real region burn must remove the text the annotation only covered"),
        ]
    }

    /// The Layer-10 normalization-parity cell (C12-108; searchable only): the
    /// term's plain spelling is burned; a compatibility-form spelling (the
    /// ordinal indicator ª for the `a`, NFKC image `a`) survives outside the
    /// region into the rebuilt text layer. Layer 3 scans the decoded page
    /// text in its normalized form as well as as-extracted; Layer 10 must
    /// read the same residue from the operator text. Terms = the plain
    /// term; `expectedVisible` = the anchor line.
    static func compatResidueInputs() -> [CellInput] {
        let data = TestFixtures.compatFormResiduePDF()
        let burn = TestFixtures.compatPlantBurnTd
        return [
            CellInput(
                docId: "factory-compat-residue", data: data, docSHA: sha256Hex(data),
                regionSet: fixedSet("factory", seeds: [
                    seed("compat-plain-line", page: 0,
                         x: (burn.x - 6) / 612, y: (burn.y - 10) / 792,
                         w: 220.0 / 612, h: 40.0 / 792),
                ]),
                regionSource: "factory",
                expectedVisible: ["COMPAT VISIBLE ANCHOR LINE"],
                notes: "the term's plain spelling is burned; its compatibility-form spelling (ordinal indicator for the a) survives outside the region — Layer 3's normalized scan and Layer 10's operator scan must agree",
                verifyOnly: false,
                termsOverride: [SensitiveTerm(text: "plant-engcompat-01", requiresTokenBoundary: false)]),
        ]
    }
}
