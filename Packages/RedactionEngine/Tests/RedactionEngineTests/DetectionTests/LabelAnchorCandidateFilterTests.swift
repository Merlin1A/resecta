import Testing
import Foundation
@testable import RedactionEngine

// The candidate filter every label-anchor route shares: a two-to-three-token
// capitalised run is a person's name only if none of its tokens is a role
// noun, an honorific, a generic addressee or an organisation word — on ANY
// token, not only the first. `Records Officer` after `Dear`, `Determination
// Unit` after `Sincerely,` and `Hiring Committee` are titles, not names.
//
// Deterministic: drives `scanLabelAnchors` on its own.
//
// Synthetic Hartwell/Sablebrook cast only (repo test-data policy).
//
// Privacy rule (audit-lint M-1): comments and test names use
// locate/surface/resolve vocabulary.

@Suite("Label anchor routes: the candidate filter reads every token")
struct LabelAnchorCandidateFilterTests {

    private static func anchors(in text: String) -> [PIIDetector.PIIMatch] {
        PIIDetector().families.name.scanLabelAnchors(in: text)
    }

    @Test("A role word on any token makes the candidate a title, not a name")
    func roleWordOnAnyTokenIsATitle() {
        #expect(Self.anchors(in: "Dear Records Officer,").isEmpty)
        #expect(Self.anchors(in: "Dear Hiring Committee,").isEmpty)
        #expect(Self.anchors(in: "PLAINTIFF: Records Officer").isEmpty)
        #expect(Self.anchors(in: "Sincerely,\nSenior Patient Advocate").isEmpty)
        #expect(Self.anchors(in: "Delia Hartwell v. Records Officer").map(\.text) == ["Delia Hartwell"])
    }

    @Test("An organisation-structure noun on any token makes the candidate an organisation")
    func structureNounOnAnyTokenIsAnOrganisation() {
        #expect(Self.anchors(in: "Sincerely,\nDetermination Unit, Regional Processing Center").isEmpty)
        #expect(Self.anchors(in: "Regards,\nClaims Division").isEmpty)
        #expect(Self.anchors(in: "Bill to: Sablebrook Program Office").isEmpty)
        #expect(Self.anchors(in: "From: Compliance Team").isEmpty)
    }

    @Test("A name stays a name: the filter reads role and organisation words only")
    func namesStillRead() {
        #expect(Self.anchors(in: "Dear Delia Hartwell,").map(\.text) == ["Delia Hartwell"])
        #expect(Self.anchors(in: "Sincerely,\nMarcus Bellamy").map(\.text) == ["Marcus Bellamy"])
        #expect(Self.anchors(in: "PLAINTIFF: Delia J. Hartwell-Bellamy").map(\.text) == ["Delia J. Hartwell-Bellamy"])
    }
}
