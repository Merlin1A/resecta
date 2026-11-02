import Testing
import Foundation
@testable import RedactionEngine

// Text recognition on iOS 27 can read a space beside a separator inside a
// phone number: the sample statement's "1-800-555-0199" reads as
// "1-800- 555-0199" there, where iOS 26 read no space. On iOS 27 the phone
// pattern takes one optional space on either side of a separator, so such a
// read is still a phone; a run the pattern did not match before (two
// separators, two spaces) still does not match. Before iOS 27 the pattern is
// the 1.3.0 one, character for character.

@Suite("Phone: a space beside a separator")
struct PhoneSeparatorSpaceTests {

    /// The phone pattern as 1.3.0 shipped it.
    static let shippedPattern = #"(?<!\d)(?:\+1[\s.-]?)?(?:\(\d{3}\)[\s.-]?\d{3}[\s.-]?\d{4}|\d{3}\)[\s.-]\d{3}[\s.-]?\d{4}|\d{3}[\s.-]?\d{3}[\s.-]?\d{4})(?!\d)"#

    private func phones(in text: String) -> [String] {
        let ns = text as NSString
        return PhoneDetector().detect(in: ns, range: NSRange(location: 0, length: ns.length)).map(\.text)
    }

    @Test("The space-tolerant pattern is used on iOS 27 only; before it, the 1.3.0 pattern")
    func gatedToIOS27() {
        if #available(iOS 27, *) {
            #expect(PhoneDetector.toleratesSeparatorSpaces)
            #expect(PhoneDetector.phonePattern.pattern != Self.shippedPattern)
        } else {
            #expect(!PhoneDetector.toleratesSeparatorSpaces)
            #expect(PhoneDetector.phonePattern.pattern == Self.shippedPattern)
        }
        #expect(PhoneDetector.shippedPhonePattern.pattern == Self.shippedPattern)
    }

    @Test("The iOS 27 read of the sample's service number is a phone on iOS 27")
    func iOS27ReadIsAPhone() {
        #expect(phones(in: "please call us at 1-800- 555-0199 so we can keep")
                == (PhoneDetector.toleratesSeparatorSpaces ? ["800- 555-0199"] : []))
    }

    @Test("A space before or after a hyphen or dot is taken on iOS 27",
          .enabled(if: PhoneDetector.toleratesSeparatorSpaces, "iOS 26 keeps the 1.3.0 pattern (gatedToIOS27)"),
          arguments: [
        ("call 208 -555-0147", "208 -555-0147"),
        ("call 208- 555-0147", "208- 555-0147"),
        ("call 208.555 .0147", "208.555 .0147"),
        ("call (208) 555 -0147", "(208) 555 -0147"),
        ("call +1- 208-555-0147", "+1- 208-555-0147"),
    ])
    func spaceBesideASeparator(text: String, phone: String) {
        #expect(phones(in: text) == [phone])
    }

    @Test("A spaced separator run is a candidate on iOS 27 and not before it")
    func spacedRunGated() {
        let tolerant = PhoneDetector.separatorSpacePhonePattern
        let shipped = PhoneDetector.shippedPhonePattern
        for text in ["call 100 - 200 - 3000", "call 100 -200 -3000"] {
            let range = NSRange(location: 0, length: (text as NSString).length)
            #expect(tolerant.numberOfMatches(in: text, range: range) == 1, "\(text)")
            #expect(shipped.numberOfMatches(in: text, range: range) == 0, "\(text)")
            #expect(phones(in: text).count == (PhoneDetector.toleratesSeparatorSpaces ? 1 : 0), "\(text)")
        }
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
