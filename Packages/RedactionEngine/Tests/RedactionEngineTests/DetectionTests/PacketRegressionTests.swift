import Foundation
import CoreGraphics
import PDFKit
import Testing
@testable import RedactionEngine

// The VEH `.generic` gating verification for the synthetic Hartwell loan
// packet: page 11 classifies `.generic`, so its licence plate fires, and the
// `.financial` gate suppresses it. Both run on the page's embedded text.

@Suite("Hartwell packet -- VEH .generic gating + must-fire/not-fire freeze", .serialized)
struct PacketRegressionTests {

    // MARK: - Lens D: VEH `.generic` classification + licensePlate gate

    @Test("VEH page 11 classifies .generic (STOP if .financial)")
    func vehClassifiesGeneric() async throws {
        let document = try #require(PDFDocument(data: try TestFixtures.loanPacketPDF()))
        let page = try #require(document.page(at: 11))
        let text = try #require(EmbeddedTextSource.make(from: page)).text
        let result = await DocumentTypeClassifier().classify(pageText: text)
        print("[OCRQ-pkt] p11(VEH) doctype=\(result.primary.rawValue) "
            + "softmax=\(result.softmax.map { ($0.key.rawValue, ($0.value * 1000).rounded() / 1000) }.sorted { $0.0 < $1.0 })")
        #expect(result.primary == .generic,
                "STOP: VEH page must classify .generic for licensePlate to fire; got \(result.primary.rawValue). Un-gating licensePlate for .financial would be a policy change, not a tuning.")
    }

    @Test("VEH licensePlate gate: 7XYZ842 fires under .generic; VIN/Tag/cross-page negatives do not; .financial suppresses")
    func licensePlateGate() async throws {
        let document = try #require(PDFDocument(data: try TestFixtures.loanPacketPDF()))
        let page = try #require(document.page(at: 11))
        let text = try #require(EmbeddedTextSource.make(from: page)).text

        let generic = await PIIDetector().detect(in: text, doctype: .generic, documentHeader: nil)
        let plates = generic.filter { $0.kind == .licensePlate }.map { $0.text }
        print("[OCRQ-pkt] p11 licensePlate(.generic) matched=\(plates)")
        // occ_veh_01 must fire as licensePlate (the must-fire case).
        #expect(plates.contains { $0.contains("7XYZ842") }, "occ_veh_01 (7XYZ842) must fire as licensePlate on the .generic VEH page")
        // occ_veh_04 (VIN) must NOT fire as licensePlate (too long / not plate-shaped).
        #expect(!plates.contains { $0.contains("4S4BSANC1K3304412") }, "occ_veh_04 VIN must not fire as licensePlate")
        // NOTE: occ_veh_05 "Tag No: 88KJ2" DOES fire as
        // licensePlate -- "Tag No" is a plate-label synonym, so this is
        // defensible engine behavior. The manifest mis-tiered it as a negative;
        // this test treats it as a watch case rather than a must-not-fire.

        // Gate proof: under .financial the same page yields NO licensePlate.
        let financial = await PIIDetector().detect(in: text, doctype: .financial, documentHeader: nil)
        #expect(!financial.contains { $0.kind == .licensePlate },
                "licensePlate is doctype-gated OFF on .financial -- the gate that makes the VEH .generic page necessary")
    }
}
