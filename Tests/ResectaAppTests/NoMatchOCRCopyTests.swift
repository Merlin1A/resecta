import Testing
import Foundation
import RedactionEngine
@testable import ResectaApp

// The no-match copy when the run read pages by text recognition. A
// no-match over an OCR page is not a statement about that page: Vision
// can misread a name or drop punctuation, and the misread word does not
// match. The four no-match branches say what was searched and point at
// the page itself; a run that read no page by OCR keeps today's copy.

@Suite("No-match copy on pages read by text recognition", .tags(.search))
@MainActor
struct NoMatchOCRCopyTests {

    static let noMatchContexts: [SearchEmptyStateCopy.EmptyContext] = [
        .textNoMatch, .regexNoMatch, .multiTermNoMatch, .multiTermNoMatchConjunction,
    ]

    // MARK: - The copy

    @Test("A text no-match over OCR pages names the pages and the recourse")
    func textNoMatchQualified() {
        #expect(SearchEmptyStateCopy.description(for: .textNoMatch, ocrReadPages: 2)
            == "No matches in the text Resecta could read. 2 pages were read by text recognition, and a misread word won't match. Check those pages by eye, or search a shorter part of the term.")
    }

    @Test("One OCR page reads in the singular")
    func singularPage() {
        #expect(SearchEmptyStateCopy.description(for: .textNoMatch, ocrReadPages: 1)
            == "No matches in the text Resecta could read. 1 page was read by text recognition, and a misread word won't match. Check those pages by eye, or search a shorter part of the term.")
    }

    @Test("The regex and multi-term no-matches carry the same line with their own recourse")
    func otherNoMatchesQualified() {
        #expect(SearchEmptyStateCopy.description(for: .regexNoMatch, ocrReadPages: 3)
            == "The active pattern produced no matches in the text Resecta could read. 3 pages were read by text recognition, and a misread word won't match. Check those pages by eye, or loosen the pattern.")
        #expect(SearchEmptyStateCopy.description(for: .multiTermNoMatch, ocrReadPages: 3)
            == "No matches for any of the active terms in the text Resecta could read. 3 pages were read by text recognition, and a misread word won't match. Check those pages by eye, or search a shorter part of a term.")
        #expect(SearchEmptyStateCopy.description(for: .multiTermNoMatchConjunction, ocrReadPages: 3)
            == "No page contains all of the active terms together in the text Resecta could read. 3 pages were read by text recognition, and a misread word won't match. Check those pages by eye, or turn off \"All terms must match\" to see per-term occurrences.")
    }

    @Test("A run that read no page by OCR keeps today's no-match copy")
    func textLayerOnlyUnchanged() {
        for context in Self.noMatchContexts {
            #expect(SearchEmptyStateCopy.description(for: context, ocrReadPages: 0)
                == SearchEmptyStateCopy.description(for: context))
        }
        #expect(SearchEmptyStateCopy.description(for: .textNoMatch)
            == "No occurrences in the document for the active query. Try a broader term or change the search options.")
    }

    @Test("Only the no-match branches read the OCR count")
    func otherBranchesIgnoreTheCount() {
        let others: [SearchEmptyStateCopy.EmptyContext] = [
            .textPreSearch, .textNotRun, .regexPreSearch, .regexNotRun,
            .multiTermPreSearchNoRecents, .multiTermPreSearchWithRecents, .multiTermNotRun,
            .piiScanPreScan, .piiScanStartFailed,
            .piiScanPostScanZero(detectorCount: 5),
            .piiScanCancelled(pagesScanned: 3, pageCount: 12),
        ]
        for context in others {
            #expect(SearchEmptyStateCopy.description(for: context, ocrReadPages: 4)
                == SearchEmptyStateCopy.description(for: context))
        }
    }

    @Test("The qualified copy carries no audit-lint-forbidden phrase and no content verdict")
    func qualifiedCopyIsMechanismOnly() {
        // Split so the test source itself does not trip the pre-commit hook.
        let forbidden = [
            "guarant" + "ee", "ensur" + "e", "impossi" + "ble", "perfect" + "ly",
            "fin" + "d", "cat" + "ch", "no occurrences in the document", "not in the document",
        ]
        for context in Self.noMatchContexts {
            let copy = SearchEmptyStateCopy.description(for: context, ocrReadPages: 2).lowercased()
            for phrase in forbidden {
                #expect(!copy.contains(phrase), "'\(phrase)' in: \(copy)")
            }
        }
    }

    // MARK: - The count

    @Test("The count is the pages Search sends to OCR, with Include OCR on, for a typed run")
    func ocrReadPageCount() {
        let mixed: [Int: TextLayerStatus] = [0: .rich, 1: .none, 2: .sparse, 3: .rich]
        #expect(SearchEmptyStateCopy.ocrReadPageCount(mixed, includeOCR: true, isScan: false) == 2)
        #expect(SearchEmptyStateCopy.ocrReadPageCount([0: .rich, 1: .rich], includeOCR: true, isScan: false) == 0)
        // A page absent from the map takes the text-layer path.
        #expect(SearchEmptyStateCopy.ocrReadPageCount([:], includeOCR: true, isScan: false) == 0)
        // OCR off reads no page by OCR (the not-analysed toast covers it).
        #expect(SearchEmptyStateCopy.ocrReadPageCount(mixed, includeOCR: false, isScan: false) == 0)
        // A Scan has its own zero-result copy.
        #expect(SearchEmptyStateCopy.ocrReadPageCount(mixed, includeOCR: true, isScan: true) == 0)
    }

    @Test("The empty state renders the run's kickoff count, and the run sets it from the routing snapshot")
    func sourceWiring() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let section = try String(contentsOf: root.appendingPathComponent(
            "Sources/ResectaApp/Views/Search/SearchResultsSection.swift"), encoding: .utf8)
        #expect(section.contains("description(for: context, ocrReadPages: searchState.lastRunOCRPageCount)"))
        let trigger = try String(contentsOf: root.appendingPathComponent(
            "Sources/ResectaApp/Views/Search/SearchAndRedactSheet+Trigger.swift"), encoding: .utf8)
        #expect(trigger.contains("searchState.lastRunOCRPageCount = SearchEmptyStateCopy.ocrReadPageCount("))
        #expect(trigger.contains("textLayerStatus, includeOCR: searchState.options.includeOCR, isScan: isPIIScan)"))
    }
}
