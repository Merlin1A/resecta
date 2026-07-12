import Foundation
import CoreGraphics
import PDFKit
import Testing
import CryptoKit
@testable import RedactionEngine

// S01 / W2 — Resecta sample/test-document packet series.
//
// Dual-leg Stage-1 detection SNAPSHOT of the FROZEN shipped sample bank
// statement (`Resources/SampleDocument.pdf` → engine fixture
// `TestResources/sample-bank-statement.pdf`, SHA 992ca054…ce18fa20, 3 pp). This
// closes the statement's never-run pre-ship gates: revision-plan G1 (engine
// fixture copy + dual-copy identity) and handoff H2 — "the single most
// important pre-ship check" — the Stage-1 detection snapshot itself.
//
// MEASUREMENT HARNESS, not a regression guard. It surfaces every detection on
// BOTH legs across all 3 pages — text-extraction (the production path for a
// born-digital page) and OCR (the scan-sim path) — with `thresholdVector=nil`
// (everything surfaces), then dumps a committed JSON + an [OCRQ]-style console
// summary and the per-page doctype / name grouping that answer the three
// empirical questions. NO Stage-2 detection-count assertion is frozen here —
// that freeze is gated on maintainer review of this snapshot.
// The only hard assertions are mechanism facts: the dual-copy fixture-identity
// guard (SHA + page count) and the per-leg OCR-invocation behavior.
//
// MATCHED-TEXT LOGGING EXEMPTION (pending maintainer confirmation):
// CLAUDE.md's real-document rule forbids emitting running text for a real-document
// fixture. THIS fixture is categorically different — fully synthetic, with
// every planted value fixture-disclosed and synthetic — so
// logging matched text here is safe and is exactly what lets the snapshot be
// reconciled against the manifest. If the maintainer prefers conservatism, set
// `matchedText` to nil (counts + rects stay position-reconcilable to the
// manifest by page). Production logging rules (ARCH §12.2) are untouched — this
// is a test-only exemption scoped to a synthetic, publicly-manifested fixture.

@Suite("Sample bank-statement Stage-1 snapshot (S01/W2)", .serialized)
struct SampleStatementSnapshotTests {

    // MARK: - W1 dual-copy fixture identity (engine half)

    /// Engine half of the dual-copy identity guard. The app-bundle copy is
    /// pinned by `ResectaAppTests/BundleContentsTests`; the two repo files are
    /// byte-compared at commit time by `Scripts/audit-lint.sh` (M-9). Three
    /// names, one SHA — a silent fixture substitution must be loud.
    @Test("Fixture identity — SHA-256 + page count pin")
    func fixtureIdentity() throws {
        let data = try TestFixtures.sampleStatementPDF()
        let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #expect(hex == TestFixtures.sampleStatementSHA256,
                "sample-bank-statement.pdf SHA drift — the engine fixture no longer matches the frozen shipped bytes")
        let doc = try #require(PDFDocument(data: data))
        #expect(doc.pageCount == TestFixtures.sampleStatementPageCount)
    }

    // MARK: - W2 dual-leg Stage-1 snapshot (measurement; no Stage-2 freeze)

    @Test("Dual-leg Stage-1 detection snapshot — 3 pages × {text, OCR}")
    func dualLegSnapshot() async throws {
        let data = try TestFixtures.sampleStatementPDF()
        let document = try #require(PDFDocument(data: data))
        #expect(document.pageCount == TestFixtures.sampleStatementPageCount)

        let orchestrator = DetectionOrchestrator(recognitionLevel: .fast)
        let rasterizer = PageRasterizer()
        let balanced = PresetThresholdBundle.loadFromEngineBundle().presets[.balanced]

        var pageSnaps: [PageSnap] = []
        for pageIndex in 0..<document.pageCount {
            let page = try #require(document.page(at: pageIndex))

            // ── Text-extraction leg (production path for born-digital) ──
            // detectPage still needs an image (barcode/signature pass; face is
            // skipped on .financial). Text / doctype / text-PII come from the
            // embedded layer, so OCR is bypassed (provenance.ocrSkipped == true).
            let embedded = try #require(
                EmbeddedTextSource.make(from: page),
                "born-digital statement page must yield an embedded text source")
            let textLegImage = try await rasterizer.renderPage(
                page, pageIndex: pageIndex, dpi: 150)
            let textResult = try await orchestrator.detectPage(
                image: textLegImage, pageIndex: pageIndex,
                priors: PerCategoryPriors(), surfaceForms: SurfaceFormDictionary(),
                doctypeContext: nil, thresholdVector: nil,
                embeddedText: embedded, ocrSkipReason: nil)
            // Per-leg OCR-invocation mechanism fact, asserted DETERMINISTICALLY
            // via per-detection provenance — NOT the process-global
            // `OCRInvocationCounter`. The embedded-text path stamps every
            // detection `provenance.ocrSkipped = true` and never calls Vision
            // (DetectionOrchestrator.swift:301-308). The counter is mutated by
            // sibling suites running concurrently in the same batched
            // `xcodebuild` invocation, so an exact `== 0` on it is batch-fragile
            // (that pollution was the first b6 red). The non-empty guard keeps
            // the allSatisfy from passing vacuously (not a count freeze — this
            // fixture's text leg yields detections on every page).
            #expect(!textResult.detections.isEmpty,
                    "born-digital statement page must yield text-leg detections")
            #expect(textResult.detections.allSatisfy { $0.provenance.ocrSkipped },
                    "every text-leg detection must carry provenance.ocrSkipped (OCR bypassed)")

            // ── OCR leg (scan-sim path) rendered at the policy DPI for the
            //    doctype the text leg classified (financial → 200, else 150). ──
            let ocrDPI = DetectionRenderPolicy.detectionDPI(for: textResult.doctype.primary)
            let ocrImage = try await rasterizer.renderPage(
                page, pageIndex: pageIndex, dpi: ocrDPI)
            let ocrResult = try await ocrLegDetect(
                orchestrator, image: ocrImage, pageIndex: pageIndex)
            #expect(!ocrResult.detections.isEmpty,
                    "OCR leg must yield detections on the statement page")
            #expect(ocrResult.detections.allSatisfy { !$0.provenance.ocrSkipped },
                    "every OCR-leg detection must carry provenance.ocrRan")

            pageSnaps.append(PageSnap(
                pageIndex: pageIndex,
                textLeg: Self.legSnap(
                    "text", result: textResult, ocrSkipped: true,
                    renderDPI: nil, coverage: embedded.coverage, balanced: balanced),
                ocrLeg: Self.legSnap(
                    "ocr", result: ocrResult, ocrSkipped: false,
                    renderDPI: Int(ocrDPI), coverage: nil, balanced: balanced)))
        }

        let snapshot = SnapshotDoc(
            schemaVersion: 1,
            fixture: SnapshotDoc.Fixture(
                name: "sample-bank-statement.pdf",
                sha256: TestFixtures.sampleStatementSHA256,
                pageCount: TestFixtures.sampleStatementPageCount),
            generatedBy: "SampleStatementSnapshotTests (S01/W2, resecta-sample-packet-2026-06-12)",
            note: "Dual-leg Stage-1 snapshot of the FROZEN shipped statement. "
                + "thresholdVector=nil → every detection surfaces; `aboveBalanced` applies the "
                + "calibrated balanced preset (preset-thresholds.json, status=calibrated) in post. "
                + "`confidence` is the post-posterior score (absorbing-state floor 0.35, empty priors). "
                + "MEASUREMENT ONLY — no Stage-2 regression freeze (gated on Jesse's review). The text "
                + "leg is fully deterministic; OCR-leg numbers may vary by ±epsilon across Vision / "
                + "simulator-runtime versions.",
            balancedPreset: Self.balancedDump(balanced),
            pages: pageSnaps)

        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let json = String(decoding: try enc.encode(snapshot), as: UTF8.self)
        print("===SAMPLE-STATEMENT-STAGE1-JSON-BEGIN===")
        print(json)
        print("===SAMPLE-STATEMENT-STAGE1-JSON-END===")

        Self.printSummary(pageSnaps)
    }

    /// OCR-leg detect with cold-start retries. The S8 exit notes document a
    /// transient Vision "Could not create inference context" (#9) on the FIRST
    /// 200-DPI call in a fresh process; an immediate retry warms the context
    /// (`Vision200ColdStartProbeTests`). The extra attempts also absorb the
    /// Vision / memory contention this OCR-heavy suite sees when it runs inside
    /// a parallel `xcodebuild` batch. The final attempt rethrows the real error.
    private func ocrLegDetect(
        _ orchestrator: DetectionOrchestrator, image: CGImage, pageIndex: Int
    ) async throws -> PageDetectionResult {
        let maxAttempts = 3
        var lastError: Error?
        for attempt in 1...maxAttempts {
            do {
                return try await orchestrator.detectPage(
                    image: image, pageIndex: pageIndex,
                    priors: PerCategoryPriors(), surfaceForms: SurfaceFormDictionary(),
                    doctypeContext: nil, thresholdVector: nil,
                    embeddedText: nil, ocrSkipReason: nil)
            } catch {  // LegalPhrases:safe (Swift keyword)
                lastError = error          // warm the inference context, retry
                if attempt == maxAttempts { throw error }
            }
        }
        throw lastError ?? CancellationError()   // unreachable; satisfies the type checker
    }

    // MARK: - Snapshot model (forward-compatible subset of the D12 ground-truth schema)

    struct SnapshotDoc: Codable {
        let schemaVersion: Int
        let fixture: Fixture
        let generatedBy: String
        let note: String
        let balancedPreset: [String: Double]
        let pages: [PageSnap]
        struct Fixture: Codable { let name: String; let sha256: String; let pageCount: Int }
    }
    struct PageSnap: Codable {
        let pageIndex: Int
        let textLeg: LegSnap
        let ocrLeg: LegSnap
    }
    struct LegSnap: Codable {
        let leg: String                 // "text" | "ocr"
        let ocrSkipped: Bool            // leg contract: text bypasses Vision, OCR runs it
        let renderDPI: Int?             // OCR leg only
        let coverage: Double?           // text leg only — selectable-text coverage in [0,1]
        let doctype: DoctypeSnap
        let detectionCount: Int
        let detections: [DetSnap]
    }
    struct DoctypeSnap: Codable {
        let primary: String
        let runnerUp: String?
        let softmax: [String: Double]
        let topKeywords: [String]       // "keyword→class:weight" — closed-vocabulary classifier tokens
    }
    struct DetSnap: Codable {
        let category: String            // wire name (preset key); face/barcode/signatureCandidate otherwise
        let confidence: Double          // post-posterior (thresholdVector=nil → ungated)
        let balancedThreshold: Double?  // nil for non-calibration categories
        let aboveBalanced: Bool?        // confidence >= balancedThreshold
        let normalizedRect: [Double]    // [x, y, w, h], 0–1 bottom-left origin, rounded
        let matchedText: String?        // logging exemption (synthetic, manifested fixture)
    }

    // MARK: - Builders

    static func legSnap(
        _ leg: String, result: PageDetectionResult, ocrSkipped: Bool,
        renderDPI: Int?, coverage: Double?,
        balanced: PresetThresholdVector?
    ) -> LegSnap {
        let dets: [DetSnap] = result.detections.map { d in
            let conf = r4(d.confidence)
            let thr = balancedThreshold(for: d.kind, balanced)
            return DetSnap(
                category: wireName(for: d.kind),
                confidence: conf,
                balancedThreshold: thr.map(r4),
                aboveBalanced: thr.map { conf >= $0 },
                normalizedRect: [
                    r4(Double(d.normalizedRect.minX)), r4(Double(d.normalizedRect.minY)),
                    r4(Double(d.normalizedRect.width)), r4(Double(d.normalizedRect.height))],
                matchedText: d.matchedText)
        }.sorted(by: detOrder)
        return LegSnap(
            leg: leg, ocrSkipped: ocrSkipped,
            renderDPI: renderDPI, coverage: coverage.map(r4),
            doctype: doctypeSnap(result.doctype),
            detectionCount: dets.count, detections: dets)
    }

    /// Deterministic order so the committed JSON does not churn: top-of-page
    /// first (y descending, bottom-left origin), then left-to-right, then
    /// category, then matched text.
    static func detOrder(_ a: DetSnap, _ b: DetSnap) -> Bool {
        if a.normalizedRect[1] != b.normalizedRect[1] { return a.normalizedRect[1] > b.normalizedRect[1] }
        if a.normalizedRect[0] != b.normalizedRect[0] { return a.normalizedRect[0] < b.normalizedRect[0] }
        if a.category != b.category { return a.category < b.category }
        return (a.matchedText ?? "") < (b.matchedText ?? "")
    }

    static func doctypeSnap(_ r: DoctypeResult) -> DoctypeSnap {
        DoctypeSnap(
            primary: r.primary.rawValue,
            runnerUp: r.runnerUp?.rawValue,
            softmax: Dictionary(uniqueKeysWithValues:
                r.softmax.map { ($0.key.rawValue, r4($0.value)) }),
            topKeywords: r.topKeywords.map {
                "\($0.keyword)→\($0.classContributedTo.rawValue):\(r4($0.weight))" })
    }

    static func balancedDump(_ v: PresetThresholdVector?) -> [String: Double] {
        guard let v else { return [:] }
        var out: [String: Double] = [:]
        for cat in PIICategory.allCases {
            if let wire = PresetThresholdVector.wireName(for: cat),
               let t = v.threshold(for: cat) { out[wire] = r4(t) }
        }
        return out
    }

    static func wireName(for kind: DetectionResult.Kind) -> String {
        switch kind {
        case .pii(let k):
            if let cat = PIICategory(piiKind: k) {
                return PresetThresholdVector.wireName(for: cat) ?? String(describing: k)
            }
            return String(describing: k)   // barcode / signatureCandidate / other
        case .face: return "face"
        case .searchMatch: return "searchMatch"
        }
    }

    static func balancedThreshold(
        for kind: DetectionResult.Kind, _ v: PresetThresholdVector?
    ) -> Double? {
        guard case .pii(let k) = kind, let cat = PIICategory(piiKind: k) else { return nil }
        return v?.threshold(for: cat)
    }

    static func r4(_ d: Double) -> Double { (d * 10_000).rounded() / 10_000 }

    // MARK: - Console summary + raw material for the three empirical answers

    static func printSummary(_ pages: [PageSnap]) {
        print("[OCRQ-stmt] ───── sample bank-statement Stage-1 snapshot ─────")
        for p in pages {
            for leg in [p.textLeg, p.ocrLeg] {
                let dpi = leg.renderDPI.map { " dpi=\($0)" } ?? ""
                let cov = leg.coverage.map { " coverage=\($0)" } ?? ""
                print("[OCRQ-stmt] p\(p.pageIndex) leg=\(leg.leg) doctype=\(leg.doctype.primary)"
                    + " runnerUp=\(leg.doctype.runnerUp ?? "-") ocrSkipped=\(leg.ocrSkipped)"
                    + "\(dpi)\(cov) detections=\(leg.detectionCount)")
                var total: [String: Int] = [:], above: [String: Int] = [:]
                for d in leg.detections {
                    total[d.category, default: 0] += 1
                    if d.aboveBalanced == true { above[d.category, default: 0] += 1 }
                }
                for cat in total.keys.sorted() {
                    print("[OCRQ-stmt]     \(cat): \(above[cat] ?? 0)/\(total[cat] ?? 0) ≥balanced")
                }
            }
        }
        // Q-doctype
        if let p0 = pages.first {
            print("[OCRQ-stmt] Q-doctype: p0 text-leg primary=\(p0.textLeg.doctype.primary)"
                + " softmax=\(p0.textLeg.doctype.softmax.sorted { $0.key < $1.key })")
            print("[OCRQ-stmt] Q-doctype: p0 text-leg topKeywords=\(p0.textLeg.doctype.topKeywords)")
        }
        // Q-name-bloom + Q-uniformity: page-1 name detections grouped by matched text.
        if let p0 = pages.first {
            for leg in [p0.textLeg, p0.ocrLeg] {
                let names = leg.detections.filter { $0.category == "name" }
                if names.isEmpty {
                    print("[OCRQ-stmt] Q-name p0 leg=\(leg.leg): NO name detections")
                    continue
                }
                var byText: [String: [DetSnap]] = [:]
                for n in names { byText[n.matchedText ?? "<nil>", default: []].append(n) }
                for (txt, group) in byText.sorted(by: { $0.key < $1.key }) {
                    let confs = group.map(\.confidence).sorted()
                    let allCaps = txt == txt.uppercased() && txt != txt.lowercased()
                    let aboveN = group.filter { $0.aboveBalanced == true }.count
                    print("[OCRQ-stmt] Q-name p0 leg=\(leg.leg) \"\(txt)\" ×\(group.count)"
                        + " conf=[\(confs.first ?? 0)…\(confs.last ?? 0)] allCaps=\(allCaps)"
                        + " ≥balanced=\(aboveN)/\(group.count)")
                }
            }
        }
    }
}
