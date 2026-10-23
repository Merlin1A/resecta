import Testing
import Foundation
@testable import ResectaApp

// The accented-letter hint on the password sheet: the system reader can
// refuse a password holding a letter outside ASCII even when it is the
// right one, so a refusal of such a password says so beside the
// wrong-password line. The sheet keeps only whether the refused password
// held such a letter, never the password.

@Suite("Password sheet — the accented-letter hint")
struct ImportPasswordNonASCIIHintTests {

    @Test("A letter outside ASCII is detected; ASCII text, digits, symbols and spaces are not")
    func detectsNonASCIILetters() {
        #expect(ImportPasswordFlow.hasNonASCIILetter("pässwörd"))
        #expect(ImportPasswordFlow.hasNonASCIILetter("café"))
        #expect(ImportPasswordFlow.hasNonASCIILetter("密码"))
        #expect(!ImportPasswordFlow.hasNonASCIILetter("password"))
        #expect(!ImportPasswordFlow.hasNonASCIILetter("P@ss w0rd!"))
        #expect(!ImportPasswordFlow.hasNonASCIILetter("€100"), "a currency sign is not a letter")
        #expect(!ImportPasswordFlow.hasNonASCIILetter(""))
    }

    @Test("The hint shows only after a refusal of a password that held such a letter")
    func showsOnlyAfterANonASCIIRefusal() {
        #expect(ImportPasswordFlow.showsNonASCIIHint(lastOutcome: .wrongPassword, refusedHadNonASCIILetter: true))
        #expect(!ImportPasswordFlow.showsNonASCIIHint(lastOutcome: .wrongPassword, refusedHadNonASCIILetter: false))
        #expect(!ImportPasswordFlow.showsNonASCIIHint(lastOutcome: .awaiting, refusedHadNonASCIILetter: true))
        #expect(!ImportPasswordFlow.showsNonASCIIHint(lastOutcome: .cannotOpen, refusedHadNonASCIILetter: true))
    }

    @Test("The hint names the limit without a promise")
    func copy() {
        let hint = ImportPasswordFlow.nonASCIIHint
        #expect(hint == "A password with accented letters, such as ä or é, may not open this document in Resecta, even when it is correct.")
        for term in LegalPhrases.bannedTerms {
            #expect(!hint.lowercased().contains(term), "mechanism description, not a promise: '\(term)'")
        }
    }
}
