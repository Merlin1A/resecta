import Foundation
import CoreGraphics
import PDFKit
import Testing
@testable import RedactionEngine

// S05 / Steps C + D -- Resecta sample/test-document packet series.
//
// The BLOCKING regression freeze (D32) + the VEH `.generic` gating verification
// (D24) for the synthetic Hartwell loan packet. Sibling of the measurement
// suites: `PacketSnapshotTests` (S05/A -- the live dual-leg snapshot) and
// `PacketPRHarnessTests` (S05/B -- the deterministic D22 Option-C report over
// the committed snapshot). This suite is the LIVE guard: it re-runs the engine
// and asserts the reconciled tiers, so a future engine change that drops a
// must-fire (or starts firing a must-not-fire) breaks CI.
//
// MEASUREMENT LEG. The freeze runs on the TEXT leg -- the deterministic path:
// `detectPage(embeddedText:)` does NOT invoke Vision OCR, `.financial` pages
// skip the face pass, and the barcode pass tolerates the simulator Vision #9
// locally (DetectionOrchestrator step 6b). The OCR leg is Vision-dependent
// (+-epsilon across runtimes) and is measured/reported by the snapshot + P/R
// harness, not frozen here. (S01 design consequence #4: this packet's pages
// take the OCR path in production -- coverage < 0.95 -- but the text leg
// exercises the same detectors/gates deterministically, which is what a
// regression guard needs.)
//
// FACE-FREE SEAM (pages 10 GOV-ID + 11 VEH only). Those two pages are
// NON-financial, so `detectPage` runs the Vision face detector
// (`shouldRunFaceDetection` is true for court/medical/foia/generic) which
// deterministically throws `com.apple.Vision #9 "could not create inference
// context"` on the simulator -- the S8-documented sim-fragility. (Note: the
// barcode pass, step 6b, tolerates the IDENTICAL Vision #9; the face pass at
// :462 rethrows -- an engine-robustness asymmetry flagged for maintainer review, NOT fixed
// here per INV-1.) For those two pages this suite measures the PII path
// face-free by calling the SAME building blocks `detectPage` calls
// (`DocumentTypeClassifier().classify` at orchestrator :314 and
// `PIIDetector().detect(...,documentHeader:nil)` at :339 -- nil is exactly
// what the orchestrator passes for any page index > 0) and reconstructing the
// region rect via the same `boundingRect` union of word bounds. The raw-detect
// path omits cross-category overlap resolution; that is faithful for the
// label-agnostic region hard-gate (overlap only relabels/drops -- the region
// stays covered by the surviving box) and for the p10/p11 negatives (no
// account/phone overlap collisions live there). The account/phone collisions
// all sit on financial pages, which use the full `detectPage` pipeline.
//
// MATCHED-TEXT LOGGING (D31): synthetic, publicly-manifested fixture -- logged.

@Suite("Hartwell packet -- VEH .generic gating + must-fire/not-fire freeze (S05/C+D)", .serialized)
struct PacketRegressionTests {

    // MARK: - Ground-truth model (subset of the D21 schema the freeze needs)

    struct GroundTruth: Codable {
        let occurrences: [Occ]
        let carried_stmt: [Occ]
    }
    struct Occ: Codable {
        let id: String
        let value: String
        let category: String
        let page: Int?
        let bbox: [Double]?
        let expectation: String           // must_fire | must_not_fire | should_fire | watch
        let leg_applicability: [String]
        let spans: [Span]?
        struct Span: Codable { let bbox: [Double]? }
    }

    static func loadGroundTruth() throws -> GroundTruth {
        let data = try TestFixtures.loanPacketGroundTruthJSON()
        return try JSONDecoder().decode(GroundTruth.self, from: data)
    }

    /// GT categories are `PIIKind` names; the engine surfaces preset wire names.
    /// The only divergence is dateOfBirth -> dob (verified against the committed
    /// preset). Everything else is identical.
    static func normalize(_ category: String) -> String {
        category == "dateOfBirth" ? "dob" : category
    }

    // MARK: - Geometry (the join the P/R harness also uses)

    /// GT bbox is CORNER form [x0,y0,x1,y1]; build origin+size CGRect.
    static func gtRect(_ b: [Double]) -> CGRect {
        CGRect(x: b[0], y: b[1], width: b[2] - b[0], height: b[3] - b[1])
    }

    /// Coverage = fraction of the GT VALUE area that sits under a detection box.
    /// This is the D22 "redaction recall -- did any box COVER the PII (the
    /// privacy outcome)" measure, and it is the right gate for a privacy
    /// regression freeze: the label-anchored detectors (driversLicense,
    /// licensePlate) match "<label>: <value>", so their box OVER-covers the
    /// value -- a tight IoU vs the value-only GT bbox would score that a miss
    /// even though the value is fully redacted. Coverage >= IoU always, so this
    /// never credits a true non-detection (those score 0). The IoU>=0.5
    /// headline match-quality number lives in PacketPRHarnessTests.
    static func coverFrac(_ gt: CGRect, _ det: CGRect) -> Double {
        let inter = gt.intersection(det)
        if inter.isNull || inter.width <= 0 || inter.height <= 0 { return 0 }
        let g = gt.width * gt.height
        return g > 0 ? (inter.width * inter.height) / g : 0
    }

    struct Det { let category: String; let rect: CGRect; let text: String }

    /// D22 region hard-gate (coverage form): is the occurrence value covered by
    /// some detection box (coverage >= threshold), with DetEval-style merge
    /// credit for a multi-line occurrence (each `spans[]` line individually
    /// covered). Returns the covering detection's category (for the ratchet).
    static func regionHit(_ occ: Occ, _ dets: [Det], threshold: Double = 0.5)
        -> (hit: Bool, category: String?) {
        guard let bbox = occ.bbox else { return (false, nil) }
        let whole = gtRect(bbox)
        var best = 0.0, bestCat: String? = nil
        for d in dets {
            let v = coverFrac(whole, d.rect)
            if v > best { best = v; bestCat = d.category }
        }
        if best >= threshold { return (true, bestCat) }
        // merge credit: every line of a multi-line occurrence covered.
        let spans = occ.spans ?? []
        if spans.count > 1 {
            var firstCat: String? = nil, allCovered = true
            for s in spans {
                guard let sb = s.bbox else { allCovered = false; break }
                let sr = gtRect(sb)
                var sBest = 0.0, sCat: String? = nil
                for d in dets {
                    let v = coverFrac(sr, d.rect)
                    if v > sBest { sBest = v; sCat = d.category }
                }
                if sBest >= threshold { firstCat = firstCat ?? sCat } else { allCovered = false; break }
            }
            if allCovered { return (true, firstCat) }
        }
        return (false, nil)
    }

    // MARK: - Measurement helpers

    static func wire(for kind: DetectionResult.Kind) -> String {
        switch kind {
        case .pii(let k):
            if let cat = PIICategory(piiKind: k) {
                return PresetThresholdVector.wireName(for: cat) ?? String(describing: k)
            }
            return String(describing: k)
        case .face: return "face"
        case .searchMatch: return "searchMatch"
        }
    }

    /// boundingRect replica (DetectionOrchestrator :799) -- union of the word
    /// bounds whose range intersects the match range.
    static func boundingRect(for range: NSRange, in wordBounds: [(NSRange, CGRect)]) -> CGRect? {
        var result: CGRect? = nil
        for (wr, rect) in wordBounds where NSIntersectionRange(wr, range).length > 0 {
            result = result?.union(rect) ?? rect
        }
        return result
    }

    struct PageMeasurement { let doctype: String; let dets: [Det] }

    /// Measure the requested pages on the TEXT leg, parsing the packet ONCE into
    /// a LOCAL `PDFDocument` so the (non-Sendable) `PDFPage` can be sent to the
    /// `@concurrent` rasterizer without a Swift-6 region race (the document must
    /// be local to the function that renders, per `PacketSnapshotTests`).
    ///
    /// - Financial pages (0-9): the full pipeline via `detectPage` (face skipped,
    ///   OCR bypassed, barcode tolerant -> deterministic; cross-category overlap
    ///   resolution included, so the account/phone collisions resolve faithfully).
    /// - Non-financial pages (10 GOV-ID, 11 VEH): the face-free seam (classify +
    ///   `PIIDetector().detect(...,documentHeader:nil)` + boundingRect), because
    ///   `detectPage` would throw the sim face Vision #9 there. Raw detect omits
    ///   overlap resolution -- faithful for the region hard-gate and these pages'
    ///   negatives (no account/phone overlap collisions live on 10/11).
    func measureAll(pages: [Int]) async throws -> [Int: PageMeasurement] {
        let document = try #require(PDFDocument(data: try TestFixtures.loanPacketPDF()))
        let rasterizer = PageRasterizer()
        let orchestrator = DetectionOrchestrator(recognitionLevel: .fast)
        var out: [Int: PageMeasurement] = [:]
        for pageIndex in pages.sorted() {
            let page = try #require(document.page(at: pageIndex))
            let embedded = try #require(EmbeddedTextSource.make(from: page))
            if pageIndex >= 10 {
                let doctype = await DocumentTypeClassifier().classify(pageText: embedded.text)
                let matches = await PIIDetector().detect(
                    in: embedded.text, doctype: doctype.primary, documentHeader: nil)
                let wordBounds = embedded.wordBounds.map { ($0.range, $0.normalizedRect) }
                var dets: [Det] = []
                for m in matches {
                    guard let rect = Self.boundingRect(for: m.range, in: wordBounds) else { continue }
                    let cat = m.category.flatMap { PresetThresholdVector.wireName(for: $0) }
                        ?? String(describing: m.kind)
                    dets.append(Det(category: cat, rect: rect, text: m.text))
                }
                out[pageIndex] = PageMeasurement(doctype: doctype.primary.rawValue, dets: dets)
            } else {
                let image = try await rasterizer.renderPage(page, pageIndex: pageIndex, dpi: 150)
                let result = try await orchestrator.detectPage(
                    image: image, pageIndex: pageIndex,
                    priors: PerCategoryPriors(), surfaceForms: SurfaceFormDictionary(),
                    doctypeContext: nil, thresholdVector: nil,
                    embeddedText: embedded, ocrSkipReason: nil)
                let dets = result.detections.map {
                    Det(category: Self.wire(for: $0.kind), rect: $0.normalizedRect, text: $0.matchedText ?? "")
                }
                out[pageIndex] = PageMeasurement(doctype: result.doctype.primary.rawValue, dets: dets)
            }
        }
        return out
    }

    // MARK: - Lens D: VEH `.generic` classification + licensePlate gate (D24)

    @Test("VEH page 11 classifies .generic (D24 STOP if .financial)")
    func vehClassifiesGeneric() async throws {
        let document = try #require(PDFDocument(data: try TestFixtures.loanPacketPDF()))
        let page = try #require(document.page(at: 11))
        let text = try #require(EmbeddedTextSource.make(from: page)).text
        let result = await DocumentTypeClassifier().classify(pageText: text)
        print("[OCRQ-pkt] D24 p11(VEH) doctype=\(result.primary.rawValue) "
            + "softmax=\(result.softmax.map { ($0.key.rawValue, ($0.value * 1000).rounded() / 1000) }.sorted { $0.0 < $1.0 })")
        #expect(result.primary == .generic,
                "D24 STOP: VEH page must classify .generic for licensePlate to fire; got \(result.primary.rawValue). Fallback (engine-improvement track, do NOT self-decide): un-gate licensePlate for .financial.")
    }

    @Test("VEH licensePlate gate: 7XYZ842 fires under .generic; VIN/Tag/cross-page negatives do not; .financial suppresses")
    func licensePlateGate() async throws {
        let document = try #require(PDFDocument(data: try TestFixtures.loanPacketPDF()))
        let page = try #require(document.page(at: 11))
        let text = try #require(EmbeddedTextSource.make(from: page)).text

        let generic = await PIIDetector().detect(in: text, doctype: .generic, documentHeader: nil)
        let plates = generic.filter { $0.kind == .licensePlate }.map { $0.text }
        print("[OCRQ-pkt] D24 p11 licensePlate(.generic) matched=\(plates)")
        // occ_veh_01 must fire as licensePlate (the D24 must-fire).
        #expect(plates.contains { $0.contains("7XYZ842") }, "occ_veh_01 (7XYZ842) must fire as licensePlate on the .generic VEH page")
        // occ_veh_04 (VIN) must NOT fire as licensePlate (too long / not plate-shaped).
        #expect(!plates.contains { $0.contains("4S4BSANC1K3304412") }, "occ_veh_04 VIN must not fire as licensePlate")
        // NOTE (S05 reconciliation): occ_veh_05 "Tag No: 88KJ2" DOES fire as
        // licensePlate -- "Tag No" is a plate-label synonym, so this is
        // defensible engine behavior. The manifest mis-tiered it as a negative;
        // S05 re-tiers occ_veh_05 must_not_fire -> watch (flagged for maintainer review).

        // Gate proof: under .financial the same page yields NO licensePlate.
        let financial = await PIIDetector().detect(in: text, doctype: .financial, documentHeader: nil)
        #expect(!financial.contains { $0.kind == .licensePlate },
                "licensePlate is doctype-gated OFF on .financial -- the gate that makes the VEH .generic page necessary")
    }

    // MARK: - Lens C: must-fire region freeze + must-not-fire precision freeze (D32)

    @Test("FREEZE: every must_fire is region-covered on the text leg (D32 region hard-gate)")
    func mustFireRegionFreeze() async throws {
        let gt = try Self.loadGroundTruth()
        let want = gt.occurrences.filter { $0.expectation == "must_fire" }
        let pages = Array(Set(want.compactMap { $0.page }))
        let measured = try await measureAll(pages: pages)
        var misses: [String] = []
        for occ in want {
            guard let page = occ.page, let m = measured[page] else { continue }
            let (hit, _) = Self.regionHit(occ, m.dets)
            if !hit { misses.append("\(occ.id) p\(page) \(occ.category) value=\(occ.value)") }
        }
        if !misses.isEmpty {
            print("[OCRQ-pkt] must_fire REGION MISSES (demote these to should_fire in occurrences.py):")
            misses.forEach { print("[OCRQ-pkt]   \($0)") }
        }
        #expect(misses.isEmpty, "must_fire region misses (reconcile tiers before freezing): \(misses)")
    }

    @Test("FREEZE: no must_not_fire fires as its own category on the text leg (D32 precision gate)")
    func mustNotFirePrecisionFreeze() async throws {
        let gt = try Self.loadGroundTruth()
        let want = gt.occurrences.filter { $0.expectation == "must_not_fire" }
        let pages = Array(Set(want.compactMap { $0.page }))
        let measured = try await measureAll(pages: pages)
        var violations: [String] = []
        for occ in want {
            guard let page = occ.page, let m = measured[page] else { continue }
            let wantCat = Self.normalize(occ.category)
            // Per-category precision: a same-category box covering the region is a FP.
            let sameCat = m.dets.filter { $0.category == wantCat }
            let (hit, _) = Self.regionHit(occ, sameCat)
            if hit { violations.append("\(occ.id) p\(page) fires-as-\(wantCat) value=\(occ.value)") }
        }
        if !violations.isEmpty {
            print("[OCRQ-pkt] must_not_fire PRECISION VIOLATIONS (re-tier to watch in occurrences.py):")
            violations.forEach { print("[OCRQ-pkt]   \($0)") }
        }
        #expect(violations.isEmpty, "must_not_fire precision violations: \(violations)")
    }

    // MARK: - Measurement dump for the 2 face-blocked pages (informs reconciliation)

    @Test("DUMP: face-free measurement of pages 10 (GOV-ID) + 11 (VEH)")
    func dumpFaceBlockedPages() async throws {
        let gt = try Self.loadGroundTruth()
        let measured = try await measureAll(pages: [10, 11])
        for page in [10, 11] {
            guard let m = measured[page] else { continue }
            print("[OCRQ-pkt] ----- p\(page) face-free doctype=\(m.doctype) detections=\(m.dets.count) -----")
            for occ in gt.occurrences where occ.page == page {
                let (hit, cat) = Self.regionHit(occ, m.dets)
                let want = Self.normalize(occ.category)
                let verdict = !hit ? "MISS" : (cat == want ? "ok" : "region-as-\(cat ?? "?")")
                print("[OCRQ-pkt]   \(occ.expectation) \(occ.id) \(occ.category) -> \(verdict)  value=\(occ.value)")
            }
        }
    }
}
