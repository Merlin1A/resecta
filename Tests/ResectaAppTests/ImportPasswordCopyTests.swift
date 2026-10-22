import Testing
import Foundation
@testable import ResectaApp
@testable import RedactionEngine

// The copy of the password-locked import, pinned word for word: the engine's
// refusal line, the failed card's title and recovery, the sheet's strings,
// the encrypted-source toast and the Share-card caption. Each is
// mechanism-worded and names no document text.

@Suite("Import password copy", .tags(.importFlow))
struct ImportPasswordCopyTests {

    @Test("The engine's password refusal names the missing password")
    func engineRefusalLine() {
        #expect(PipelineError.importError(.passwordProtected).errorDescription
                == "This document needs a password to open, and none was entered.")
    }

    @Test("The failed card's title and recovery for a password refusal")
    func failedCardCopy() {
        let error = PipelineError.importError(.passwordProtected)
        #expect(error.localizedTitle == "Password-Protected Document")
        #expect(error.localizedRecovery
                == "The document was not opened because its password was not entered. Choose the file again to enter the password.")
    }

    @Test("The sheet's strings")
    func sheetStrings() {
        #expect(ImportPasswordFlow.title == "This document needs a password.")
        #expect(ImportPasswordFlow.body
                == "Enter the password to open it. The password is used on this device to unlock the document; Resecta does not store it. If iOS offers to save it, that offer is the system's own Passwords feature.")
        #expect(ImportPasswordFlow.placeholder == "Password")
        #expect(ImportPasswordFlow.fieldAccessibilityLabel == "Document password")
        #expect(ImportPasswordFlow.open == "Open")
        #expect(ImportPasswordFlow.cancel == "Cancel")
        #expect(ImportPasswordFlow.ok == "OK")
        #expect(ImportPasswordFlow.wrongPassword == "That password did not open the document.")
        #expect(ImportPasswordFlow.certificateHint
                == "A document protected by a certificate or by another app's protection scheme, rather than a password, does not open in Resecta.")
        #expect(ImportPasswordFlow.cannotOpen
                == "The password was accepted, but the document could not be read in full with it, so it was not opened.")
    }

    @Test("The encrypted-source toast: the restrictions line, the plain line, nothing for a plain source")
    func encryptedSourceToast() {
        #expect(RedactWorkspaceView.encryptedSourceToast(
            facts: ImportFacts.Summary(origin: .pdf, wasEncrypted: true, hadRestrictions: true))
            == "This PDF carries usage restrictions set with an owner password. The redacted copy is built without a password and without those restrictions.")
        #expect(RedactWorkspaceView.encryptedSourceToast(
            facts: ImportFacts.Summary(origin: .pdf, wasEncrypted: true, hadRestrictions: false))
            == "This PDF was password-protected. The redacted copy is built without a password.")
        #expect(RedactWorkspaceView.encryptedSourceToast(facts: ImportFacts.Summary()) == nil)
    }

    @Test("The Share-card caption")
    func shareCaption() {
        #expect(VerificationResultsView.notProtectedCaption(hadRestrictions: false)
                == "The redacted copy is not password-protected.")
        #expect(VerificationResultsView.notProtectedCaption(hadRestrictions: true)
                == "The redacted copy is not password-protected. It carries none of the original's usage restrictions.")
    }
}
