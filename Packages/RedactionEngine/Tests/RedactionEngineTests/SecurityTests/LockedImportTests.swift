import Testing
import Foundation
import CoreGraphics
import CryptoKit
import PDFKit
@testable import RedactionEngine

// The committed encrypted fixtures and the import mirror's lock gate. Each
// fixture carries its own pin (it opens locked, the throwaway password
// unlocks it, its text and its payload are there afterwards), so a fixture
// that lost its JavaScript or its hidden layer under encryption proves
// nothing. The mirror then shows the two facts the import relies on: the
// walks must read the UNLOCKED reader, and a reader built from the bytes
// stays locked when only PDFKit was unlocked.

@Suite("Locked import fixtures and mirror", .tags(.security))
struct LockedImportTests {

    // MARK: - The committed set

    static let directory: URL = {
        URL(fileURLWithPath: "\(#filePath)")
            .deletingLastPathComponent()   // SecurityTests
            .deletingLastPathComponent()   // RedactionEngineTests
            .appendingPathComponent("Fixtures/TestResources/Encrypted", isDirectory: true)
    }()

    static func bytes(_ name: String) throws -> Data {
        try Data(contentsOf: directory.appendingPathComponent(name))
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The README's hashes: the committed bytes are the fixtures.
    static let pins: [String: String] = [
        "seed-text.pdf": "8ec5ebb500ce2d6eee07e562edc798f3f2281f81965c9bcb7d7437aabf3bbcd1",
        "seed-javascript.pdf": "6855231094eca6f63d86517bd017faa9344bfaf79062606e35239dda623f61d9",
        "seed-hidden-ocg.pdf": "b5c43ad86f809d1c14bfb59e8d791eb601cf2cc62f5b01040029a989ce14b101",
        "r3-rc4-128.pdf": "0af802de0dcc106dc96ceaf40c9b59db8e81004ba72a9aa8bdd9bbc5e15bf415",
        "r4-aes-128.pdf": "102a0f3ebeab790294be22d7d863385c5d75de6f807451dfb6c9ebbf3c0f09d9",
        "r6-aes-256.pdf": "8bd55ecfce59c47f912bfba2db6680c4b059a353abb5a3a90b09dc2f7d00921a",
        "owner-only-r6.pdf": "557a914fd791c1885189f0434a6c897d19209c9af021e5773c5136cf219f8980",
        "owner-only-nocopy-r4.pdf": "2329ececa45aa2881e73b5a19bb15814d4a071275cdca26db688f9ed19652233",
        "r4-nonascii.pdf": "ddbd093444e4a1d0c32f9eb72c26e1a7b673ae01dc9579d8a7f9107e20efbec8",
        "r6-nonascii.pdf": "b9eae6a4fd0b6c1e3434c6cc003bfc207ca2417917df22fef920e1a2ff062399",
        "r6-cjk.pdf": "2fdd09c0dfa039d1cdcba61619f63ccb1cf886c86c181af87ce10df105cf46bc",
        "locked-javascript-r6.pdf": "c5d054987acda3b8fdaa12aef4f5eb0935b5ad1cca6168341445c3346f0b9b95",
        "locked-hidden-ocg-r6.pdf": "366e22c93f2da3844db76bbbd318c529a6c1c864d930ef4c3855518e59ea4dda",
        "certificate-stub.pdf": "704c1e3a6a5a44567b449fd5ca028f82006e8e9b23392ae72cf1312bf6bead0c",
        "unknown-handler-stub.pdf": "2e37b1bb3e66419282009c863312b8911d7885058679bf146fe8abb9fb6a896a",
    ]

    @Test("Every committed fixture matches its pinned hash")
    func committedBytesArePinned() throws {
        for (name, hash) in Self.pins {
            #expect(Self.sha256(try Self.bytes(name)) == hash, "\(name)")
        }
    }

    @Test("The user-password fixtures open locked, refuse a wrong password and read their text once unlocked",
          arguments: ["r3-rc4-128.pdf", "r4-aes-128.pdf", "r6-aes-256.pdf", "locked-javascript-r6.pdf", "locked-hidden-ocg-r6.pdf"])
    func userPasswordFixtureOpensWithItsPassword(name: String) throws {
        let doc = try #require(PDFDocument(data: try Self.bytes(name)))
        #expect(doc.isLocked)
        #expect(doc.isEncrypted)
        #expect(!doc.unlock(withPassword: "wrong"))
        #expect(doc.isLocked)
        #expect(doc.unlock(withPassword: "user"))
        #expect(!doc.isLocked)
        #expect(doc.pageCount == 1)
        let page = try #require(doc.page(at: 0))
        #expect(page.pageRef?.dictionary != nil)
        let text = page.string ?? ""
        #expect(text.contains("ENCRYPTED SEED 7731") || text.contains("VISIBLE WORD 2210"), "\(name)")
    }

    @Test("The owner-only fixtures open with no password and report their withheld permissions")
    func ownerOnlyFixturesOpenUnprompted() throws {
        let restricted = try #require(PDFDocument(data: try Self.bytes("owner-only-r6.pdf")))
        #expect(!restricted.isLocked)
        #expect(restricted.isEncrypted)
        #expect(!restricted.allowsPrinting)
        #expect(restricted.permissionsStatus != .owner)
        let noCopy = try #require(PDFDocument(data: try Self.bytes("owner-only-nocopy-r4.pdf")))
        #expect(!noCopy.isLocked)
        #expect(noCopy.isEncrypted)
        #expect(!noCopy.allowsCopying)
    }

    @Test("The two handler stubs open as plain documents: iOS reads no lock from a foreign encryption dictionary")
    func handlerStubsOpenAsPlain() throws {
        for name in ["certificate-stub.pdf", "unknown-handler-stub.pdf"] {
            let doc = try #require(PDFDocument(data: try Self.bytes(name)))
            #expect(!doc.isLocked, "\(name)")
            #expect(!doc.isEncrypted, "\(name)")
            #expect(doc.page(at: 0)?.string?.contains("ENCRYPTED SEED 7731") == true, "\(name)")
        }
    }

    // MARK: - The payloads survive encryption

    @Test("The locked JavaScript fixture's action is read on the unlocked reader and nothing is read on a reader left locked")
    func lockedJavaScriptPayloadSurvives() throws {
        let data = try Self.bytes("locked-javascript-r6.pdf")
        let doc = try #require(PDFDocument(data: data))
        #expect(doc.unlock(withPassword: "user"))
        let unlocked = try #require(doc.documentRef)
        #expect(unlocked.isUnlocked)
        #expect(ActiveContentScan.firstLocation(in: unlocked) == .openAction)

        // A second reader built from the bytes is a different document:
        // PDFKit's unlock does not reach it, and its page tree reads empty.
        let separate = try #require(CGPDFDocument(CGDataProvider(data: data as CFData)!))
        #expect(!separate.isUnlocked)
        #expect(separate.page(at: 1)?.dictionary == nil)
    }

    @Test("The locked hidden-layer fixture's /OFF array is read on the unlocked reader; locked, it shows zero pages")
    func lockedHiddenLayerPayloadSurvives() throws {
        let data = try Self.bytes("locked-hidden-ocg-r6.pdf")
        let doc = try #require(PDFDocument(data: data))
        #expect(doc.pageCount == 0, "locked, the object-stream page tree is unreadable")
        #expect(doc.unlock(withPassword: "user"))
        #expect(doc.pageCount == 1)
        let unlocked = try #require(doc.documentRef)
        #expect(TextLayerExtractor.documentHasHiddenOCG(unlocked))
        #expect(doc.page(at: 0)?.string?.contains("HIDDENLAYER 4410") == true)
    }

    // MARK: - The import mirror's lock gate

    private func mirrorClass(_ result: RobustnessRunnerTests.ImportMirrorResult) -> String {
        switch result {
        case .open: "open"
        case .reject(let errorClass): errorClass
        }
    }

    @Test("Without a password a locked document is refused as password-protected; with the wrong one the same")
    func mirrorRefusesWithoutThePassword() throws {
        let data = try Self.bytes("r6-aes-256.pdf")
        #expect(mirrorClass(RobustnessRunnerTests.importMirror(data)) == "passwordProtected")
        #expect(mirrorClass(RobustnessRunnerTests.importMirror(data, password: "wrong")) == "passwordProtected")
    }

    @Test("With the password the mirror opens the document and reads its text layer",
          arguments: ["r3-rc4-128.pdf", "r4-aes-128.pdf", "r6-aes-256.pdf"])
    func mirrorOpensWithThePassword(name: String) throws {
        guard case .open(let doc, let status, let hidden) =
                RobustnessRunnerTests.importMirror(try Self.bytes(name), password: "user") else {
            Issue.record("\(name) did not open"); return
        }
        #expect(!doc.isLocked)
        #expect(status[0] == .rich)
        #expect(hidden == false)
    }

    @Test("Locked plus JavaScript: the password reaches the walk, which refuses the document for its action")
    func mirrorRefusesActiveContentBehindThePassword() throws {
        let data = try Self.bytes("locked-javascript-r6.pdf")
        #expect(mirrorClass(RobustnessRunnerTests.importMirror(data)) == "passwordProtected")
        #expect(mirrorClass(RobustnessRunnerTests.importMirror(data, password: "user")) == "activeContent")
    }

    @Test("Locked plus a hidden layer: the password reaches the walk, which reads the layer on the unlocked reader")
    func mirrorReadsHiddenLayerBehindThePassword() throws {
        let data = try Self.bytes("locked-hidden-ocg-r6.pdf")
        guard case .open(_, _, let hidden) = RobustnessRunnerTests.importMirror(data, password: "user") else {
            Issue.record("did not open"); return
        }
        #expect(hidden == true)
    }

    @Test("An owner-only document opens through the mirror with no password")
    func mirrorOpensOwnerOnlyUnprompted() throws {
        #expect(mirrorClass(RobustnessRunnerTests.importMirror(try Self.bytes("owner-only-r6.pdf"))) == "open")
    }

    @Test("The corpus runner's hidden-layer fact reads the unlocked reader of a locked twin")
    func corpusMirrorReadsUnlockedTwin() throws {
        let doc = try #require(PDFDocument(data: try Self.bytes("locked-hidden-ocg-r6.pdf")))
        #expect(doc.unlock(withPassword: "user"))
        #expect(VerificationCorpusRunnerTests.documentHasHiddenOCG(doc))
        let plain = try #require(PDFDocument(data: try Self.bytes("seed-hidden-ocg.pdf")))
        #expect(VerificationCorpusRunnerTests.documentHasHiddenOCG(plain))
        let text = try #require(PDFDocument(data: try Self.bytes("seed-text.pdf")))
        #expect(!VerificationCorpusRunnerTests.documentHasHiddenOCG(text))
    }

    @Test("The corpus factory set carries the two seeds and their three locked twins")
    func corpusFactorySetCarriesTheTwins() {
        let inputs = VerificationCorpusRunnerTests.encryptedInputs()
        #expect(inputs.map(\.docId) == [
            "encrypted-seed-text", "encrypted-seed-hidden-ocg",
            "encrypted-r4-aes-128", "encrypted-r6-aes-256", "encrypted-locked-hidden-ocg-r6",
        ])
        #expect(inputs.filter { $0.password != nil }.count == 3)
        #expect(inputs.compactMap(\.plainTwinId) == [
            "encrypted-seed-text", "encrypted-seed-text", "encrypted-seed-hidden-ocg",
        ])
        #expect(VerificationCorpusRunnerTests.factoryInputs().map(\.docId).suffix(5) == inputs.map(\.docId))
    }
}
