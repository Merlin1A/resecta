import Foundation
import RedactionEngine

// The results screen's lines about what the run made and what it did not
// read before Redact. Each is a pinned builder of facts recorded with the
// output on screen (`RedactionState.LastRunInputs`) or of the report shown,
// so a later search, box or file change cannot move what they say about it.

extension RedactStop {
    /// The pages the stop at Redact names across its units, as page indices,
    /// before any is answered: a page is counted once however many reasons
    /// or texts name it, and an answered page still counts, since it was not
    /// searched in full before Redact whatever the answer.
    static func pagesNotSearchedInFull(runs: [Run]) -> Set<Int> {
        Set(namedPages(runs: runs, answered: []).map(\.page))
    }

    /// The pages whose only gap is small pictures in some unit's account,
    /// joined as the stop joins its runs: a page a later run read in full is
    /// not among them. A page can also be one the stop names for another unit.
    static func smallPicturePages(runs: [Run]) -> Set<Int> {
        var pages = Set<Int>()
        for unit in units(of: runs) {
            guard let account = account(for: unit, in: runs) else { continue }
            pages.formUnion(account.quietPages)
        }
        return pages
    }
}

extension VerificationResultsView.RunFactsStrip {
    /// The boxes the run burned. Every box counts, one or many to a page.
    static func boxesLine(count: Int) -> String {
        count == 1
            ? "1 box can still show how long its text is."
            : "\(count) boxes can still show how long their text is."
    }

    /// The run line that opens What Boxes Can Show: the boxes line, when it
    /// shows.
    static func doorLine(for facts: VerificationResultsView.RunFacts) -> String? {
        facts.burnedBoxes > 0 ? boxesLine(count: facts.burnedBoxes) : nil
    }

    /// The spoken hint on the link row that opens the page.
    static var doorHint: String { "Opens \(LegalDocument.whatBoxesCanShow.title)." }

    /// The output's size, as the Files app gives a file's size.
    static func sizeLine(bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return "This PDF is \(formatter.string(fromByteCount: bytes))."
    }

    /// The run's page count past which a long image-only PDF is named.
    static let longImageOnlyPageCount = 80

    /// A Secure Rasterization output of more than `longImageOnlyPageCount` pages.
    static func longImageOnlyLine(pages: Int) -> String {
        "This PDF has \(pages) pages and no text, so an AI assistant that reads only the text of a PDF this long will read nothing of it."
    }

    /// The pages the stop at Redact named.
    static func notSearchedInFullLine(pages: Int) -> String {
        pages == 1
            ? "Before Redact, 1 page was not searched in full."
            : "Before Redact, \(pages) pages were not searched in full."
    }

    /// The pages whose only gap is small pictures.
    static func smallPicturesLine(pages: Int) -> String {
        let lead = pages == 1
            ? "Small pictures on 1 page, such as logos and stamps, were not searched."
            : "Small pictures on \(pages) pages, such as logos and stamps, were not searched."
        return lead + " A name inside a logo or stamp is not found."
    }

    /// What the checks ran on after Redact, by the output's page count.
    static func checksRanLine(pages: Int) -> String {
        switch pages {
        case 1: "The checks then ran on the page, looking for your boxed text."
        case 2: "The checks then ran on both pages, looking for your boxed text."
        default: "The checks then ran on all \(pages) pages, looking for your boxed text."
        }
    }

    /// Whether the report shows every check ran to its end with no issue: at
    /// least one row, every row passed, a note or not applicable, and none
    /// skipped, unable to read part of its input, or stopped early. A Stop
    /// during the checks, checks turned off and a re-check with rows skipped
    /// all read false.
    static func checksRanToTheEnd(_ report: VerificationReport) -> Bool {
        !report.layers.isEmpty && report.layers.allSatisfy { layer in
            switch layer.status {
            case .pass, .info, .notApplicable:
                !layer.couldNotVerify && layer.couldNotVerifyPart == nil && layer.stopped == nil
            case .warn, .attention, .fail, .skipped:
                false
            }
        }
    }

    /// The lines about what was not read before Redact: the named pages, the
    /// small pictures, then what the checks ran on, which follows one of the
    /// first two and needs a report whose checks ran to the end.
    static func unreadLines(for facts: VerificationResultsView.RunFacts, report: VerificationReport?) -> [String] {
        var result: [String] = []
        if !facts.pagesNotSearchedInFull.isEmpty {
            result.append(notSearchedInFullLine(pages: facts.pagesNotSearchedInFull.count))
        }
        if !facts.smallPicturePages.isEmpty {
            result.append(smallPicturesLine(pages: facts.smallPicturePages.count))
        }
        if !result.isEmpty, facts.pageCount > 0, let report, checksRanToTheEnd(report) {
            result.append(checksRanLine(pages: facts.pageCount))
        }
        return result
    }
}

extension ResultsScopeNote {
    /// The sentences beside Checks Passed. Their gate is the note's own, and
    /// they speak of this PDF, so they need the output on disk.
    static func checksPassedSentences(outputExists: Bool) -> [String] {
        guard outputExists else { return [] }
        return [
            "Checks Passed means no check reported your boxed text in this PDF.",
            "In this version the checks do not show that they read every part of the file.",
            "What remains can still identify someone.",
        ]
    }
}
