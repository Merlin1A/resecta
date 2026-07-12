import Foundation
import CoreGraphics
import PDFKit
import Testing
import CryptoKit
@testable import RedactionEngine

// S05 / Step A -- Resecta sample/test-document packet series.
//
// Dual-leg Stage-1 detection SNAPSHOT of the synthetic Hartwell loan packet
// (`~/resecta-sample-doc` generator -> engine fixture
// `TestResources/packet.pdf`, SHA 362375692b8c..., 12 pp). This is the FIRST
// session that runs the detection engine on the packet; it is the measurement
// the P/R harness (PacketPRHarnessTests) and the must-fire freeze consume.
//
// Mirrors `SampleStatementSnapshotTests` (S01): for each of the 12 pages it runs
// BOTH legs -- text-extraction (the production path for a born-digital page) and
// OCR (the scan-sim path) -- with `thresholdVector=nil` (every detection
// surfaces), then dumps a committed JSON + an [OCRQ]-style console summary plus
// the per-page doctype / overlap-suppression data that answer the S05 questions
// (VEH .generic; account->phone collision; per-leg text coverage).
//
// MEASUREMENT HARNESS, not a regression guard. The ONLY hard assertions are
// mechanism facts: fixture identity (SHA + page count) and the per-leg
// OCR-invocation contract (text bypasses Vision; OCR runs it). NO Stage-2
// detection-count / fire-miss assertion is frozen here -- that freeze is the
// must-fire smoke suite (S05 Step C), gated on this snapshot's measurement.
//
// SCHEMA: a forward-compatible SUPERSET of the S01 snapshot schema
// (`sample-statement-stage1.json`) -- identical keys, plus a per-leg
// `overlapSuppressedByCategory` map (plan A.3) so the account->phone collision
// (Sec 1.5#2) is machine-readable by the P/R harness.
//
// MATCHED-TEXT LOGGING (D31): this fixture is fully synthetic with a public
// values manifest, so matched text is logged here (same exemption as the
// sample statement). Production logging rules (ARCH 12.2) are untouched.

@Suite("Hartwell loan-packet Stage-1 snapshot (S05/A)", .serialized)
struct PacketSnapshotTests {

    // MARK: - Fixture identity (dual of the S01 guard)

    /// A silent fixture substitution must be loud. The packet is byte-
    /// deterministic (a committed fixture must match a fresh generator run),
    /// so the SHA pin is a hard contract, not an approximation.
    @Test("Packet fixture identity -- SHA-256 + page count pins")
    func fixtureIdentity() throws {
        let pdf = try TestFixtures.loanPacketPDF()
        let pdfHex = SHA256.hash(data: pdf).map { String(format: "%02x", $0) }.joined()
        #expect(pdfHex == TestFixtures.loanPacketSHA256,
                "packet.pdf SHA drift -- the engine fixture no longer matches the deterministic generator output")
        let doc = try #require(PDFDocument(data: pdf))
        #expect(doc.pageCount == TestFixtures.loanPacketPageCount)

        let scan = try TestFixtures.loanPacketScanSimPDF()
        let scanHex = SHA256.hash(data: scan).map { String(format: "%02x", $0) }.joined()
        #expect(scanHex == TestFixtures.loanPacketScanSimSHA256, "scan-sim SHA drift")

        let gt = try TestFixtures.loanPacketGroundTruthJSON()
        let gtHex = SHA256.hash(data: gt).map { String(format: "%02x", $0) }.joined()
        #expect(gtHex == TestFixtures.loanPacketGroundTruthSHA256, "ground-truth SHA drift")
    }

    // MARK: - Dual-leg Stage-1 snapshot (measurement; no Stage-2 freeze)

    @Test("Dual-leg Stage-1 detection snapshot -- 12 pages x {text, OCR}")
    func dualLegSnapshot() async throws {
        let data = try TestFixtures.loanPacketPDF()
        let document = try #require(PDFDocument(data: data))
        #expect(document.pageCount == TestFixtures.loanPacketPageCount)

        let orchestrator = DetectionOrchestrator(recognitionLevel: .fast)
        let rasterizer = PageRasterizer()
        let balanced = PresetThresholdBundle.loadFromEngineBundle().presets[.balanced]

        // Warm the Vision inference context on a SMALL synthetic image before
        // the measurement loop. The first Vision request in a fresh process can
        // return #9 "could not create inference context"; batched runs absorb
        // this in a sibling suite, but an isolated run must warm Vision itself
        // (Vision200ColdStartProbeTests). Immediate retries alone did not warm
        // it -- a synthetic-image warm-up with backoff does.
        await warmUpVision(orchestrator, rasterizer)

        var pageSnaps: [PacketPageSnap] = []
        for pageIndex in 0..<document.pageCount {
            let page = try #require(document.page(at: pageIndex))

            // -- Text-extraction leg (production path for born-digital pages). --
            // detectPage still needs an image (barcode/signature pass; face is
            // skipped on .financial). Text / doctype / text-PII come from the
            // embedded layer, so OCR is bypassed (provenance.ocrSkipped == true).
            // A page that yields NO embedded source is recorded as an empty text
            // leg (a measured gap, not an abort) -- this is a measurement, not a guard.
            var textSnap: PacketLegSnap
            if let embedded = EmbeddedTextSource.make(from: page) {
                let textLegImage = try await rasterizer.renderPage(
                    page, pageIndex: pageIndex, dpi: 150)
                // Retry the text leg too: detectPage still runs the Vision
                // barcode pass on the image, so it is not OCR-immune. A leg that
                // still throws is RECORDED (errored), not aborted -- measurement.
                do {
                    let textResult = try await detectWithRetry(
                        orchestrator, image: textLegImage, pageIndex: pageIndex,
                        embeddedText: embedded)
                    // Per-leg OCR-invocation contract asserted DETERMINISTICALLY
                    // via per-detection provenance, NOT the process-global counter
                    // (sibling suites mutate it in a batched run -- S01 b6 lesson).
                    #expect(textResult.detections.allSatisfy { $0.provenance.ocrSkipped },
                            "every text-leg detection must carry provenance.ocrSkipped (OCR bypassed)")
                    textSnap = Self.legSnap(
                        "text", result: textResult, ocrSkipped: true,
                        renderDPI: nil, coverage: embedded.coverage, balanced: balanced)
                } catch {  // LegalPhrases:safe (Swift keyword)
                    let ns = error as NSError
                    print("[OCRQ-pkt] p\(pageIndex) leg=text DETECT FAILED \(ns.domain)#\(ns.code)")
                    textSnap = PacketLegSnap.errored("text", ocrSkipped: true, coverage: embedded.coverage)
                }
            } else {
                textSnap = PacketLegSnap.empty("text", ocrSkipped: true)
            }

            // -- OCR leg (scan-sim path) rendered at the policy DPI for the
            //    doctype the text leg classified (financial -> 200, else 150). --
            let dpiDoctype = DoctypeClass(rawValue: textSnap.doctype.primary) ?? .generic
            let ocrDPI = DetectionRenderPolicy.detectionDPI(for: dpiDoctype)
            var ocrSnap: PacketLegSnap
            do {
                let ocrImage = try await rasterizer.renderPage(
                    page, pageIndex: pageIndex, dpi: ocrDPI)
                let ocrResult = try await detectWithRetry(
                    orchestrator, image: ocrImage, pageIndex: pageIndex,
                    embeddedText: nil)
                #expect(ocrResult.detections.allSatisfy { !$0.provenance.ocrSkipped },
                        "every OCR-leg detection must carry provenance.ocrRan")
                ocrSnap = Self.legSnap(
                    "ocr", result: ocrResult, ocrSkipped: false,
                    renderDPI: Int(ocrDPI), coverage: nil, balanced: balanced)
            } catch {  // LegalPhrases:safe (Swift keyword)
                let ns = error as NSError
                print("[OCRQ-pkt] p\(pageIndex) leg=ocr DETECT FAILED \(ns.domain)#\(ns.code)")
                ocrSnap = PacketLegSnap.errored("ocr", ocrSkipped: false, coverage: nil)
            }

            pageSnaps.append(PacketPageSnap(
                pageIndex: pageIndex, textLeg: textSnap, ocrLeg: ocrSnap))
            // Space successive pages so Vision can release/recreate inference
            // contexts under the simulator's memory pressure (isolated runs).
            try? await Task.sleep(for: .milliseconds(200))
        }

        let snapshot = PacketSnapshotDoc(
            schemaVersion: 1,
            fixture: PacketSnapshotDoc.Fixture(
                name: "packet.pdf",
                sha256: TestFixtures.loanPacketSHA256,
                pageCount: TestFixtures.loanPacketPageCount),
            generatedBy: "PacketSnapshotTests (S05/A, resecta-sample-packet-2026-06-12)",
            note: "Dual-leg Stage-1 snapshot of the synthetic Hartwell loan packet. "
                + "thresholdVector=nil -> every detection surfaces; `aboveBalanced` applies the "
                + "calibrated balanced preset (preset-thresholds.json) in post. `confidence` is the "
                + "post-posterior score (empty priors). Forward-compatible SUPERSET of the S01 schema: "
                + "adds per-leg `overlapSuppressedByCategory`. Ground truth bbox is CORNER form "
                + "[x0,y0,x1,y1]; `normalizedRect` here is origin+size [x,y,w,h] (same coordinate "
                + "system, different encoding -- the P/R harness converts). MEASUREMENT ONLY -- no "
                + "Stage-2 freeze (that is the must-fire smoke suite). Text leg is deterministic; OCR "
                + "numbers may vary by +-epsilon across Vision / simulator-runtime versions.",
            balancedPreset: Self.balancedDump(balanced),
            pages: pageSnaps)

        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let json = String(decoding: try enc.encode(snapshot), as: UTF8.self)
        print("===PACKET-STAGE1-JSON-BEGIN===")
        print(json)
        print("===PACKET-STAGE1-JSON-END===")

        Self.printSummary(pageSnaps)
    }

    /// detectPage with cold-start retries (S8 / S01 lesson: a transient Vision
    /// "could not create inference context" #9 on the first Vision request in a
    /// fresh process; an immediate retry warms it). Used for BOTH legs -- the
    /// text leg still runs the Vision barcode pass, so it is not immune. The
    /// final attempt rethrows. `embeddedText` nil => OCR leg; non-nil => text leg.
    private func detectWithRetry(
        _ orchestrator: DetectionOrchestrator, image: CGImage, pageIndex: Int,
        embeddedText: EmbeddedTextSource?
    ) async throws -> PageDetectionResult {
        let maxAttempts = 4
        var lastError: Error?
        for attempt in 1...maxAttempts {
            do {
                return try await orchestrator.detectPage(
                    image: image, pageIndex: pageIndex,
                    priors: PerCategoryPriors(), surfaceForms: SurfaceFormDictionary(),
                    doctypeContext: nil, thresholdVector: nil,
                    embeddedText: embeddedText, ocrSkipReason: nil)
            } catch {  // LegalPhrases:safe (Swift keyword)
                lastError = error
                if attempt == maxAttempts { throw error }
                try? await Task.sleep(for: .milliseconds(400))   // let Vision settle
            }
        }
        throw lastError ?? CancellationError()   // unreachable; satisfies the type checker
    }

    /// Create the Vision inference context before the measurement loop, on a
    /// small synthetic image, so the first REAL packet page is not the cold-
    /// start victim. Best-effort: if it never warms, the per-page retries still
    /// surface #9 honestly (rather than this hiding a real failure).
    private func warmUpVision(
        _ orchestrator: DetectionOrchestrator, _ rasterizer: PageRasterizer
    ) async {
        guard let doc = PDFDocument(data: TwentyPageFixtureBuilder.buildDocument()),
              let page = doc.page(at: 0)
        else { return }
        // Warm BOTH render DPIs we use (text leg 150; OCR financial 200) -- the
        // #9 context appears to be per-render-config, so a 200-only warm-up did
        // not cover the 150-DPI barcode pass the first real page runs.
        for dpi in [CGFloat(150), CGFloat(200)] {
            guard let image = try? await rasterizer.renderPage(page, pageIndex: 0, dpi: dpi)
            else { continue }
            var warmed = false
            for attempt in 1...8 {
                do {
                    _ = try await orchestrator.detectPage(
                        image: image, pageIndex: 0,
                        priors: PerCategoryPriors(), surfaceForms: SurfaceFormDictionary(),
                        doctypeContext: nil, thresholdVector: nil,
                        embeddedText: nil, ocrSkipReason: nil)
                    print("[OCRQ-pkt] Vision warm-up ok dpi=\(Int(dpi)) attempt=\(attempt)")
                    warmed = true
                    break
                } catch {  // LegalPhrases:safe (Swift keyword)
                    try? await Task.sleep(for: .milliseconds(600))
                }
            }
            if !warmed {
                print("[OCRQ-pkt] Vision warm-up FAILED dpi=\(Int(dpi)) after 8 attempts")
            }
        }
    }

    // MARK: - Snapshot model (forward-compatible superset of the S01 schema)

    struct PacketSnapshotDoc: Codable {
        let schemaVersion: Int
        let fixture: Fixture
        let generatedBy: String
        let note: String
        let balancedPreset: [String: Double]
        let pages: [PacketPageSnap]
        struct Fixture: Codable { let name: String; let sha256: String; let pageCount: Int }
    }
    struct PacketPageSnap: Codable {
        let pageIndex: Int
        let textLeg: PacketLegSnap
        let ocrLeg: PacketLegSnap
    }
    struct PacketLegSnap: Codable {
        let leg: String                              // "text" | "ocr"
        let ocrSkipped: Bool                         // leg contract
        let renderDPI: Int?                          // OCR leg only
        let coverage: Double?                        // text leg only -- selectable-text coverage [0,1]
        let doctype: PacketDoctypeSnap
        let detectionCount: Int
        let overlapSuppressedByCategory: [String: Int]   // NEW (plan A.3): account->phone diagnostic
        let detections: [PacketDetSnap]

        static func empty(_ leg: String, ocrSkipped: Bool) -> PacketLegSnap {
            PacketLegSnap(
                leg: leg, ocrSkipped: ocrSkipped, renderDPI: nil, coverage: nil,
                doctype: PacketDoctypeSnap(primary: "none", runnerUp: nil, softmax: [:], topKeywords: []),
                detectionCount: 0, overlapSuppressedByCategory: [:], detections: [])
        }

        /// A leg whose detect threw (e.g. a Vision #9 on a dense page in an
        /// isolated run). Recorded -- not aborted -- so the measurement still
        /// yields the legs that DID succeed, with a clear marker for the ones
        /// that did not. `doctype.primary == "detect-error"`.
        static func errored(_ leg: String, ocrSkipped: Bool, coverage: Double?) -> PacketLegSnap {
            PacketLegSnap(
                leg: leg, ocrSkipped: ocrSkipped, renderDPI: nil, coverage: coverage,
                doctype: PacketDoctypeSnap(primary: "detect-error", runnerUp: nil, softmax: [:], topKeywords: []),
                detectionCount: 0, overlapSuppressedByCategory: [:], detections: [])
        }
    }
    struct PacketDoctypeSnap: Codable {
        let primary: String
        let runnerUp: String?
        let softmax: [String: Double]
        let topKeywords: [String]            // "keyword->class:weight"
    }
    struct PacketDetSnap: Codable {
        let category: String                 // wire name (preset key); face/barcode/signatureCandidate otherwise
        let confidence: Double               // post-posterior (ungated)
        let balancedThreshold: Double?
        let aboveBalanced: Bool?             // confidence >= balancedThreshold
        let normalizedRect: [Double]         // [x, y, w, h], 0-1 bottom-left origin, rounded
        let matchedText: String?             // D31 logging exemption (synthetic, manifested fixture)
    }

    // MARK: - Builders

    static func legSnap(
        _ leg: String, result: PageDetectionResult, ocrSkipped: Bool,
        renderDPI: Int?, coverage: Double?, balanced: PresetThresholdVector?
    ) -> PacketLegSnap {
        let dets: [PacketDetSnap] = result.detections.map { d in
            let conf = r4(d.confidence)
            let thr = balancedThreshold(for: d.kind, balanced)
            return PacketDetSnap(
                category: wireName(for: d.kind),
                confidence: conf,
                balancedThreshold: thr.map(r4),
                aboveBalanced: thr.map { conf >= $0 },
                normalizedRect: [
                    r4(Double(d.normalizedRect.minX)), r4(Double(d.normalizedRect.minY)),
                    r4(Double(d.normalizedRect.width)), r4(Double(d.normalizedRect.height))],
                matchedText: d.matchedText)
        }.sorted(by: detOrder)
        var overlap: [String: Int] = [:]
        for (cat, n) in result.overlapSuppressedCountByCategory {
            overlap[PresetThresholdVector.wireName(for: cat) ?? String(describing: cat)] = n
        }
        return PacketLegSnap(
            leg: leg, ocrSkipped: ocrSkipped, renderDPI: renderDPI,
            coverage: coverage.map(r4), doctype: doctypeSnap(result.doctype),
            detectionCount: dets.count, overlapSuppressedByCategory: overlap, detections: dets)
    }

    /// Deterministic order so the committed JSON does not churn: top-of-page
    /// first (y descending, bottom-left origin), then left-to-right, category, text.
    static func detOrder(_ a: PacketDetSnap, _ b: PacketDetSnap) -> Bool {
        if a.normalizedRect[1] != b.normalizedRect[1] { return a.normalizedRect[1] > b.normalizedRect[1] }
        if a.normalizedRect[0] != b.normalizedRect[0] { return a.normalizedRect[0] < b.normalizedRect[0] }
        if a.category != b.category { return a.category < b.category }
        return (a.matchedText ?? "") < (b.matchedText ?? "")
    }

    static func doctypeSnap(_ r: DoctypeResult) -> PacketDoctypeSnap {
        PacketDoctypeSnap(
            primary: r.primary.rawValue,
            runnerUp: r.runnerUp?.rawValue,
            softmax: Dictionary(uniqueKeysWithValues: r.softmax.map { ($0.key.rawValue, r4($0.value)) }),
            topKeywords: r.topKeywords.map {
                "\($0.keyword)->\($0.classContributedTo.rawValue):\(r4($0.weight))" })
    }

    static func balancedDump(_ v: PresetThresholdVector?) -> [String: Double] {
        guard let v else { return [:] }
        var out: [String: Double] = [:]
        for cat in PIICategory.allCases {
            if let wire = PresetThresholdVector.wireName(for: cat), let t = v.threshold(for: cat) {
                out[wire] = r4(t)
            }
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

    // MARK: - Console summary (raw material for the S05 questions)

    static func printSummary(_ pages: [PacketPageSnap]) {
        let names = ["URLA-B", "URLA-B", "URLA-A", "STMT", "STMT", "STMT",
                     "T1040", "T1040", "ACH", "W-2", "GOV-ID", "VEH"]
        print("[OCRQ-pkt] ----- Hartwell loan-packet Stage-1 snapshot -----")
        for p in pages {
            let label = p.pageIndex < names.count ? names[p.pageIndex] : "?"
            for leg in [p.textLeg, p.ocrLeg] {
                let dpi = leg.renderDPI.map { " dpi=\($0)" } ?? ""
                let cov = leg.coverage.map { " coverage=\($0)" } ?? ""
                let ovl = leg.overlapSuppressedByCategory.isEmpty ? ""
                    : " overlapSuppressed=\(leg.overlapSuppressedByCategory.sorted { $0.key < $1.key })"
                print("[OCRQ-pkt] p\(p.pageIndex)(\(label)) leg=\(leg.leg) doctype=\(leg.doctype.primary)"
                    + " runnerUp=\(leg.doctype.runnerUp ?? "-")\(dpi)\(cov) detections=\(leg.detectionCount)\(ovl)")
                var total: [String: Int] = [:], above: [String: Int] = [:]
                for d in leg.detections {
                    total[d.category, default: 0] += 1
                    if d.aboveBalanced == true { above[d.category, default: 0] += 1 }
                }
                for cat in total.keys.sorted() {
                    print("[OCRQ-pkt]     \(cat): \(above[cat] ?? 0)/\(total[cat] ?? 0) >=balanced")
                }
            }
        }
        // S05-Q1 VEH .generic: page 11 doctype on both legs.
        if pages.count > 11 {
            let veh = pages[11]
            print("[OCRQ-pkt] Q-VEH p11 text doctype=\(veh.textLeg.doctype.primary)"
                + " (softmax=\(veh.textLeg.doctype.softmax.sorted { $0.key < $1.key }));"
                + " ocr doctype=\(veh.ocrLeg.doctype.primary)")
            let lp = veh.textLeg.detections.filter { $0.category == "licensePlate" }
                + veh.ocrLeg.detections.filter { $0.category == "licensePlate" }
            print("[OCRQ-pkt] Q-VEH p11 licensePlate detections=\(lp.count) "
                + "matched=\(lp.compactMap { $0.matchedText })")
        }
        // S05-Q2 account vs phone: every page's account/phone counts + overlap.
        print("[OCRQ-pkt] Q-acct/phone (per page, both legs):")
        for p in pages {
            for leg in [p.textLeg, p.ocrLeg] {
                let acct = leg.detections.filter { $0.category == "account" }.count
                let phone = leg.detections.filter { $0.category == "phone" }.count
                let supp = leg.overlapSuppressedByCategory
                if acct > 0 || phone > 0 || supp["account"] != nil || supp["phone"] != nil {
                    print("[OCRQ-pkt]   p\(p.pageIndex) \(leg.leg): account=\(acct) phone=\(phone)"
                        + " suppressed(acct=\(supp["account"] ?? 0),phone=\(supp["phone"] ?? 0))")
                }
            }
        }
        // S05-Q3 per-leg text coverage (does each born-digital form page clear >0.95?).
        print("[OCRQ-pkt] Q-coverage (text leg, >0.95 => text fast path):")
        for p in pages {
            let label = p.pageIndex < names.count ? names[p.pageIndex] : "?"
            let c = p.textLeg.coverage
            let mark = (c ?? 0) >= 0.95 ? "TEXT" : "OCR-path"
            print("[OCRQ-pkt]   p\(p.pageIndex)(\(label)) coverage=\(c.map { String($0) } ?? "nil") -> \(mark)")
        }
    }
}
