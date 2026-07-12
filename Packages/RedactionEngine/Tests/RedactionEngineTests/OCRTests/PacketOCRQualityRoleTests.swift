import Foundation
import PDFKit
import CryptoKit
import Testing
@testable import RedactionEngine

// S06 -- INV-2 retirement checklist, ROLE 1 of 3.
//
// The packet successor to `RealDocOCRQualityTests`. That suite runs the
// production OCR->detect leg (PageRasterizer.renderPage at the policy DPI ->
// DetectionOrchestrator.detectPage with embeddedText: nil = forced Vision OCR)
// over the retired born-digital + scan-sim fixtures and emits per-
// category COUNTS, asserting the structural invariants (page_count;
// ocr_invocations == page_count). Its HARD per-category pins run on SYNTHETIC
// fixtures (the 7/8/9 pt small-text doc; the 20-page memory/latency doc) which
// are fixture-INDEPENDENT and survive F28 untouched -- so the fixture-specific
// part of the role is exactly the born-digital/scan-sim SWEEP. This suite proves the
// same SWEEP on the packet scan-sim, the degraded-scan proxy and the production
// path for this packet (S05: text coverage 0.10-0.21 < 0.95 -> OCR leg).
//
// It REUSES the same instrument verbatim (`RealDocOCRQualityTests.sweep`), so
// the measurement is genuinely the same; only the fixture changes.
//
// Cross-walk to S05 (the role transfers with measured-comparable counts): the
// committed-snapshot OCR leg (PacketPRHarnessTests, the same forced-OCR path)
// measured STMT pages 3-5 OCR counts account 7 / phone 7 / address 3 / name 2 /
// email 1 and OCR-leg region recall 0.565. A live scan-sim sweep is Vision- and
// runtime-dependent, so this suite asserts the ROBUST structural invariants +
// a conservative non-emptiness floor and EMITS the per-category counts; the
// deterministic per-category cross-walk lives in PacketPRHarnessTests.
//
// FACE-BLOCK (S05 result #1): pages 10 (GOV-ID) + 11 (VEH) classify non-
// financial, so detectPage runs the Vision face pass which throws Vision #9 on
// the simulator. The sweep records those as page_errors and continues; the
// deterministic ocr_invocations tally counts only pages that COMPLETE the
// OCR->detect leg, so 10/11 are excluded -- ocr_invocations is the 10 financial
// pages, and page_errors is bounded to the 2 known face pages.
//
// MATCHED-TEXT LOGGING: counts and categories only (this reuses the same
// instrument, which is counts-only by construction).

@Suite("Packet OCR-quality role (S06 retirement checklist)", .serialized)
struct PacketOCRQualityRoleTests {

    @Test("S06 scan-sim identity pin -- SHA-256 + page count")
    func scanSimIdentityPin() throws {
        let data = try TestFixtures.loanPacketScanSimPDF()
        let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #expect(hex == TestFixtures.loanPacketScanSimSHA256,
                "committed packet scan-sim bytes must match the recorded SHA-256")
        let doc = PDFDocument(data: data)
        #expect(doc?.pageCount == TestFixtures.loanPacketPageCount,
                "packet scan-sim must have exactly 12 pages")
    }

    @Test("OCR-leg sweep over the packet scan-sim (realdoc ROLE 1 successor)")
    func packetScanSimOCRSweep() async throws {
        let scanSim = try TestFixtures.loanPacketScanSimPDF()
        let (sweep, pages) = try await RealDocOCRQualityTests.sweep(
            pdfData: scanSim, label: "packet_scan_sim"
        )

        // Structural invariants (mirrors the predecessor scan-sim assertions).
        #expect(sweep.page_count == TestFixtures.loanPacketPageCount,
                "packet scan-sim must sweep all 12 pages")
        // ocr_invocations is the deterministic per-sweep tally of pages that
        // COMPLETE the forced-OCR detectPage. The 10 financial pages (0-9)
        // complete it; the 2 face pages (10/11) OCR then throw at the face pass,
        // so they are page_errors, not invocations. Robust to concurrent OCR
        // siblings in a batched run (no process-global counter).
        #expect(sweep.ocr_invocations >= 10,
                "every financial scan-sim page must take the Vision OCR leg; got \(sweep.ocr_invocations)")

        // The only tolerated page errors are the 2 known face-block pages.
        #expect(sweep.page_errors.count <= 2,
                "only the GOV-ID/VEH face pages may error; got \(sweep.page_errors.count): \(sweep.page_errors)")

        // Non-emptiness floor on the financial pages (0-9): the degraded-scan
        // OCR leg must still surface PII somewhere (a total OCR regression would
        // zero this). per_page_raw_counts carries -1 for an errored page.
        let financialRaw = (0...9).compactMap { idx -> Int? in
            idx < sweep.per_page_raw_counts.count ? sweep.per_page_raw_counts[idx] : nil
        }.filter { $0 >= 0 }
        let financialTotal = financialRaw.reduce(0, +)
        #expect(financialTotal > 0,
                "the scan-sim OCR leg surfaced no detections on the financial pages (pages 0-9)")

        // Emit the per-category counts (the measured-comparable cross-walk).
        let catReport = sweep.categories
            .mapValues { "\($0.raw)/\($0.surfaced)" }
            .sorted { $0.key < $1.key }
        print("[PKT-OCRQ] scan_sim pages=\(sweep.page_count) ocr=\(sweep.ocr_invocations) "
            + "financialRaw(0-9)=\(financialTotal) page_errors=\(sweep.page_errors.count)")
        print("[PKT-OCRQ] per-category raw/surfaced: \(catReport)")
        print("[PKT-OCRQ] per-page raw counts: \(sweep.per_page_raw_counts)")
        _ = pages  // detections retained by the instrument; counts are the role.
    }
}
