import Testing
import Foundation
@testable import RedactionEngine

// Route 4 of the label anchors: the salutation and the subject line. `Dear`
// at a line's start is followed by the addressee, closed by a comma or a
// colon; a generic addressee (`Dear Sir or Madam,`) is not a name. A subject
// line (`Re:` / `Subject:` / `Regarding:`) yields the two-to-three-token run
// that closes it when a lower-case word stands right before that run; a
// subject in title case throughout is a title and yields nothing.
//
// Deterministic: drives `scanLabelAnchors` on its own, apart from the tagger
// rows that win the overlap inside `detectNames`.
//
// Synthetic Hartwell/Sablebrook cast only (repo test-data policy).
//
// Privacy rule (audit-lint M-1): comments and test names use
// locate/surface/resolve vocabulary.

@Suite("Label anchor routes: salutation and subject line")
struct LabelAnchorSalutationSubjectTests {

    private static func route(_ name: String, in text: String) -> [PIIDetector.PIIMatch] {
        PIIDetector().families.name.scanLabelAnchors(in: text).filter { match in
            match.rationale?.signals.contains(.regexPattern(name: "name.label-anchor.\(name)")) == true
        }
    }

    // MARK: - Route 4a: the salutation

    @Test("Dear followed by the addressee and a comma or colon surfaces the addressee")
    func dearSurfacesTheAddressee() {
        #expect(Self.route("salutation", in: "Dear Delia Hartwell,").map(\.text) == ["Delia Hartwell"])
        #expect(Self.route("salutation", in: "Dear Delia Hartwell:").map(\.text) == ["Delia Hartwell"])
        #expect(Self.route("salutation", in: "Dear Delia,").map(\.text) == ["Delia"])
        #expect(Self.route("salutation", in: "  DEAR DELIA HARTWELL,\nThank you for writing.").map(\.text) == ["DELIA HARTWELL"])
        #expect(Self.route("salutation", in: "Dear Delia Hartwell").map(\.text) == ["Delia Hartwell"])
    }

    @Test("A generic addressee, an honorific-led addressee or an organisation is not read")
    func genericHonorificOrOrganisationIsNotRead() {
        for text in ["Dear Sir,", "Dear Madam:", "Dear Sir or Madam,", "Dear Valued Customer,", "Dear Hiring Manager,",
                     "Dear Team,", "Dear Colleagues,", "Dear Patient,", "Dear Counsel:"] {
            #expect(Self.route("salutation", in: text).isEmpty, "in \(text.debugDescription)")
        }
        // The honorific-led shape belongs to the prefix pass.
        #expect(Self.route("salutation", in: "Dear Ms. Hartwell,").isEmpty)
        #expect(Self.route("salutation", in: "Dear Dr. Delia Hartwell:").isEmpty)
        #expect(Self.route("salutation", in: "Dear Sablebrook Holdings Inc.,").isEmpty)
    }

    @Test("Dear inside a sentence, or followed by prose, is not a salutation")
    func dearInsideASentenceIsNotASalutation() {
        #expect(Self.route("salutation", in: "It was dear to Delia Hartwell,").isEmpty)
        #expect(Self.route("salutation", in: "Dear Delia Hartwell wrote back at once.").isEmpty)
        #expect(Self.route("salutation", in: "Dearest Delia Hartwell,").isEmpty)
        #expect(Self.route("salutation", in: "Dear [REDACTED],").isEmpty)
    }

    // MARK: - Route 4b: the subject line

    @Test("The run that closes a subject line after a lower-case word is the name")
    func runClosingTheSubjectLineIsTheName() {
        #expect(Self.route("subject-line", in: "Re: Records pertaining to Delia Hartwell").map(\.text) == ["Delia Hartwell"])
        #expect(Self.route("subject-line", in: "RE: Records pertaining to Delia Hartwell.").map(\.text) == ["Delia Hartwell"])
        #expect(Self.route("subject-line", in: "Subject: Claim filed by Marcus J. Bellamy").map(\.text) == ["Marcus J. Bellamy"])
        #expect(Self.route("subject-line", in: "Regarding: the account of Delia Hartwell, Esq.").isEmpty)
    }

    @Test("A subject in title case, an organisation, a single token or no label yields nothing")
    func titleCaseOrganisationSingleTokenOrNoLabelYieldsNothing() {
        #expect(Self.route("subject-line", in: "Re: Motion To Dismiss").isEmpty)
        #expect(Self.route("subject-line", in: "Re: Delia Hartwell").isEmpty)
        #expect(Self.route("subject-line", in: "Re: Records pertaining to Sablebrook Holdings Inc.").isEmpty)
        #expect(Self.route("subject-line", in: "Re: Records pertaining to Hartwell").isEmpty)
        #expect(Self.route("subject-line", in: "Records pertaining to Delia Hartwell").isEmpty)
        #expect(Self.route("subject-line", in: "Re: Records pertaining to Delia Hartwell dated last week").isEmpty)
        #expect(Self.route("subject-line", in: "Reply: sent to Delia Hartwell").isEmpty)
    }

    @Test("The subject reading stays on its own line")
    func subjectReadingStaysOnItsOwnLine() {
        let text = "Re: Records pertaining to Delia Hartwell\nMarcus Bellamy attended."
        #expect(Self.route("subject-line", in: text).map(\.text) == ["Delia Hartwell"])
    }
}
