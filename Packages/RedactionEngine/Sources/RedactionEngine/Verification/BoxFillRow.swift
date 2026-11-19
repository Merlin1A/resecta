import CoreGraphics
import Foundation

/// The Box Fill row: what the box check established, read as today's row.
///
/// One pure function from the check's report and the run's record to the
/// row. A box that is not exactly the fill reads Needs Review on the pages
/// with one; a page whose picture could not be read, and a box that could
/// not be judged, read Could not verify, each with its own sentence and its
/// own pages, beside an issue or alone; a run with no record reads Skipped.
/// The boxes are taken from the record, not from the check's report, so a
/// box the report leaves out is a box that could not be checked, never a
/// box that passed. The check returns every refusal as a value, so nothing
/// here can read as a failed check.
enum BoxFillRow {
    /// The line under an issue: the check is new.
    static let newCheckLine = "This check is new and has not yet been shown to stay quiet on correct files."

    /// What the row reads as.
    enum Reading: Equatable, Sendable {
        /// The row, with the line under an issue when it has one.
        case row(CheckRow, LayerCopy?)
        /// No record of the run to check against.
        case skipped
    }

    /// The row for `report`, against the boxes and regions of `record`.
    static func reading(report: BoxCheckReport, record: RunRecord?) -> Reading {
        guard let record, case .pages(let pictures) = report else { return .skipped }
        var unreadPages: Set<Int> = []
        var notChecked: [Int] = []
        var found: [Int] = []
        for page in record.confirmed.pages {
            let index = page.pageIndex
            let picture = index < pictures.count ? pictures[index] : nil
            guard let picture, picture.picture == .completed else {
                unreadPages.insert(index)
                continue
            }
            let boxes = page.plan?.boxes ?? []
            for planIndex in boxes.indices {
                let outcome = planIndex < picture.boxes.count ? picture.boxes[planIndex] : nil
                switch outcome {
                case .completed?, .offPage?: break
                case .issue?: found.append(index)
                case .inconclusive?, .couldNotFinish?, nil: notChecked.append(index)
                }
            }
            for region in page.regions where !isCovered(region, on: page) {
                notChecked.append(index)
            }
        }
        var conditions: [UnverifiedCondition] = []
        if !unreadPages.isEmpty {
            let pages = unreadPages.sorted()
            conditions.append(UnverifiedCondition(sentence: unreadablePagesSentence(pages), pages: pages))
        }
        if !notChecked.isEmpty {
            conditions.append(UnverifiedCondition(sentence: notCheckedSentence(notChecked), pages: Array(Set(notChecked)).sorted()))
        }
        if !found.isEmpty {
            let sentence = findSentence(found)
            let row = CheckRowComposition.compose(
                issue: (.attention(sentence), Array(Set(found)).sorted()), conditions: conditions, warnings: [])
            return .row(row ?? CheckRow(status: .attention(sentence), pages: Array(Set(found)).sorted(), couldNotVerify: false),
                        LayerCopy(short: sentence, detail: newCheckLine))
        }
        if let row = CheckRowComposition.compose(issue: nil, conditions: conditions, warnings: []) {
            return .row(row, nil)
        }
        return .row(.passed, nil)
    }

    /// Whether a region as drawn is covered: it shares no area with its page
    /// on any side (the region is wholly off the page), or a box of the
    /// page's plan names it and its inner rectangle holds it. The test is
    /// made on the region as drawn, never through the clamp, which slides a
    /// region off the left or the bottom onto the page.
    static func isCovered(_ region: RunRecord.DrawnRegion, on page: RunRecord.Page) -> Bool {
        guard let plan = page.plan else { return false }
        let r = region.normalizedRect
        guard let drawn = PageRect64(
            share: PointRect(minX: Double(r.minX), minY: Double(r.minY), maxX: Double(r.maxX), maxY: Double(r.maxY)),
            widthSixtyFourths: plan.widthSixtyFourths, heightSixtyFourths: plan.heightSixtyFourths) else { return false }
        let sheet = PageRect64(minX: 0, minY: 0, maxX: plan.widthSixtyFourths, maxY: plan.heightSixtyFourths)
        if !drawn.sharesArea(with: sheet) { return true }
        return plan.boxes.contains { $0.regionIDs.contains(region.id) && $0.inner.contains(drawn) }
    }

    /// "A box on page 4 is not exactly the fill." · "3 boxes on pages 4 and 9 are not exactly the fill."
    static func findSentence(_ boxPages: [Int]) -> String {
        boxPages.count == 1
            ? "A box on page \(boxPages[0] + 1) is not exactly the fill."
            : "\(boxPages.count) boxes on \(pagesPhrase(boxPages)) are not exactly the fill."
    }

    /// "A box on page 4 could not be checked." · "3 boxes on pages 4 and 9 could not be checked."
    static func notCheckedSentence(_ boxPages: [Int]) -> String {
        boxPages.count == 1
            ? "A box on page \(boxPages[0] + 1) could not be checked."
            : "\(boxPages.count) boxes on \(pagesPhrase(boxPages)) could not be checked."
    }

    /// "page 4", "pages 4 and 9", "pages 4, 9 and 12": each page once, 1-based, in order.
    static func pagesPhrase(_ pages: [Int]) -> String {
        let numbers = Array(Set(pages)).sorted().map { String($0 + 1) }
        switch numbers.count {
        case 1: return "page \(numbers[0])"
        default: return "pages \(numbers.dropLast().joined(separator: ", ")) and \(numbers[numbers.count - 1])"
        }
    }
}
