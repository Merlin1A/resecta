import Testing
import Foundation
@testable import RedactionEngine

// WU-75 / [P3] / D-30 — reverse-rationale doctype-gate parity extended
// from 4 (DOB / NPI / DEA / Account) to 6 (+ MRN / License Plate).
// The reverse-rationale popover renders `.doctypeGated` rows so the user
// understands why a flagged-looking string didn't match — without this
// parity fix, the popover would show `.noMatch` for the three added
// categories even when the engine actually skipped them by gate.
//
// Sign-off: D-31 codification round 2 captures the D-11 escalation gate
// for this engine surface.

@Suite("Doctype-gate parity (WU-75)")
struct DoctypeGateParityTests {

    private var balancedVector: PresetThresholdVector {
        PresetThresholdBundle.builtInDefaults.presets[.balanced]!
    }

    @Test("MRN gated on financial document")
    func mrnGatedOnFinancial() async {
        let detector = PIIDetector()
        // MRN-shaped string with a labeled prefix so the detector would
        // otherwise consider it. `.financial` is not in MRN's runs-set
        // (medical only) — so the reverse gate must report .doctypeGated.
        let snippet = "MRN-0042-9981"
        let context = "Charge code MRN-0042-9981 reconciled to ledger."
        let result = await detector.reverseRationale(
            for: snippet,
            fullContext: context,
            doctype: .financial,
            thresholdVector: balancedVector
        )
        let mrn = result.considered.first { $0.category == .medicalRecord }
        #expect(mrn?.reason == .doctypeGated, "MRN must report .doctypeGated on financial")
        #expect(mrn?.matched == false)
        #expect(result.doctypeGatedOut.contains(.medicalRecord))
    }

    @Test("License plate gated on medical document")
    func licensePlateGatedOnMedical() async {
        let detector = PIIDetector()
        let snippet = "7ABC123"
        let context = "Vehicle 7ABC123 noted in patient transport log."
        let result = await detector.reverseRationale(
            for: snippet,
            fullContext: context,
            doctype: .medical,
            thresholdVector: balancedVector
        )
        let lp = result.considered.first { $0.category == .licensePlate }
        #expect(lp?.reason == .doctypeGated, "License plate must report .doctypeGated on medical")
        #expect(lp?.matched == false)
        #expect(result.doctypeGatedOut.contains(.licensePlate))
    }

    @Test("MRN runs on medical document (not gated)")
    func mrnRunsOnMedical() async {
        let detector = PIIDetector()
        let snippet = "MRN-0042-9981"
        let context = "Patient MRN-0042-9981 admitted yesterday."
        let result = await detector.reverseRationale(
            for: snippet,
            fullContext: context,
            doctype: .medical,
            thresholdVector: balancedVector
        )
        let mrn = result.considered.first { $0.category == .medicalRecord }
        // On a medical doctype, MRN MUST NOT report .doctypeGated — it
        // either matches above threshold or below threshold or noMatch.
        #expect(mrn?.reason != .doctypeGated)
        #expect(!result.doctypeGatedOut.contains(.medicalRecord))
    }

    @Test("License plate runs on generic document (not gated)")
    func licensePlateRunsOnGeneric() async {
        let detector = PIIDetector()
        let snippet = "7ABC123"
        let context = "Towed vehicle 7ABC123 logged at the lot."
        let result = await detector.reverseRationale(
            for: snippet,
            fullContext: context,
            doctype: .generic,
            thresholdVector: balancedVector
        )
        let lp = result.considered.first { $0.category == .licensePlate }
        #expect(lp?.reason != .doctypeGated)
        #expect(!result.doctypeGatedOut.contains(.licensePlate))
    }
}
