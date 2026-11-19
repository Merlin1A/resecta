import CoreGraphics
import Foundation

/// A Searchable page's text path: from the extracted entries to the list the
/// page records and writes, or to "a picture" with a reason. The rasterizer
/// calls it once. Its steps run in one order, each through a seam a test can
/// replace (`steps`): the fold, the filter, the alphabet marks and the paint
/// marks, the whole-word closure with the drawn-cell rule, and the record.
/// Every step that changes a letter of the hidden text runs before the
/// record; after it nothing adds, removes or changes a letter.
///
/// Two lists of rectangles come in, already in output-page points; the path
/// derives neither. The text-path rectangles: the filter, the layout's line
/// breaks (in the writer and in the drawn-cell rule), the record and the
/// page output's rectangles all read this one list, every kind but "under a
/// widened box", which only the position check reads. The painted
/// rectangles: read by the paint marks; the rasterizer passes none today.
enum PageTextPath {

    /// The path's steps. The default is the real step for each; a test
    /// replaces one, within `$steps.withValue`, to make it fault. The fold
    /// and the alphabet marks may also return nothing (nil), which the real
    /// steps never do: the page is then a picture, as when a step throws.
    /// Neither step has a time limit of its own.
    struct Steps: Sendable {
        var fold: @Sendable ([CharacterInfo]) throws -> [CharacterInfo]?
        var filter: @Sendable ([CharacterInfo], [CGRect]) async throws -> FilterResult
        var alphabetMarks: @Sendable ([CharacterInfo]) throws -> TextPathAlphabetMarks.Marks?
        /// The words the paint covers, by the page's one partition, from the
        /// survivors and the painted rectangles. Nothing while no painted
        /// rectangle is handed in.
        var paintMarks: @Sendable ([CharacterInfo], [CGRect]) throws -> Set<Int>

        static let live = Steps(
            fold: { TextPathFold.fold($0) },
            filter: { try await filterCharacters(characters: $0, redactionRects: $1) },
            alphabetMarks: { TextPathAlphabetMarks.marks($0) },
            paintMarks: { _, _ in [] })
    }

    @TaskLocal static var steps = Steps.live

    #if DEBUG
    /// Tests only, compiled out of a release build: true turns the closure
    /// over words the filter or the drawn-cell rule took a letter of off, so
    /// a test can make a leaking export for a check to report. Marked words
    /// (the alphabet and the paint) still leave whole.
    @TaskLocal static var wholeWordsOff = false
    #endif

    /// Whether a word that loses a letter leaves whole: always, but in a
    /// test that turns it off.
    static var wholeWords: Bool {
        #if DEBUG
        return !wholeWordsOff
        #else
        return true
        #endif
    }

    /// How the page ends.
    enum Outcome: Sendable {
        /// The list to record and write, its record, and the rectangles the
        /// writer's line assembly reads.
        case written(entries: [CharacterInfo], digest: PageFilterDigest, removalRects: [CGRect])
        /// The page is a picture, for this reason.
        case picture(TextLayerDetector.FallbackReason)
    }

    struct Result: Sendable {
        let outcome: Outcome
        /// The runs the alphabet rule left out: carried with either outcome,
        /// zero when the page is a picture for another reason.
        let runsLeftOut: Int
        /// Survivors the drawn-cell rule dropped.
        let drawnCellDropped: Int
        /// The written list's lines as the drawn-cell rule laid them out,
        /// for the writer; nil when the page is a picture.
        var hiddenTextLines: HiddenTextLines? = nil
    }

    static func run(
        entries: [CharacterInfo],
        frame: PageFrame,
        textPathRectangles: [TextPathRectangle],
        paintedRectangles: [CGRect],
        pageIndex: Int,
        safetyMargin: CGFloat = safetyMarginPoints
    ) async throws -> Result {
        let steps = Self.steps
        let rects = textPathRectangles.filter { $0.kind != .underWidenedBox }.map(\.rect)

        // A step that returns nothing writes no text: the page is a picture.
        guard let folded = try steps.fold(entries) else {
            return Result(outcome: .picture(.extractionFailed), runsLeftOut: 0, drawnCellDropped: 0)
        }
        let filtered = try await steps.filter(folded, rects)
        guard let alphabet = try steps.alphabetMarks(filtered.surviving) else {
            return Result(outcome: .picture(.extractionFailed), runsLeftOut: 0, drawnCellDropped: 0)
        }
        let painted = try steps.paintMarks(filtered.surviving, paintedRectangles)

        // The whole-word closure over every marked word and every word the
        // filter took a letter of, then the drawn-cell rule on what is left.
        // A word the rule takes a letter of leaves whole too, and the rule
        // runs again on the lines that changed, until nothing more leaves.
        let wholeWords = Self.wholeWords
        let filterTook = wholeWords ? wordsLosingALetter(before: folded, after: filtered.surviving) : []
        var current = closeOverMarkedWords(
            filtered, marked: alphabet.wordIndices.union(painted).union(filterTook))
        let shapes = rects.map {
            RegionShape(expandedBounds: $0.insetBy(dx: -safetyMargin, dy: -safetyMargin), bounds: $0)
        }
        var drawnCellDropped = 0
        var passes = 0
        var lines: HiddenTextLines? = nil
        while true {
            let pass = TextLayerReconstructor.validateSurvivors(
                current, regionShapes: shapes, frame: frame)
            drawnCellDropped += pass.dropped
            // A line the hidden text's faces cannot lay out leaves no text the
            // page can write: a picture with no searchable text left. A layout
            // that does not settle outside the regions is a fault.
            guard pass.laidOut else {
                return Result(outcome: .picture(.noWritableText), runsLeftOut: 0,
                              drawnCellDropped: drawnCellDropped)
            }
            guard pass.settled else {
                return Result(outcome: .picture(.extractionFailed), runsLeftOut: 0,
                              drawnCellDropped: drawnCellDropped)
            }
            let ruleTook = wholeWords
                ? wordsLosingALetter(before: current.surviving, after: pass.result.surviving) : []
            current = closeOverMarkedWords(pass.result, marked: ruleTook)
            // The pass that takes nothing laid out the survivors as they
            // stand: the writer draws its lines.
            if ruleTook.isEmpty { lines = pass.lines; break }
            passes += 1
            guard passes < TextLayerReconstructor.drawnCellRulePassLimit else {
                return Result(outcome: .picture(.extractionFailed), runsLeftOut: 0,
                              drawnCellDropped: drawnCellDropped)
            }
        }
        let validated = (result: current, dropped: drawnCellDropped, lines: lines)
        if validated.result.surviving.isEmpty, !alphabet.wordIndices.isEmpty,
           let reason = alphabet.reasonIfNoWordLeft {
            return Result(outcome: .picture(reason), runsLeftOut: alphabet.runsLeftOut,
                          drawnCellDropped: validated.dropped)
        }

        // The record.
        let digest = validated.result.toDigest(
            pageIndex: pageIndex,
            redactionRects: rects,
            safetyMargin: safetyMargin,
            drawnCellRuleExcludedCount: validated.dropped,
            frame: frame)
        return Result(
            outcome: .written(entries: validated.result.surviving, digest: digest, removalRects: rects),
            runsLeftOut: alphabet.runsLeftOut, drawnCellDropped: validated.dropped,
            hiddenTextLines: validated.lines)
    }

    /// The words that lost at least one letter between `before` and `after`
    /// (`after` a subset of `before`). White space is no letter of a word:
    /// a space that leaves takes no word with it.
    static func wordsLosingALetter(before: [CharacterInfo], after: [CharacterInfo]) -> Set<Int> {
        var count: [Int: Int] = [:]
        for entry in before where !SandwichMetrics.isLineageWhitespace(entry.character) {
            count[entry.wordIndex, default: 0] += 1
        }
        for entry in after where !SandwichMetrics.isLineageWhitespace(entry.character) {
            count[entry.wordIndex, default: 0] -= 1
        }
        return Set(count.filter { $0.value > 0 }.keys)
    }

    /// `result` with every survivor of a marked word left out, counted as
    /// excluded. With no word marked it is `result` itself.
    static func closeOverMarkedWords(_ result: FilterResult, marked: Set<Int>) -> FilterResult {
        guard !marked.isEmpty else { return result }
        let kept = result.surviving.filter { !marked.contains($0.wordIndex) }
        return FilterResult(
            surviving: kept, totalCharacters: result.totalCharacters,
            excludedCount: result.excludedCount + (result.surviving.count - kept.count))
    }
}
