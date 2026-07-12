import Foundation
import CoreGraphics
import Testing
@testable import RedactionEngine

// S05 / Step B -- Resecta sample/test-document packet series.
//
// The manifest-driven precision/recall harness implementing D22 Option C (the
// ratified two-gate model). It UPGRADES the counts-only S8 `RealDocOCRQuality`
// harness from counts to a labeled per-occurrence P/R/F-beta join.
//
// DETERMINISTIC + REPORT-ONLY. It joins two committed artifacts -- the D21
// ground truth (`packet-ground-truth.json`) and the dual-leg Stage-1 snapshot
// (`snapshots/packet-stage1.json`, produced by `PacketSnapshotTests`) -- with
// NO engine run, so it never flakes on the simulator Vision path. The LIVE
// regression guard is `PacketRegressionTests` (the must-fire/not-fire freeze);
// this suite is the measurement report + a few cross-consistency assertions.
//
// D22 OPTION C, as implemented here:
//  - Region match TWO ways: (1) coverage (fraction of the GT value under a
//    detection box) -- the LABEL-AGNOSTIC redaction-recall / privacy outcome;
//    (2) IoU -- the headline match-QUALITY number, reported at >= 0.5 with the
//    >= 0.7 "tight" number as a TREND-only secondary. DetEval-style merge
//    credit for multi-line `spans[]` in both.
//  - Category ratchet (Gate 2): CoNLL-strict category match among region-
//    matched (coverage) occurrences -> the strict-F1 / confusion view.
//  - Per leg (text vs OCR); F-beta with beta = 2 (favor recall, per Presidio).
//  - Tier -> metric mapping: must_fire -> recall denominator; must_not_fire ->
//    precision denominator (a same-category fire is a false positive);
//    should_fire -> off-headline known-miss line; watch -> record only.
//  - The account/phone collision (S01 Sec 1.5#2) surfaces as the snapshot's
//    `overlapSuppressedByCategory` + the account->phone confusion cell.
//  - Pages 10 (GOV-ID) + 11 (VEH) are face-blocked in the snapshot (sim Vision
//    face #9); their occurrences are reported in a separate FACE-BLOCKED bucket
//    and EXCLUDED from the headline denominators (they are frozen live, on the
//    face-free seam, by PacketRegressionTests).
//
// MATCHED-TEXT LOGGING (D31): synthetic, publicly-manifested fixture -- logged.

@Suite("Hartwell packet -- D22 Option-C P/R harness (S05/B)", .serialized)
struct PacketPRHarnessTests {

    // MARK: - Committed-artifact models

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
        let expectation: String
        let leg_applicability: [String]
        let spans: [Span]?
        let count: Int?
        struct Span: Codable { let bbox: [Double]? }
    }

    struct Snapshot: Codable { let pages: [Page] }
    struct Page: Codable { let pageIndex: Int; let textLeg: Leg; let ocrLeg: Leg }
    struct Leg: Codable {
        let leg: String
        let doctype: Doctype
        let detections: [Detection]
        let overlapSuppressedByCategory: [String: Int]
        var blocked: Bool { doctype.primary == "detect-error" }
    }
    struct Doctype: Codable { let primary: String }
    struct Detection: Codable {
        let category: String
        let normalizedRect: [Double]      // [x, y, w, h]
        let matchedText: String?
        var rect: CGRect { CGRect(x: normalizedRect[0], y: normalizedRect[1],
                                  width: normalizedRect[2], height: normalizedRect[3]) }
    }

    static func loadGroundTruth() throws -> GroundTruth {
        try JSONDecoder().decode(GroundTruth.self, from: try TestFixtures.loanPacketGroundTruthJSON())
    }
    static func loadSnapshot() throws -> Snapshot {
        let url = try #require(Bundle.module.url(
            forResource: "packet-stage1", withExtension: "json", subdirectory: "snapshots"),
            "committed snapshot snapshots/packet-stage1.json must be bundled")
        return try JSONDecoder().decode(Snapshot.self, from: try Data(contentsOf: url))
    }

    // MARK: - Geometry

    static func gtRect(_ b: [Double]) -> CGRect {
        CGRect(x: b[0], y: b[1], width: b[2] - b[0], height: b[3] - b[1])
    }
    static func iou(_ a: CGRect, _ b: CGRect) -> Double {
        let i = a.intersection(b)
        if i.isNull || i.width <= 0 || i.height <= 0 { return 0 }
        let ia = i.width * i.height
        let ua = a.width * a.height + b.width * b.height - ia
        return ua > 0 ? ia / ua : 0
    }
    static func coverFrac(_ gt: CGRect, _ det: CGRect) -> Double {
        let i = gt.intersection(det)
        if i.isNull || i.width <= 0 || i.height <= 0 { return 0 }
        let g = gt.width * gt.height
        return g > 0 ? (i.width * i.height) / g : 0
    }
    static func normalize(_ c: String) -> String { c == "dateOfBirth" ? "dob" : c }

    /// One join verdict for an occurrence against a leg's detections.
    struct Verdict {
        let covered: Bool          // coverage >= 0.5 (privacy / region-recall)
        let iouMatched: Bool       // IoU >= 0.5 (headline match quality)
        let iouTight: Bool         // IoU >= 0.7 (trend-only)
        let coverCategory: String? // category of the best-covering box (ratchet)
    }
    static func join(_ occ: Occ, _ dets: [Detection]) -> Verdict {
        guard let bbox = occ.bbox else { return Verdict(covered: false, iouMatched: false, iouTight: false, coverCategory: nil) }
        let whole = gtRect(bbox)
        var bestCover = 0.0, bestCoverCat: String? = nil, bestIoU = 0.0
        for d in dets {
            let c = coverFrac(whole, d.rect); if c > bestCover { bestCover = c; bestCoverCat = d.category }
            let v = iou(whole, d.rect); if v > bestIoU { bestIoU = v }
        }
        // DetEval merge credit: a multi-line occurrence whose every line is
        // individually covered counts as covered / matched even if the single
        // whole-bbox IoU is diluted by the inter-line gaps.
        let spans = occ.spans ?? []
        if spans.count > 1 {
            var allCov = true, allIoU = true, mergeCat: String? = nil
            for s in spans {
                guard let sb = s.bbox else { allCov = false; allIoU = false; break }
                let sr = gtRect(sb)
                var sc = 0.0, scat: String? = nil, sv = 0.0
                for d in dets {
                    let c = coverFrac(sr, d.rect); if c > sc { sc = c; scat = d.category }
                    let v = iou(sr, d.rect); if v > sv { sv = v }
                }
                if sc >= 0.5 { mergeCat = mergeCat ?? scat } else { allCov = false }
                if sv < 0.5 { allIoU = false }
            }
            if allCov { bestCover = max(bestCover, 1.0); bestCoverCat = bestCoverCat ?? mergeCat }
            if allIoU { bestIoU = max(bestIoU, 0.5) }
        }
        return Verdict(covered: bestCover >= 0.5, iouMatched: bestIoU >= 0.5,
                       iouTight: bestIoU >= 0.7, coverCategory: bestCoverCat)
    }

    static func leg(_ page: Page, _ name: String) -> Leg { name == "text" ? page.textLeg : page.ocrLeg }

    static func fbeta(precision p: Double, recall r: Double, beta: Double) -> Double {
        let b2 = beta * beta
        let denom = b2 * p + r
        return denom > 0 ? (1 + b2) * p * r / denom : 0
    }
    static func pct(_ x: Double) -> String { String(format: "%.3f", x) }

    // MARK: - The harness

    @Test("D22 Option-C per-leg P/R/F-beta + account->phone cell + carried-STMT resolution")
    func harness() throws {
        let gt = try Self.loadGroundTruth()
        let snap = try Self.loadSnapshot()
        let pageByIndex = Dictionary(uniqueKeysWithValues: snap.pages.map { ($0.pageIndex, $0) })

        #expect(snap.pages.count == 12, "snapshot must cover all 12 packet pages")
        #expect(gt.occurrences.count == 106, "ground truth must carry all 106 drawn occurrences")

        print("[OCRQ-pkt] ===== D22 Option-C P/R harness (committed snapshot join) =====")

        // Per-leg tallies.
        var faceBlocked: [String] = []
        // For the account->phone cell and the strict confusion view.
        var confusion: [String: Int] = [:]   // "gt->det" -> n (region-matched, category mismatch)

        // Headline recall / precision per leg (region = coverage; strict = +category).
        var report: [String: String] = [:]
        for legName in ["text", "ocr"] {
            var mfTotal = 0, mfRegion = 0, mfStrict = 0           // must_fire (recall)
            var mnfTotal = 0, mnfFireRegion = 0, mnfFireStrict = 0 // must_not_fire (precision)
            var sfTotal = 0, sfRegion = 0                          // should_fire (off-headline)
            var iouHead = 0, iouTight = 0, iouDenom = 0            // headline IoU among must_fire

            for occ in gt.occurrences {
                guard let p = occ.page, let page = pageByIndex[p] else { continue }
                guard occ.leg_applicability.contains(legName) else { continue }
                let L = Self.leg(page, legName)
                if L.blocked {
                    if legName == "text" { faceBlocked.append("\(occ.expectation) \(occ.id) \(occ.category)") }
                    continue
                }
                let v = Self.join(occ, L.detections)
                let want = Self.normalize(occ.category)
                let strict = v.covered && v.coverCategory == want
                if v.covered && v.coverCategory != want, let got = v.coverCategory {
                    confusion["\(want)->\(got)", default: 0] += 1
                }
                switch occ.expectation {
                case "must_fire":
                    mfTotal += 1; if v.covered { mfRegion += 1 }; if strict { mfStrict += 1 }
                    iouDenom += 1; if v.iouMatched { iouHead += 1 }; if v.iouTight { iouTight += 1 }
                case "must_not_fire":
                    mnfTotal += 1; if v.covered { mnfFireRegion += 1 }; if strict { mnfFireStrict += 1 }
                case "should_fire":
                    sfTotal += 1; if v.covered { sfRegion += 1 }
                default: break
                }
            }

            // Region-recall (privacy): covered must_fire / measured must_fire.
            let regionRecall = mfTotal > 0 ? Double(mfRegion) / Double(mfTotal) : 0
            // Strict recall: region AND category.
            let strictRecall = mfTotal > 0 ? Double(mfStrict) / Double(mfTotal) : 0
            // Precision (strict): TP / (TP + FP); FP = must_not_fire that fired as-category.
            let strictPrecision = (mfStrict + mnfFireStrict) > 0
                ? Double(mfStrict) / Double(mfStrict + mnfFireStrict) : 1
            let regionPrecision = (mfRegion + mnfFireRegion) > 0
                ? Double(mfRegion) / Double(mfRegion + mnfFireRegion) : 1
            let f2region = Self.fbeta(precision: regionPrecision, recall: regionRecall, beta: 2)
            let f2strict = Self.fbeta(precision: strictPrecision, recall: strictRecall, beta: 2)
            let iouHeadline = iouDenom > 0 ? Double(iouHead) / Double(iouDenom) : 0
            let iouTightR = iouDenom > 0 ? Double(iouTight) / Double(iouDenom) : 0

            report[legName] = legName
            print("[OCRQ-pkt] --- leg=\(legName) (measured must_fire=\(mfTotal), must_not_fire=\(mnfTotal), should_fire=\(sfTotal)) ---")
            print("[OCRQ-pkt]   REGION (label-agnostic / privacy): recall=\(Self.pct(regionRecall)) precision=\(Self.pct(regionPrecision)) F2=\(Self.pct(f2region))")
            print("[OCRQ-pkt]   STRICT (region AND category):      recall=\(Self.pct(strictRecall)) precision=\(Self.pct(strictPrecision)) F2=\(Self.pct(f2strict))")
            print("[OCRQ-pkt]   IoU headline>=0.5=\(Self.pct(iouHeadline)) tight>=0.7=\(Self.pct(iouTightR)) (among \(iouDenom) must_fire)")
            print("[OCRQ-pkt]   must_not_fire that FIRED as-category (FP): \(mnfFireStrict)/\(mnfTotal); region-covered: \(mnfFireRegion)/\(mnfTotal)")
            print("[OCRQ-pkt]   should_fire region-covered (off-headline tracked wins): \(sfRegion)/\(sfTotal)")

            // Cross-consistency: post-reconciliation, every MEASURED must_fire
            // is region-covered on the deterministic text leg (mirrors the live
            // PacketRegressionTests freeze, against the committed snapshot).
            if legName == "text" {
                #expect(regionRecall == 1.0,
                        "text-leg must_fire region recall must be 1.0 after S05 tier reconciliation; got \(Self.pct(regionRecall))")
            }
        }

        // account -> phone confusion cell (S01 Sec 1.5#2) + overlap suppression.
        print("[OCRQ-pkt] ----- category confusion (region-matched, category mismatch) -----")
        for (k, n) in confusion.sorted(by: { $0.value > $1.value }) { print("[OCRQ-pkt]   \(k): \(n)") }
        var suppressed: [String: Int] = [:]
        for page in snap.pages {
            for L in [page.textLeg, page.ocrLeg] {
                for (cat, n) in L.overlapSuppressedByCategory { suppressed[cat, default: 0] += n }
            }
        }
        print("[OCRQ-pkt]   overlapSuppressedByCategory (summed): \(suppressed.sorted { $0.key < $1.key })")
        #expect((suppressed["account"] ?? 0) >= 1 || (confusion["account->phone"] ?? 0) >= 1,
                "the S01 account->phone collision (Sec 1.5#2) must reproduce in the packet")

        // Face-blocked bucket (pages 10/11; frozen live by PacketRegressionTests).
        print("[OCRQ-pkt] ----- FACE-BLOCKED (pages 10/11, excluded from headline; frozen by PacketRegressionTests) -----")
        for f in faceBlocked { print("[OCRQ-pkt]   \(f)") }

        // Carried STMT resolution (B.8): the 20 S01-measured classes now sit on
        // packet pages 3-5 (the embedded FROZEN statement -- the OCR-path
        // exhibit). Resolve each class's measured count on its applicable leg.
        print("[OCRQ-pkt] ----- carried STMT resolution (pages 3-5) -----")
        var stmtCatCount: [String: [String: Int]] = ["text": [:], "ocr": [:]]
        for page in snap.pages where (3...5).contains(page.pageIndex) {
            for (legName, L) in [("text", page.textLeg), ("ocr", page.ocrLeg)] where !L.blocked {
                for d in L.detections { stmtCatCount[legName]![d.category, default: 0] += 1 }
            }
        }
        print("[OCRQ-pkt]   STMT pages 3-5 measured counts: text=\(stmtCatCount["text"]!.sorted { $0.key < $1.key }) ocr=\(stmtCatCount["ocr"]!.sorted { $0.key < $1.key })")
        var resolved = 0
        for c in gt.carried_stmt {
            let want = Self.normalize(c.category)
            let leg = c.leg_applicability.contains("text") ? "text" : "ocr"
            let measured = stmtCatCount[leg]?[want] ?? 0
            if measured > 0 { resolved += 1 }
            print("[OCRQ-pkt]   \(c.expectation) \(c.id) \(c.category) declared=\(c.count ?? 0) measured(\(leg))=\(measured)")
        }
        print("[OCRQ-pkt]   carried STMT classes with a measured detection on the expected leg: \(resolved)/\(gt.carried_stmt.count)")
        // The must_fire STMT classes (email/phone/address/name/account) must be present.
        #expect((stmtCatCount["ocr"]?["account"] ?? 0) >= 1, "STMT account class must resolve on the OCR leg (the OCR-path exhibit)")
        #expect((stmtCatCount["text"]?["phone"] ?? 0) >= 1 || (stmtCatCount["ocr"]?["phone"] ?? 0) >= 1, "STMT phone class must resolve")
    }
}
