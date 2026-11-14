import Testing
import Foundation
@testable import RedactionEngine

// `PIIDetector.emittedRuleIDs` against the detection sources and against a
// detection run: the ids the sources write as string literals are exactly
// the set, no source writes a reserved id, and a sample of every family
// yields only ids in the set.

@Suite("Emitted rule ids")
struct EmittedRuleIDTests {

    /// One place a source writes a rule id as a string literal.
    struct Site: CustomStringConvertible {
        let id: String
        let file: String
        let line: Int
        var description: String { "\(file):\(line) \"\(id)\"" }
    }

    /// The shapes a rule id is written in: `let ruleID = "…"`, a
    /// `ruleID: "…"` argument, a `static let …RuleID = "…"`, a pattern tuple
    /// `(Self.<pattern>, "…")`, and (read apart, below) an arm of
    /// `defaultRuleID(for:)`. An id written another way (built by
    /// interpolation, or looked up in a table) is not seen by the scan; the
    /// family test below is the guard for that.
    static let literalShapes: [NSRegularExpression] = [
        #"\blet ruleID = "([^"]*)""#,
        #"\bruleID: "([^"]*)""#,
        #"\bstatic let \w*RuleID = "([^"]*)""#,
        #"\(Self\.\w+, "([^"]*)"\)"#,
    ].map { try! NSRegularExpression(pattern: $0) }

    static let defaultArm = try! NSRegularExpression(pattern: #"case \.\w+:\s+"([^"]*)""#)

    /// Every literal rule-id site in the engine's sources, read from disk
    /// through this file's path (the package root is four levels up).
    static func scannedSites() throws -> [Site] {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // DetectionTests
            .deletingLastPathComponent()   // RedactionEngineTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // <package root>
            .appendingPathComponent("Sources/RedactionEngine")
        let walk = try #require(
            FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil),
            "the engine's sources are not readable from the package root"
        )
        var sites: [Site] = []
        for case let url as URL in walk where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8) as NSString
            func record(_ regex: NSRegularExpression, in range: NSRange) {
                for match in regex.matches(in: text as String, range: range) {
                    let before = text.substring(to: match.range.location)
                    sites.append(Site(
                        id: text.substring(with: match.range(at: 1)),
                        file: url.lastPathComponent,
                        line: before.components(separatedBy: "\n").count
                    ))
                }
            }
            for regex in literalShapes {
                record(regex, in: NSRange(location: 0, length: text.length))
            }
            let head = text.range(of: "func defaultRuleID(")
            if head.location != NSNotFound {
                let rest = NSRange(location: head.location, length: text.length - head.location)
                let end = text.range(of: "\n    }\n", range: rest)
                let body = NSRange(
                    location: head.location,
                    length: (end.location == NSNotFound ? text.length : end.location) - head.location
                )
                record(defaultArm, in: body)
            }
        }
        return sites
    }

    @Test("The ids the detection sources write are exactly the emitted set")
    func sourcesWriteExactlyTheEmittedSet() throws {
        let sites = try Self.scannedSites()
        let written = Set(sites.map(\.id).filter { !$0.isEmpty })
        #expect(written.count >= 25, "the scan found only \(written.count) ids: \(written.sorted())")
        let notInSet = written.subtracting(PIIDetector.emittedRuleIDs)
        #expect(notInSet.isEmpty,
                "written in the sources but not in emittedRuleIDs: \(sites.filter { notInSet.contains($0.id) })")
        let notWritten = PIIDetector.emittedRuleIDs.subtracting(written)
        #expect(notWritten.isEmpty, "in emittedRuleIDs but written nowhere in the sources: \(notWritten.sorted())")
        // One site gives an overlap loser with no rationale the empty id; it is
        // in neither set, and a second such site would be new.
        let empty = sites.filter { $0.id.isEmpty }
        #expect(empty.count == 1, "empty rule ids: \(empty)")
        #expect(empty.first?.file == "DetectionOrchestrator+OverlapResolution.swift", "empty rule ids: \(empty)")
    }

    @Test("No detection source writes a reserved id, and no id is both reserved and emitted")
    func noSourceWritesAReservedID() throws {
        let sites = try Self.scannedSites()
        #expect(!PIIDetector.reservedRuleIDs.isEmpty)
        let reservedWritten = sites.filter { PIIDetector.reservedRuleIDs.contains($0.id) }
        #expect(reservedWritten.isEmpty, "reserved ids written in the sources: \(reservedWritten)")
        let both = PIIDetector.reservedRuleIDs.intersection(PIIDetector.emittedRuleIDs)
        #expect(both.isEmpty, "both reserved and emitted: \(both.sorted())")
    }

    /// One sample per family, each from that detector's own tests.
    static let samples: [(PIICategory, String)] = [
        (.ssn, "SSN: 123-45-6789 on file."),
        (.creditCard, "Card: 4111-1111-1111-1111"),
        (.email, "Contact: jane@example.com for scheduling."),
        (.phone, "Phone: (555) 123-4567"),
        (.ein, "EIN: 12-3456789 for the company"),
        (.address, "Plaintiff resides at 123 Main Street, Springfield, IL 62701"),
        (.dateOfBirth, "Patient DOB: 03/15/1985 was admitted"),
        (.itin, "ITIN: 912-80-5678 individual taxpayer identification"),
        (.driversLicense, "DL: A1234567"),
        (.passport, "Passport: AB123456"),
        (.medicalRecord, "MRN: 12345678 in a free-floating note."),
        (.npi, "Provider NPI 1455395883 billed today"),
        (.dea, "DEA Number: AB1234563"),
        (.account, "Account: 123456789 transferred today"),
        (.routingNumber, "ABA routing 021000021"),
        (.licensePlate, "License plate: 3ABC123 observed."),
        (.name, "PLAINTIFF: Marcus Bellamy"),
    ]

    @Test("A sample of every family yields matches whose rule ids are all emitted")
    func everyFamilyYieldsEmittedIDs() async {
        #expect(PIICategory.allCases.count == 17)
        #expect(Self.samples.count == PIICategory.allCases.count)
        #expect(Set(Self.samples.map(\.0)) == Set(PIICategory.allCases))
        let detector = PIIDetector()
        var familiesMatched = Set<PIICategory>()
        for (category, text) in Self.samples {
            let matches = await detector.detect(in: text)
            if matches.contains(where: { $0.kind == category.piiKind }) {
                familiesMatched.insert(category)
            } else {
                Issue.record("no \(category) match on \"\(text)\"; kinds found: \(matches.map(\.kind))")
            }
            for match in matches {
                let id = match.rationale?.ruleID
                #expect(id.map(PIIDetector.emittedRuleIDs.contains) == true,
                        "\(match.kind) on \"\(text)\" carries rule id \(String(describing: id)), not in emittedRuleIDs")
            }
        }
        #expect(familiesMatched.count == 17)
    }
}
