import Foundation
import CoreGraphics
import PDFKit
import Testing
@testable import RedactionEngine

// q31 / QW-14 -- rotate-trigger probe: a REPORT-ONLY measured verdict on the
// open rotated-coordinate question.
//
// The `~/resecta-sample-doc` generator builds a `rotate-trigger` packet variant:
// the same 12-page Hartwell loan packet with `/Rotate 90` on every page and the
// ground truth transformed into rotated DISPLAY space ((nx,ny) -> (ny, 1-nx)).
// variants.py labels it "a deliberate TRIGGER for the open rotated-coordinate
// P0 ... FAILS against the current engine until that fix lands" -- but until
// this probe the variant had zero consumers, so the actual status of DETECTION
// on a rotated source was unmeasured. (RECONSTRUCTION-side rotation is pinned
// separately by RotatedPageCoordinateTests; this suite measures the
// detection-vs-ground-truth side the variant was built for.)
//
// MEASUREMENT, not a gate: the recall expectation is wrapped in
// `withKnownIssue(isIntermittent: true)` -- a recall regression is RECORDED
// (suite stays green) and the measured pass is also green. VERDICT (first
// run, 2026-07-06): text-leg detection SURVIVES /Rotate 90 -- region recall
// 1.000, strict 1.000, IoU>=0.5 0.935 over 46 measured must_fire -- so the
// variants.py "FAILS until the fix lands" note is stale (upstream close
// recommended; the sample-doc edit is not this PR).
//
// Scoring reuses the D22 Option-C P/R harness verbatim
// (PacketPRHarnessTests.join: coverage >= 0.5 == region hit, DetEval span
// merge credit) against the TRANSFORMED ground truth, over the 55 drawn
// must_fire occurrences (carried_stmt entries have no bbox and are excluded,
// as in the harness's region metrics).
//
// MATCHED-TEXT LOGGING: same D31 exemption as the packet suites -- fully
// synthetic fixture with a public values manifest (TestHelpers.swift
// loan-packet note); production logging rules (ARCH 12.2) untouched.

@Suite("Rotate-trigger packet -- detection probe (q31/QW-14)", .serialized)
struct RotatedPacketDetectionProbeTests {

    enum RotatedFixtureError: Error { case missingResource }

    // MARK: - Fixture loading (probe fixture: no SHA pin -- not a frozen
    // contract; generation command + sample-doc SHA recorded in the PR body)

    static func rotatedPacketPDF() throws -> Data {
        guard let url = Bundle.module.url(
            forResource: "packet-rotate-trigger",
            withExtension: "pdf",
            subdirectory: "TestResources"
        ) else { throw RotatedFixtureError.missingResource }
        return try Data(contentsOf: url)
    }

    static func rotatedGroundTruthJSON() throws -> Data {
        guard let url = Bundle.module.url(
            forResource: "packet-rotate-trigger-ground-truth",
            withExtension: "json",
            subdirectory: "TestResources"
        ) else { throw RotatedFixtureError.missingResource }
        return try Data(contentsOf: url)
    }

    /// The variant ground truth: the P/R-harness occurrence schema plus the
    /// `variant` block stamped by `packet.variants.rotate_trigger`.
    struct VariantGroundTruth: Codable {
        let occurrences: [PacketPRHarnessTests.Occ]
        let carried_stmt: [PacketPRHarnessTests.Occ]
        let variant: VariantMeta
        struct VariantMeta: Codable {
            let kind: String
            let rotate_degrees: Int
        }
    }

    static func loadVariantGroundTruth() throws -> VariantGroundTruth {
        try JSONDecoder().decode(VariantGroundTruth.self, from: try rotatedGroundTruthJSON())
    }

    // MARK: - Fixture sanity (mechanism facts -- hard assertions)

    @Test("Rotate-trigger fixture sanity -- /Rotate 90 on every page, variant-stamped GT")
    func fixtureSanity() throws {
        let doc = try #require(PDFDocument(data: try Self.rotatedPacketPDF()))
        #expect(doc.pageCount == TestFixtures.loanPacketPageCount)
        for pageIndex in 0..<doc.pageCount {
            let page = try #require(doc.page(at: pageIndex))
            #expect(page.rotation == 90,
                    "rotate-trigger page \(pageIndex) must carry /Rotate 90 (got \(page.rotation))")
        }
        let gt = try Self.loadVariantGroundTruth()
        #expect(gt.variant.kind == "rotate-trigger")
        #expect(gt.variant.rotate_degrees == 90)
        // Same drawn-occurrence census as the pristine packet GT -- the variant
        // transforms boxes, it does not add or drop labels.
        let baseline = try PacketPRHarnessTests.loadGroundTruth()
        #expect(gt.occurrences.count == baseline.occurrences.count)
        #expect(gt.occurrences.allSatisfy { $0.bbox != nil })
    }

    // MARK: - The probe

    @Test("Rotated-source detection recall vs transformed GT -- report-only probe")
    func rotatedDetectionProbe() async throws {
        let doc = try #require(PDFDocument(data: try Self.rotatedPacketPDF()))
        let gt = try Self.loadVariantGroundTruth()

        let orchestrator = DetectionOrchestrator(recognitionLevel: .fast)
        let rasterizer = PageRasterizer()
        await Self.warmUpVision(orchestrator, rasterizer)

        // Per-page detections per leg, in the harness's Detection shape so the
        // join verdict is bit-identical to the S05/B scoring.
        var textDets: [Int: [PacketPRHarnessTests.Detection]] = [:]
        var ocrDets: [Int: [PacketPRHarnessTests.Detection]] = [:]
        var textBlocked: Set<Int> = []
        var ocrBlocked: Set<Int> = []

        for pageIndex in 0..<doc.pageCount {
            let page = try #require(doc.page(at: pageIndex))

            // Text leg (production path for a born-digital rotated page).
            var textDoctype = DoctypeClass.generic
            if let embedded = EmbeddedTextSource.make(from: page) {
                do {
                    let image = try await rasterizer.renderPage(
                        page, pageIndex: pageIndex, dpi: 150)
                    let result = try await Self.detectWithRetry(
                        orchestrator, image: image, pageIndex: pageIndex,
                        embeddedText: embedded)
                    textDets[pageIndex] = result.detections.map(Self.harnessDet)
                    textDoctype = result.doctype.primary
                } catch {  // LegalPhrases:safe (Swift keyword)
                    let ns = error as NSError
                    print("[ROT-probe] p\(pageIndex) leg=text DETECT FAILED \(ns.domain)#\(ns.code)")
                    textBlocked.insert(pageIndex)
                }
            } else {
                // No embedded source on a born-digital variant page is itself
                // rotation evidence -- recorded as an empty leg, not an abort.
                print("[ROT-probe] p\(pageIndex) leg=text NO EMBEDDED TEXT SOURCE")
                textDets[pageIndex] = []
            }

            // OCR leg (scan-path check on the same rotated render), at the
            // policy DPI for the doctype the text leg classified -- mirrors
            // PacketSnapshotTests.dualLegSnapshot.
            do {
                let dpi = DetectionRenderPolicy.detectionDPI(for: textDoctype)
                let image = try await rasterizer.renderPage(
                    page, pageIndex: pageIndex, dpi: dpi)
                let result = try await Self.detectWithRetry(
                    orchestrator, image: image, pageIndex: pageIndex,
                    embeddedText: nil)
                ocrDets[pageIndex] = result.detections.map(Self.harnessDet)
            } catch {  // LegalPhrases:safe (Swift keyword)
                let ns = error as NSError
                print("[ROT-probe] p\(pageIndex) leg=ocr DETECT FAILED \(ns.domain)#\(ns.code)")
                ocrBlocked.insert(pageIndex)
            }
            try? await Task.sleep(for: .milliseconds(200))
        }

        // Score both legs against the TRANSFORMED must_fire ground truth.
        let textScore = Self.score(gt.occurrences, leg: "text", dets: textDets, blocked: textBlocked)
        let ocrScore = Self.score(gt.occurrences, leg: "ocr", dets: ocrDets, blocked: ocrBlocked)
        for s in [textScore, ocrScore] { Self.printScore(s) }

        // The measured verdict, report-only. MEASURED 2026-07-06 (q31, first
        // run of the probe): text-leg region recall 1.000 (46/46 must_fire
        // covered; strict 1.000; IoU>=0.5 0.935) -- rotated-source detection
        // PASSED, contradicting the variants.py "FAILS until the fix lands"
        // prediction. The strict withKnownIssue form was verified in both
        // directions on that run (the unexpected pass flagged loudly);
        // `isIntermittent: true` now keeps the suite green on this measured
        // pass while a future regression below the bar is still RECORDED as a
        // known issue, not a gating red -- the probe stays report-only.
        let knownIssueNote = Comment(rawValue:
            "QW-14 rotated-coordinate probe: measured PASS 2026-07-06 "
            + "(text-leg region recall 1.000); a recorded issue here means "
            + "rotated-source detection recall has regressed below 0.5")
        let verdictNote = Comment(rawValue:
            "text-leg rotated region recall \(PacketPRHarnessTests.pct(textScore.regionRecall)) "
            + "(\(textScore.regionHits)/\(textScore.measured) must_fire covered)")
        withKnownIssue(knownIssueNote, isIntermittent: true) {
            #expect(textScore.measured > 0 && textScore.regionRecall >= 0.5, verdictNote)
        }
    }

    // MARK: - Scoring (thin aggregation over the P/R harness join verdict)

    struct LegScore {
        let leg: String
        let measured: Int              // must_fire occurrences on non-blocked pages
        let excludedBlocked: Int       // must_fire occurrences skipped: leg errored on their page
        let regionHits: Int            // coverage >= 0.5 (label-agnostic / privacy)
        let strictHits: Int            // region AND category
        let iouHits: Int               // IoU >= 0.5
        let perCategory: [String: (hits: Int, total: Int)]
        var regionRecall: Double { measured > 0 ? Double(regionHits) / Double(measured) : 0 }
        var strictRecall: Double { measured > 0 ? Double(strictHits) / Double(measured) : 0 }
        var iouRate: Double { measured > 0 ? Double(iouHits) / Double(measured) : 0 }
    }

    static func score(
        _ occurrences: [PacketPRHarnessTests.Occ], leg: String,
        dets: [Int: [PacketPRHarnessTests.Detection]], blocked: Set<Int>
    ) -> LegScore {
        var measured = 0, excluded = 0, region = 0, strict = 0, iouHits = 0
        var perCategory: [String: (hits: Int, total: Int)] = [:]
        for occ in occurrences
        where occ.expectation == "must_fire" && occ.leg_applicability.contains(leg) {
            guard let page = occ.page else { continue }
            if blocked.contains(page) { excluded += 1; continue }
            measured += 1
            let v = PacketPRHarnessTests.join(occ, dets[page] ?? [])
            let cat = PacketPRHarnessTests.normalize(occ.category)
            var bucket = perCategory[cat] ?? (0, 0)
            bucket.total += 1
            if v.covered {
                region += 1
                bucket.hits += 1
                if let c = v.coverCategory,
                   PacketPRHarnessTests.normalize(c) == cat { strict += 1 }
            }
            if v.iouMatched { iouHits += 1 }
            perCategory[cat] = bucket
        }
        return LegScore(
            leg: leg, measured: measured, excludedBlocked: excluded,
            regionHits: region, strictHits: strict, iouHits: iouHits,
            perCategory: perCategory)
    }

    static func printScore(_ s: LegScore) {
        let p = PacketPRHarnessTests.pct
        print("[ROT-probe] --- leg=\(s.leg) measured must_fire=\(s.measured)"
            + (s.excludedBlocked > 0 ? " (EXCLUDED \(s.excludedBlocked) on detect-errored pages)" : "")
            + " ---")
        print("[ROT-probe]   REGION (coverage>=0.5): recall=\(p(s.regionRecall)) (\(s.regionHits)/\(s.measured))")
        print("[ROT-probe]   STRICT (region AND category): recall=\(p(s.strictRecall)) (\(s.strictHits)/\(s.measured))")
        print("[ROT-probe]   IoU>=0.5: \(p(s.iouRate)) (\(s.iouHits)/\(s.measured))")
        for cat in s.perCategory.keys.sorted() {
            let b = s.perCategory[cat]!
            print("[ROT-probe]   \(cat): \(b.hits)/\(b.total) covered")
        }
    }

    // MARK: - Detection plumbing (same shape as PacketSnapshotTests)

    static func harnessDet(_ d: DetectionResult) -> PacketPRHarnessTests.Detection {
        PacketPRHarnessTests.Detection(
            category: PacketSnapshotTests.wireName(for: d.kind),
            normalizedRect: [
                Double(d.normalizedRect.minX), Double(d.normalizedRect.minY),
                Double(d.normalizedRect.width), Double(d.normalizedRect.height)],
            matchedText: d.matchedText)
    }

    /// detectPage with cold-start retries (S8/S01 lesson: transient Vision #9
    /// "could not create inference context" on early requests; retry warms it).
    static func detectWithRetry(
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
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
        throw lastError ?? CancellationError()   // unreachable; satisfies the type checker
    }

    /// Warm the Vision inference context on the ROTATED fixture's own first
    /// page, at both render DPIs the legs use. The #9 "could not create
    /// inference context" is per-render-config (PacketSnapshotTests lesson),
    /// and a /Rotate 90 page renders LANDSCAPE -- a portrait synthetic warm-up
    /// left every landscape config cold and the whole OCR leg blocked on an
    /// isolated first run. Best-effort.
    static func warmUpVision(
        _ orchestrator: DetectionOrchestrator, _ rasterizer: PageRasterizer
    ) async {
        guard let data = try? rotatedPacketPDF(),
              let doc = PDFDocument(data: data),
              let page = doc.page(at: 0)
        else { return }
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
                    print("[ROT-probe] Vision warm-up ok dpi=\(Int(dpi)) attempt=\(attempt)")
                    warmed = true
                    break
                } catch {  // LegalPhrases:safe (Swift keyword)
                    try? await Task.sleep(for: .milliseconds(600))
                }
            }
            if !warmed {
                print("[ROT-probe] Vision warm-up FAILED dpi=\(Int(dpi)) after 8 attempts")
            }
        }
    }
}
