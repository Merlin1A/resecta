#if DEBUG
import Foundation
import PDFKit
import RedactionEngine

/// The debug launch arguments that seed one state of the results screen
/// each, read beside `--seedVerifiedReport=<name>` by the launch hook in
/// `ResectaApp`. Each seeds exactly one fact; without `--seedVerifiedReport`
/// none of them does anything, and with none of them present the launch is
/// the hook's own. A malformed value seeds nothing and leaves the rest of
/// the launch as it is.
///
/// - `--seedHandBoxes=<n>`: the run's inputs record `n` hand-drawn boxes on
///   page 1 with no text under them.
/// - `--seedFormValues=<n>`: the document carries `n` filled form fields.
/// - `--seedCoveredText`: page 1 of the loaded document gains, in memory, an
///   opaque square annotation over a line of its text, with no box over it.
/// - `--seedLeft=<k>/<total>`: the run's inputs carry `k` of `total`
///   detected items left unredacted (`k` from 1 to `total`).
/// - `--seedAppliedSearch=typed` or `=scan`: the run's inputs carry one
///   applied search of that kind.
/// - `--seedBoxesChanged`: one small box is added through the editor's own
///   state before the seeded PDF (`--seedOutput`) is registered, so the box
///   is one the PDF does not carry.
/// - `--seedVerifying=<finished>`: the phase stops at "verifying", with the
///   report's first `finished` rows finished and the next one running. A
///   count that leaves no row running stops the launch, naming the count
///   and the report's rows.
/// - `--seedBurnedBoxes=<n>`: the run's inputs record `n` burned boxes on
///   page 1.
/// - `--seedOutputBytes=<n>`: the run's inputs record an output of `n`
///   bytes; its line shows only beside `--seedOutput`.
/// - `--seedSecurePages=<n>`: the run's inputs record `n` Secure
///   Rasterization pages in place of the report's own.
/// - `--seedUnread=<k>/<m>`: the run's inputs record pages 1 to `k` as named
///   by the stop at Redact and pages 1 to `m` as small pictures only (each
///   from 0, not both 0).
///
/// Honest limits: hand boxes, form values, the left items, the applied
/// search, the burned boxes, the output's size, the pages and the unread
/// pages are put into state directly; they show how the screen reads
/// those values, not that a real run produces them. The covered text and
/// the changed boxes go through real steps: an annotation constructed here
/// that the shipped derivation reads, and a box added by the state's own
/// function, which sets the stale flag by its own rule. The changed boxes
/// seed the state the app guards against; they do not show that a person
/// can reach it through the screens.
nonisolated struct DebugSeedOptions: Equatable, Sendable {
    enum AppliedSearchKind: Equatable {
        case typed
        case scan
    }

    struct Left: Equatable {
        let left: Int
        let total: Int
    }

    struct Unread: Equatable {
        let notInFull: Int
        let smallPictures: Int
    }

    var handBoxes: Int?
    var formValues: Int?
    var coveredText = false
    var left: Left?
    var appliedSearch: AppliedSearchKind?
    var boxesChanged = false
    var verifyingFinished: Int?
    var burnedBoxes: Int?
    var outputBytes: Int?
    var securePages: Int?
    var unread: Unread?

    /// The options in `arguments`. The first occurrence of each argument
    /// counts; a value that is not of its form seeds nothing.
    static func parse(arguments: [String]) -> DebugSeedOptions {
        var options = DebugSeedOptions()
        options.handBoxes = value(of: "--seedHandBoxes=", in: arguments).flatMap(positive)
        options.formValues = value(of: "--seedFormValues=", in: arguments).flatMap(positive)
        options.coveredText = arguments.contains("--seedCoveredText")
        options.left = value(of: "--seedLeft=", in: arguments).flatMap(left)
        options.appliedSearch = value(of: "--seedAppliedSearch=", in: arguments).flatMap { raw in
            switch raw {
            case "typed": .typed
            case "scan": .scan
            default: nil
            }
        }
        options.boxesChanged = arguments.contains("--seedBoxesChanged")
        options.verifyingFinished = value(of: "--seedVerifying=", in: arguments).flatMap(nonNegative)
        options.burnedBoxes = value(of: "--seedBurnedBoxes=", in: arguments).flatMap(positive)
        options.outputBytes = value(of: "--seedOutputBytes=", in: arguments).flatMap(positive)
        options.securePages = value(of: "--seedSecurePages=", in: arguments).flatMap(positive)
        options.unread = value(of: "--seedUnread=", in: arguments).flatMap(unread)
        return options
    }

    private static func value(of prefix: String, in arguments: [String]) -> String? {
        arguments.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
    }

    private static func nonNegative(_ raw: String) -> Int? {
        guard !raw.isEmpty, raw.allSatisfy(\.isASCII), raw.allSatisfy(\.isNumber),
              let number = Int(raw) else { return nil }
        return number
    }

    private static func positive(_ raw: String) -> Int? {
        nonNegative(raw).flatMap { $0 > 0 ? $0 : nil }
    }

    private static func left(_ raw: String) -> Left? {
        let parts = raw.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let left = positive(String(parts[0])),
              let total = positive(String(parts[1])), left <= total else { return nil }
        return Left(left: left, total: total)
    }

    private static func unread(_ raw: String) -> Unread? {
        let parts = raw.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let notInFull = nonNegative(String(parts[0])),
              let smallPictures = nonNegative(String(parts[1])), notInFull + smallPictures > 0 else { return nil }
        return Unread(notInFull: notInFull, smallPictures: smallPictures)
    }
}

// The values the launch hook seeds, one builder per option. Each returns
// what the hook hands to the app's own state; none touches the state.
@MainActor
extension DebugSeedOptions {
    /// The run's term input: `handBoxes` hand-drawn boxes on page 1 with no
    /// text under them, or no boxes.
    var sensitiveTerms: SensitiveTermSet {
        guard let handBoxes else { return SensitiveTermSet(terms: [], manualRegionsWithoutText: 0) }
        return SensitiveTermSet(terms: [], manualRegionsWithoutText: handBoxes,
                                manualRegionPagesWithoutText: Array(repeating: 0, count: handBoxes))
    }

    /// The run's applied searches: one of the seeded kind, on page 1, or none.
    var appliedSearches: [SearchRecheckRequest] {
        guard let appliedSearch else { return [] }
        let kind: AppliedSearchQuery.Kind = switch appliedSearch {
        case .typed: .text("Sample")
        case .scan: .piiScan(categories: [.email])
        }
        let record = AppliedSearchRecord(
            query: AppliedSearchQuery(kind: kind, options: SearchOptions()), foundCount: 1)
        return [SearchRecheckRequest(record: record, appliedCount: 1, appliedPages: [0])]
    }

    /// The run's deselection: `left` of `total` detected items, each its own
    /// occurrence on page 1, or none.
    var deselection: RedactionState.DeselectionSnapshot? {
        guard let left else { return nil }
        let items = (0..<left.left).map { index in
            SearchResult(pageIndex: 0,
                         normalizedRect: CGRect(x: 0.1, y: 0.1 + 0.05 * Double(index % 10), width: 0.1, height: 0.03),
                         matchedText: "item", contextSnippet: "item", source: .textLayer, term: "item")
        }
        return RedactionState.DeselectionSnapshot(items: items, totalCount: left.total)
    }

    /// The run's page modes: `securePages` Secure Rasterization pages, or the
    /// report's own.
    func pageModes(_ own: [PipelineMode]) -> [PipelineMode] {
        securePages.map { Array(repeating: .secureRasterization, count: $0) } ?? own
    }

    /// The run's fallback reasons, beside `pageModes`: none on seeded pages.
    func fallbackReasons(_ own: [TextLayerDetector.FallbackReason?]) -> [TextLayerDetector.FallbackReason?] {
        securePages.map { Array(repeating: nil, count: $0) } ?? own
    }

    /// `inputs` with the seeded burned boxes, output size and unread pages.
    func withRunLineFacts(_ inputs: RedactionState.LastRunInputs) -> RedactionState.LastRunInputs {
        var inputs = inputs
        if let burnedBoxes {
            inputs.burnedRegions = [0: (0..<burnedBoxes).map { index in
                RedactionRegion(id: UUID(), normalizedRect: CGRect(
                    x: 0.1, y: 0.1 + 0.05 * Double(index % 10), width: 0.2, height: 0.03), source: .manual)
            }]
        }
        if let outputBytes { inputs.outputBytes = Int64(outputBytes) }
        if let unread {
            inputs.pagesNotSearchedInFull = Set(0..<unread.notInFull)
            inputs.smallPicturePages = Set(0..<unread.smallPictures)
        }
        return inputs
    }

    /// The box `--seedBoxesChanged` adds: a small hand-drawn box near the
    /// foot of page 1.
    static func changedBox() -> RedactionRegion {
        RedactionRegion(id: UUID(), normalizedRect: CGRect(x: 0.1, y: 0.05, width: 0.2, height: 0.04),
                        source: .manual)
    }

    /// Adds to page 1 of `document`, in memory, an opaque black square
    /// annotation over the first line of its text, the kind of cover a
    /// received PDF can carry (`ConcealingAnnotations`). A constructed
    /// annotation, not one a real import produced; the results screen's
    /// row reads it by the shipped derivation. Nothing when page 1 has no
    /// text.
    static func coverFirstLine(of document: PDFDocument?) {
        guard let page = document?.page(at: 0), let text = page.string else { return }
        let string = text as NSString
        let letters = CharacterSet.whitespacesAndNewlines.inverted
        let start = string.rangeOfCharacter(from: letters)
        guard start.location != NSNotFound else { return }
        let lineEnd = string.rangeOfCharacter(
            from: .newlines, range: NSRange(location: start.location, length: string.length - start.location))
        let end = lineEnd.location == NSNotFound ? string.length : lineEnd.location
        guard let line = page.selection(for: NSRange(location: start.location, length: end - start.location))
        else { return }
        let bounds = line.bounds(for: page).insetBy(dx: -1, dy: -1)
        guard bounds.width > 0, bounds.height > 0 else { return }
        let cover = PDFAnnotation(bounds: bounds, forType: .square, withProperties: nil)
        cover.color = .black
        cover.interiorColor = .black
        page.addAnnotation(cover)
    }
}
#endif
