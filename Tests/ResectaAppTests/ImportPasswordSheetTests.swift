import Testing
import Foundation
@testable import ResectaApp
@testable import RedactionEngine

// The password sheet's three arms as pure derivations: the wrong password
// keeps the hold and counts the attempt, the hint from the third attempt,
// the unlocked-but-unreadable document's terminal line, another refusal
// releasing the hold, and Cancel's derived transition.

@Suite("Import password sheet flow", .tags(.importFlow))
struct ImportPasswordSheetTests {

    private func hold(returnPhase: DocumentState.ReturnPhase = .empty) -> LockedImportHold {
        LockedImportHold(bytes: Data([0x25, 0x50, 0x44, 0x46]), declaredType: "pdf", door: .files, returnPhase: returnPhase)
    }

    @Test("The document opening dismisses the sheet")
    func openedDismisses() {
        #expect(ImportPasswordFlow.step(after: .completed, phaseError: nil, hold: hold()) == .opened)
    }

    @Test("A wrong password keeps the hold, counts the attempt and marks the outcome")
    func wrongPasswordKeepsTheHold() {
        let first = hold()
        guard case .wrongPassword(let next) = ImportPasswordFlow.step(after: .needsPassword(first), phaseError: nil, hold: first) else {
            Issue.record("expected wrongPassword"); return
        }
        #expect(next.id == first.id)
        #expect(next.attempts == 1)
        #expect(next.lastOutcome == .wrongPassword)
        #expect(next.bytes == first.bytes)
        guard case .wrongPassword(let third) = ImportPasswordFlow.step(after: .needsPassword(next), phaseError: nil, hold: next) else {
            Issue.record("expected wrongPassword"); return
        }
        #expect(third.attempts == 2)
    }

    @Test("The certificate hint shows from the third wrong attempt")
    func certificateHintFromTheThirdAttempt() {
        #expect(!ImportPasswordFlow.showsCertificateHint(attempts: 0))
        #expect(!ImportPasswordFlow.showsCertificateHint(attempts: 2))
        #expect(ImportPasswordFlow.showsCertificateHint(attempts: 3))
        #expect(ImportPasswordFlow.showsCertificateHint(attempts: 7))
    }

    @Test("A document the password unlocked but that could not be read in full reaches the terminal line")
    func cannotOpenIsTerminal() {
        let first = hold()
        guard case .cannotOpen(let next) = ImportPasswordFlow.step(
            after: .refused, phaseError: .importError(.corrupt), hold: first) else {
            Issue.record("expected cannotOpen"); return
        }
        #expect(next.lastOutcome == .cannotOpen)
        #expect(next.id == first.id)
    }

    @Test("Any other refusal of the unlocked document releases the hold")
    func otherRefusalsReleaseTheHold() {
        for error in [
            PipelineError.importError(.activeContent(location: .openAction)),
            .importError(.tooLarge(bytesRead: 1)),
            .importError(.invalidPageDimensions(pageIndex: 0)),
            .redactionError(.unsupportedPageGeometry(pageIndex: 0)),
        ] {
            #expect(ImportPasswordFlow.step(after: .refused, phaseError: error, hold: hold()) == .refusedForAnotherReason)
        }
        #expect(ImportPasswordFlow.step(after: .refused, phaseError: nil, hold: hold()) == .refusedForAnotherReason)
    }

    @Test("Cancel derives the failed card's own transition: Home's import returns to empty, a drop to the editor")
    func cancelDerivesTheTransition() {
        if case .empty = ImportPasswordFlow.cancelPhase(returnPhase: .empty) {} else {
            Issue.record("expected empty")
        }
        if case .editing = ImportPasswordFlow.cancelPhase(returnPhase: .editing) {} else {
            Issue.record("expected editing")
        }
    }

    @Test("The hold is identified by its id, not its attempts")
    func holdIdentity() {
        let first = hold()
        var next = first
        next.attempts = 2
        #expect(first == next)
        #expect(hold() != first)
    }
}
