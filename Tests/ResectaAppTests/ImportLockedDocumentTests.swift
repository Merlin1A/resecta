import Testing
import Foundation
import CoreGraphics
import PDFKit
@testable import ResectaApp
@testable import RedactionEngine

// A password-locked document through the loader and the wrapper: refused
// with the hold when no password is supplied, refused again on a wrong one,
// opened on the right one with its facts and its page tree readable, the
// owner-only file opened with no prompt and its record set, and the two
// return phases the sheet rides.

@Suite("Import of a locked document", .tags(.importFlow))
@MainActor
struct ImportLockedDocumentTests {

    static let directory: URL = {
        URL(fileURLWithPath: "\(#filePath)")
            .deletingLastPathComponent()   // Tests/ResectaAppTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // <repo root>
            .appendingPathComponent("Packages/RedactionEngine/Tests/RedactionEngineTests/Fixtures/TestResources/Encrypted", isDirectory: true)
    }()

    static func bytes(_ name: String) throws -> Data {
        try Data(contentsOf: directory.appendingPathComponent(name))
    }

    /// The import failure a load threw, spelled the way the cases are, or
    /// "none" when the load succeeded.
    private func refusalName(_ data: Data, password: String?) async -> String {
        do {
            _ = try await ImportService.validatePDFOffMainActor(data: data, password: password)
            return "none"
        } catch let error as PipelineError {
            if case .importError(let failure) = error { return String(describing: failure) }
            return "other"
        } catch {
            return "other"
        }
    }

    // MARK: - The loader

    @Test("Without a password a locked document is refused as password-protected")
    func lockedWithoutPasswordRefused() async throws {
        #expect(await refusalName(try Self.bytes("r6-aes-256.pdf"), password: nil) == "passwordProtected")
    }

    @Test("A wrong password is refused as password-protected")
    func wrongPasswordRefused() async throws {
        #expect(await refusalName(try Self.bytes("r6-aes-256.pdf"), password: "wrong") == "passwordProtected")
    }

    @Test("The right password opens the document: its facts read the text layer and the encryption record",
          arguments: ["r3-rc4-128.pdf", "r4-aes-128.pdf", "r6-aes-256.pdf"])
    func rightPasswordOpens(name: String) async throws {
        let loaded = try await ImportService.validatePDFOffMainActor(data: try Self.bytes(name), password: "user")
        let doc = loaded.document.document
        #expect(!doc.isLocked)
        #expect(loaded.facts.textLayerStatus[0] == .rich)
        #expect(loaded.facts.hasHiddenOCG == false)
        #expect(loaded.facts.wasEncrypted == true)
        #expect(loaded.facts.hadRestrictions == false, "the user who typed the user password reads every permission")
        // The unlock carries to the page the engine draws: a non-blank
        // render and a readable page dictionary, with no engine change.
        let page = try #require(doc.page(at: 0))
        #expect(page.pageRef?.dictionary != nil)
        #expect(Self.nonWhitePixels(page) > 0)
    }

    @Test("Locked plus JavaScript: the password reaches the walk and the document is refused for its action")
    func lockedJavaScriptRefusedBehindThePassword() async throws {
        let data = try Self.bytes("locked-javascript-r6.pdf")
        #expect(await refusalName(data, password: nil) == "passwordProtected")
        #expect(await refusalName(data, password: "user") == "activeContent(location: RedactionEngine.ActiveContentLocation.openAction)")
    }

    @Test("Locked plus a hidden layer: the password reaches the walk and the fact reads true")
    func lockedHiddenLayerReadBehindThePassword() async throws {
        let loaded = try await ImportService.validatePDFOffMainActor(
            data: try Self.bytes("locked-hidden-ocg-r6.pdf"), password: "user")
        #expect(loaded.facts.hasHiddenOCG == true)
        #expect(loaded.document.document.pageCount == 1)
    }

    @Test("An owner-only document opens with no password, with the encrypted-source record and its withheld permissions")
    func ownerOnlyOpensUnprompted() async throws {
        let loaded = try await ImportService.validatePDFOffMainActor(data: try Self.bytes("owner-only-r6.pdf"), password: nil)
        #expect(loaded.facts.wasEncrypted == true)
        #expect(loaded.facts.hadRestrictions == true)
        #expect(loaded.facts.summary == ImportFacts.Summary(origin: .pdf, wasEncrypted: true, hadRestrictions: true))
    }

    @Test("A no-copy owner-only document still reads its text layer")
    func noCopyOwnerOnlyReadsText() async throws {
        let loaded = try await ImportService.validatePDFOffMainActor(data: try Self.bytes("owner-only-nocopy-r4.pdf"), password: nil)
        #expect(loaded.facts.hadRestrictions == true)
        #expect(loaded.facts.textLayerStatus[0] == .rich)
        #expect(loaded.document.document.page(at: 0)?.string?.contains("ENCRYPTED SEED 7731") == true)
    }

    @Test("The CJK password opens its document; the Latin non-ASCII password is refused by PDFKit (recorded)")
    func nonASCIIPasswords() async throws {
        #expect(await refusalName(try Self.bytes("r6-cjk.pdf"), password: "密码") == "none")
        // PDFKit does not open the files qpdf locked with `pässwörd`; the
        // reading is kept here so a change in the reader shows.
        #expect(await refusalName(try Self.bytes("r6-nonascii.pdf"), password: "pässwörd") == "passwordProtected")
        #expect(await refusalName(try Self.bytes("r4-nonascii.pdf"), password: "pässwörd") == "passwordProtected")
    }

    @Test("A plain document is unaffected by a password it does not need")
    func plainDocumentIgnoresPassword() async throws {
        let loaded = try await ImportService.validatePDFOffMainActor(data: makeTextPDFData(text: "plain"), password: "anything")
        #expect(loaded.facts.wasEncrypted == false)
    }

    // MARK: - The wrapper: the hold and the two return phases

    @Test("A locked data import returns the hold with the bytes and leaves the failed state beneath the sheet")
    func lockedImportReturnsTheHold() async throws {
        let data = try Self.bytes("r6-aes-256.pdf")
        let doc = DocumentState()
        let redaction = RedactionState()
        let outcome = await ImportService.importDocument(
            data: data, suggestedType: "pdf", door: .files, documentState: doc, redactionState: redaction)
        guard case .needsPassword(let hold) = outcome else {
            Issue.record("expected the hold, got \(outcome)"); return
        }
        #expect(hold.bytes.count == data.count)
        #expect(hold.door == .files)
        #expect(hold.attempts == 0)
        #expect(hold.lastOutcome == .awaiting)
        if case .empty = hold.returnPhase {} else { Issue.record("return phase should be empty") }
        guard case .failed(let error, let returnPhase) = doc.phase else {
            Issue.record("phase should be failed, is \(doc.phaseKind)"); return
        }
        if case .importError(.passwordProtected) = error {} else { Issue.record("the failed card should name the password, not \(error)") }
        if case .empty = returnPhase {} else { Issue.record("return phase should be empty") }
        #expect(doc.sourceDocument == nil)
        #expect(doc.documentPassword.isEmpty)
    }

    @Test("A plain data import returns completed")
    func plainImportCompletes() async {
        let doc = DocumentState()
        let redaction = RedactionState()
        let outcome = await ImportService.importDocument(
            data: makeTextPDFData(text: "plain"), suggestedType: "pdf", documentState: doc, redactionState: redaction)
        #expect(outcome == .completed)
        #expect(doc.phaseKind == .editing)
        #expect(doc.sourceFacts == ImportFacts.Summary())
    }

    @Test("With a document open, a locked drop holds with the editing return phase and leaves the prior document intact")
    func lockedDropOverOpenDocumentKeepsThePrior() async throws {
        let doc = DocumentState()
        let redaction = RedactionState()
        _ = await ImportService.importDocument(
            data: makeTextPDFData(text: "prior"), suggestedType: "pdf", documentState: doc, redactionState: redaction)
        let prior = doc.sourceDocument
        #expect(prior != nil)
        let outcome = await ImportService.importDocument(
            data: try Self.bytes("r4-aes-128.pdf"), door: .drop, documentState: doc, redactionState: redaction)
        guard case .needsPassword(let hold) = outcome else {
            Issue.record("expected the hold"); return
        }
        if case .editing = hold.returnPhase {} else { Issue.record("return phase should be editing") }
        #expect(doc.sourceDocument === prior)
        // Cancel's derived transition returns to the editor with the prior
        // document.
        #expect(doc.transition(to: ImportPasswordFlow.cancelPhase(returnPhase: hold.returnPhase)))
        #expect(doc.phaseKind == .editing)
        #expect(doc.sourceDocument === prior)
    }

    @Test("The re-run with the right password opens the document, sets the record and keeps the password for the session")
    func rerunWithPasswordOpens() async throws {
        let data = try Self.bytes("r4-aes-128.pdf")
        let doc = DocumentState()
        let redaction = RedactionState()
        let first = await ImportService.importDocument(
            data: data, door: .files, documentState: doc, redactionState: redaction)
        guard case .needsPassword(let hold) = first else { Issue.record("expected the hold"); return }
        // The sheet's re-run starts from the phase Cancel would return to.
        #expect(doc.transition(to: ImportPasswordFlow.cancelPhase(returnPhase: hold.returnPhase)))
        let second = await ImportService.importDocument(
            data: hold.bytes, door: hold.door, password: "user", documentState: doc, redactionState: redaction)
        #expect(second == .completed)
        #expect(doc.phaseKind == .editing)
        #expect(doc.sourceFacts.wasEncrypted == true)
        #expect(!doc.documentPassword.isEmpty)
        #expect(doc.documentPassword.withPassword { $0 } == "user")
    }

    @Test("The re-run with a wrong password holds again with one more attempt")
    func rerunWithWrongPasswordHoldsAgain() async throws {
        let data = try Self.bytes("r4-aes-128.pdf")
        let doc = DocumentState()
        let redaction = RedactionState()
        let first = await ImportService.importDocument(
            data: data, door: .files, documentState: doc, redactionState: redaction)
        guard case .needsPassword(let hold) = first else { Issue.record("expected the hold"); return }
        #expect(doc.transition(to: ImportPasswordFlow.cancelPhase(returnPhase: hold.returnPhase)))
        let second = await ImportService.importDocument(
            data: hold.bytes, door: hold.door, password: "wrong", documentState: doc, redactionState: redaction)
        let step = ImportPasswordFlow.step(after: second, phaseError: nil, hold: hold)
        guard case .wrongPassword(let next) = step else { Issue.record("expected wrongPassword, got \(step)"); return }
        #expect(next.attempts == 1)
        #expect(next.id == hold.id)
        #expect(doc.phaseKind == .failed)
    }

    // MARK: - The failed card beneath the sheet

    @Test("The password refusal's card reads locked, in the warning colour")
    func passwordRefusalCardReadsLocked() {
        let error = PipelineError.importError(.passwordProtected)
        #expect(error.severitySymbol == "lock.fill")
        #expect(error.severityColor == ResectaTokens.SemanticColor.warnText)
        #expect(PipelineError.importError(.corrupt).severitySymbol == "xmark.circle.fill")
    }

    // MARK: - Helpers

    static func nonWhitePixels(_ page: PDFPage) -> Int {
        guard let ref = page.pageRef else { return -1 }
        let w = 120, h = 156
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            return -2
        }
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: CGFloat(w) / 612, y: CGFloat(h) / 792)
        ctx.drawPDFPage(ref)
        guard let buffer = ctx.data else { return -3 }
        let pixels = buffer.bindMemory(to: UInt8.self, capacity: w * h)
        return (0..<(w * h)).reduce(0) { $0 + (pixels[$1] < 250 ? 1 : 0) }
    }
}
