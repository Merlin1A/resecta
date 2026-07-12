import Testing
import Foundation
@testable import RedactionEngine

// WS1 design 01 §10 — PO Box / rural-route / APO address arms (item 1.14, 2026-06-10).
//
// Three new regex arms appended to detectAddresses() at fixed 0.70 confidence,
// matching the existing street-address arm's confidence.
// Design doc location: DetectionOrchestratorTests.swift (address suite) or
// a new sibling file. Using a sibling (AddressArmTests.swift) here because
// the new tests exercise only PIIDetector.detectAddresses directly, without
// Vision/orchestrator machinery — keeping them in DetectionOrchestratorTests
// (which is .serialized for Vision) would unnecessarily serialize fast
// unit tests. Noted in report per spec.

@Suite("Address PO Box / rural-route / APO arms (design 01 §10, item 1.14)")
struct AddressArmTests {

    private func addressMatches(in text: String) -> [PIIDetector.PIIMatch] {
        let detector = PIIDetector()
        let ns = text as NSString
        return detector.detectAddresses(in: ns, range: NSRange(location: 0, length: ns.length))
            .filter { $0.kind == .address }
    }

    // MARK: - PO Box arm

    @Test("PO Box: 'P.O. Box 1234' detected")
    func poBox_detected() {
        let matches = addressMatches(in: "P.O. Box 1234")
        #expect(matches.count >= 1, "'P.O. Box 1234' should match poBoxPattern")
        if let m = matches.first {
            #expect(m.confidence == 0.70, "PO Box arm emits fixed 0.70")
        }
    }

    @Test("PO Box: 'PO Box 4567' detected")
    func poBox_noDotsVariant_detected() {
        let matches = addressMatches(in: "PO Box 4567")
        #expect(matches.count >= 1, "'PO Box 4567' should match poBoxPattern")
    }

    @Test("PO Box: 'Post Office Box 99' detected")
    func postOfficeBox_detected() {
        let matches = addressMatches(in: "Post Office Box 99")
        #expect(matches.count >= 1, "'Post Office Box 99' should match poBoxPattern")
    }

    @Test("PO Box: 'P.O. BOX 99999' detected (case-insensitive)")
    func poBox_uppercase_detected() {
        let matches = addressMatches(in: "P.O. BOX 99999")
        #expect(matches.count >= 1, "Case-insensitive match for all-caps BOX")
    }

    @Test("PO Box adversarial: 'the box 12' — no match (no P.O./Post Office prefix)")
    func poBox_adversarial_noPrefix_rejected() {
        let matches = addressMatches(in: "the box 12")
        let poBoxMatches = matches.filter { $0.text.lowercased().contains("box 12") }
        // "the box 12" lacks P.O./Post Office prefix — poBoxPattern must not fire.
        // Note: the street-address arm also won't fire (no street suffix).
        #expect(poBoxMatches.isEmpty, "'the box 12' should not match any address arm")
    }

    // MARK: - Rural route arm

    @Test("Rural route: 'RR 2 Box 45' detected")
    func ruralRoute_detected() {
        let matches = addressMatches(in: "RR 2 Box 45")
        #expect(matches.count >= 1, "'RR 2 Box 45' should match ruralRoutePattern")
        if let m = matches.first {
            #expect(m.confidence == 0.70, "Rural route arm emits fixed 0.70")
        }
    }

    @Test("Rural route: 'HC 1 Box 7B' detected (highway contract / box with letter)")
    func ruralRoute_HC_detected() {
        let matches = addressMatches(in: "HC 1 Box 7B")
        #expect(matches.count >= 1, "'HC 1 Box 7B' should match ruralRoutePattern")
    }

    @Test("Rural route: 'Rural Route 3 Box 12A' detected")
    func ruralRoute_longForm_detected() {
        let matches = addressMatches(in: "Rural Route 3 Box 12A")
        #expect(matches.count >= 1, "'Rural Route 3 Box 12A' should match ruralRoutePattern")
    }

    @Test("Rural route adversarial: 'RR Lyrae' — no match (no Box component)")
    func ruralRoute_adversarial_noBox_rejected() {
        let matches = addressMatches(in: "RR Lyrae is a variable star")
        // "RR Lyrae" lacks the required 'digit Box digit' suffix — must not fire.
        let rrMatches = matches.filter { $0.text.lowercased().hasPrefix("rr") }
        #expect(rrMatches.isEmpty, "'RR Lyrae' should not match ruralRoutePattern (no Box)")
    }

    // MARK: - APO/FPO/DPO arm

    @Test("APO AE: 'APO AE 09010' detected")
    func apo_ae_detected() {
        let matches = addressMatches(in: "APO AE 09010")
        #expect(matches.count >= 1, "'APO AE 09010' should match apofpoPattern")
        if let m = matches.first {
            #expect(m.confidence == 0.70, "APO arm emits fixed 0.70")
        }
    }

    @Test("FPO AP: 'FPO AP 96606' detected")
    func fpo_ap_detected() {
        let matches = addressMatches(in: "FPO AP 96606")
        #expect(matches.count >= 1, "'FPO AP 96606' should match apofpoPattern")
    }

    @Test("FPO AP with ZIP+4: 'FPO AP 96606-0001' detected")
    func fpo_ap_zipPlus4_detected() {
        let matches = addressMatches(in: "FPO AP 96606-0001")
        #expect(matches.count >= 1, "'FPO AP 96606-0001' (ZIP+4) should match apofpoPattern")
    }

    @Test("DPO AA: 'DPO AA 34001' detected")
    func dpo_aa_detected() {
        let matches = addressMatches(in: "DPO AA 34001")
        #expect(matches.count >= 1, "'DPO AA 34001' should match apofpoPattern")
    }

    @Test("APO adversarial: 'APO drug store' — no match (no valid AE/AA/AP + ZIP)")
    func apo_adversarial_noZip_rejected() {
        let matches = addressMatches(in: "APO drug store")
        // "APO drug" has no valid AE/AA/AP code + 5-digit ZIP — must not fire.
        let apoMatches = matches.filter { $0.text.lowercased().hasPrefix("apo") }
        #expect(apoMatches.isEmpty, "'APO drug store' should not match apofpoPattern")
    }

    // MARK: - Existing street-address arm still runs

    @Test("Existing street-address arm still fires after restructure")
    func existingArm_stillWorks() {
        // Verify the restructure did not break the original arm.
        let matches = addressMatches(in: "123 Main St, Anytown, CA 90210")
        #expect(matches.count >= 1, "Street-address arm must still work after §10 restructure")
        if let m = matches.first {
            #expect(m.confidence == 0.70)
        }
    }
}
