import Foundation
import CoreGraphics
import PDFKit
import Testing
import CryptoKit
@testable import RedactionEngine

// The engine half of the frozen shipped sample bank statement's identity
// (`Resources/SampleDocument.pdf` → engine fixture
// `TestResources/sample-bank-statement.pdf`, SHA 992ca054…ce18fa20, 3 pp).

@Suite("Sample bank-statement Stage-1 snapshot", .serialized)
struct SampleStatementSnapshotTests {

    // MARK: - Dual-copy fixture identity (engine half)

    /// Engine half of the dual-copy identity guard. The app-bundle copy is
    /// pinned by `ResectaAppTests/BundleContentsTests`; the two repo files are
    /// byte-compared at commit time by `Scripts/audit-lint.sh` (AL-3). Three
    /// names, one SHA — a silent fixture substitution must be loud.
    @Test("Fixture identity — SHA-256 + page count pin")
    func fixtureIdentity() throws {
        let data = try TestFixtures.sampleStatementPDF()
        let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #expect(hex == TestFixtures.sampleStatementSHA256,
                "sample-bank-statement.pdf SHA drift — the engine fixture no longer matches the frozen shipped bytes")
        let doc = try #require(PDFDocument(data: data))
        #expect(doc.pageCount == TestFixtures.sampleStatementPageCount)
    }
}
