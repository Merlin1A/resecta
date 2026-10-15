import Foundation
import CoreGraphics
import PDFKit
import Testing
import CryptoKit
@testable import RedactionEngine

// The synthetic Hartwell loan packet's fixture identity (the
// resecta-sample-doc generator -> engine fixture `TestResources/packet.pdf`,
// 12 pp): the packet, its scan-sim and its ground truth, each by SHA-256.

@Suite("Hartwell loan-packet Stage-1 snapshot", .serialized)
struct PacketSnapshotTests {

    // MARK: - Fixture identity

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
}
