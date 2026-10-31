import Testing
import Foundation
@testable import RedactionEngine

// Text recognition on iOS 27 can read a space beside a separator inside a
// phone number: the sample statement's "1-800-555-0199" reads as
// "1-800- 555-0199" there, where iOS 26 read no space. The phone pattern
// takes one optional space on either side of a separator, so such a read
// is still a phone; a run the pattern did not match before (two separators,
// two spaces) still does not match.

@Suite("Phone: a space beside a separator")
struct PhoneSeparatorSpaceTests {

    private func phones(in text: String) -> [String] {
        let ns = text as NSString
        return PhoneDetector().detect(in: ns, range: NSRange(location: 0, length: ns.length)).map(\.text)
    }

    @Test("The iOS 27 read of the sample's service number is a phone")
    func iOS27ReadIsAPhone() {
        #expect(phones(in: "please call us at 1-800- 555-0199 so we can keep") == ["800- 555-0199"])
    }

    @Test("A space before or after a hyphen or dot is taken", arguments: [
        ("call 208 -555-0147", "208 -555-0147"),
        ("call 208- 555-0147", "208- 555-0147"),
        ("call 208.555 .0147", "208.555 .0147"),
        ("call (208) 555 -0147", "(208) 555 -0147"),
        ("call +1- 208-555-0147", "+1- 208-555-0147"),
    ])
    func spaceBesideASeparator(text: String, phone: String) {
        #expect(phones(in: text) == [phone])
    }

    @Test("The shapes read before keep their spans", arguments: [
        ("call 1-800-555-0199", "800-555-0199"),
        ("call (208) 555-0147", "(208) 555-0147"),
        ("call 208.555.0147", "208.555.0147"),
        ("call 208 555 0147", "208 555 0147"),
        ("call 2085550147", "2085550147"),
    ])
    func earlierShapesUnchanged(text: String, phone: String) {
        #expect(phones(in: text) == [phone])
    }

    @Test("Runs that were not phones are still not", arguments: [
        "call 208--555-0147",
        "call 208  555-0147",
        "call 208 - - 555-0147",
        "call 208-555-01478",
    ])
    func nonPhonesStayOut(text: String) {
        #expect(phones(in: text).isEmpty)
    }
}
