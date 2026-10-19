import Foundation
import PDFKit
import CryptoKit
import Testing
@testable import RedactionEngine

// The packet scan-sim fixture's identity: its SHA-256 and page count.

@Suite("Packet OCR-quality role (retirement checklist)", .serialized)
struct PacketOCRQualityRoleTests {

    @Test("Scan-sim identity pin -- SHA-256 + page count")
    func scanSimIdentityPin() throws {
        let data = try TestFixtures.loanPacketScanSimPDF()
        let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #expect(hex == TestFixtures.loanPacketScanSimSHA256,
                "committed packet scan-sim bytes must match the recorded SHA-256")
        let doc = PDFDocument(data: data)
        #expect(doc?.pageCount == TestFixtures.loanPacketPageCount,
                "packet scan-sim must have exactly 12 pages")
    }
}
