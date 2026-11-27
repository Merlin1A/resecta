import Testing
import Foundation
import RedactionEngine
@testable import ResectaApp

// The second number of the results screen: the ring, the summary line, the
// masthead's spoken label and the end-of-run announcement all count the
// checks that had something to check, and agree.

@Suite("The check count")
@MainActor
struct VerificationCheckCountTests {

    static var seeded: [(String, VerificationReport)] {
        VerificationDebugFixtures.all.filter { !$0.value.layers.isEmpty }.sorted { $0.key < $1.key }
    }

    /// Counted from each check's own outcome, not from the partition.
    static func checksWithSomethingToCheck(_ report: VerificationReport) -> Int {
        report.layers.filter {
            VerificationRowModel.outcome(for: $0, perPageModes: report.perPageModes) != .nothingToCheck
        }.count
    }

    static func ringNumbers(_ report: VerificationReport) -> (passed: Int, total: Int)? {
        if case let .count(passed, total, _) = VerificationMasthead.ringContent(report: report) {
            return (passed, total)
        }
        return nil
    }

    /// The "P of T check(s) passed" numbers in a sentence, or nil.
    static func countPair(in text: String) -> (Int, Int)? {
        guard let match = text.firstMatch(of: #/(\d+) of (\d+) checks? passed/#),
              let p = Int(match.1), let t = Int(match.2) else { return nil }
        return (p, t)
    }

    @Test("The ring counts only checks that had something to check")
    func ringCountsOnlyChecksThatHadSomethingToCheck() throws {
        var examined = 0
        for (name, report) in Self.seeded {
            let ring = try #require(Self.ringNumbers(report), "\(name): no count")
            let expected = Self.checksWithSomethingToCheck(report)
            #expect(ring.total == expected, "\(name)")
            #expect((CountRing.progress(passed: ring.passed, total: ring.total) == 1) == (ring.passed == expected),
                    "\(name): the arc is full exactly when every check with something to check passed")
            // The partition's own total still counts every check: another
            // reader decides something else from it.
            let partition = VerificationLayerPartition(layers: report.layers, perPageModes: report.perPageModes)
            #expect(partition.total == report.layers.count, "\(name)")
            examined += 1
        }
        #expect(examined == 16)
        // The seeded run with three checks that had nothing to check: full.
        let rasterized = try #require(Self.ringNumbers(VerificationDebugFixtures.searchableAllRasterized))
        #expect(rasterized.passed == 11 && rasterized.total == 11)
    }

    @Test("The second number is one number everywhere it is drawn or spoken")
    func secondNumberIsOneNumberEverywhere() throws {
        var examined = 0
        for (name, report) in Self.seeded {
            let ring = try #require(Self.ringNumbers(report), "\(name)")
            let partition = VerificationLayerPartition(layers: report.layers, perPageModes: report.perPageModes)
            let texts = [
                partition.summaryLine1,
                VerificationResultsView.detailsSummaryText(for: report),
                VerificationResultsView.mastheadAccessibilityLabel(report: report),
                VerificationResultsView.completionAnnouncement(report: report),
            ]
            for text in texts {
                let pair = try #require(Self.countPair(in: text), "\(name): no count in \(text)")
                #expect(pair.0 == ring.passed && pair.1 == ring.total, "\(name): \(text)")
            }
            examined += 1
        }
        #expect(examined == 16)
    }
}
