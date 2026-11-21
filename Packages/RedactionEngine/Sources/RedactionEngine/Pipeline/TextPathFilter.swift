import CoreGraphics
import Foundation

/// The text path's filter, by each rectangle's kind. An ordinary rectangle
/// (a box's own, a box Search placed and its hidden letters' box, an ink
/// strip) takes a letter by today's tests: any overlap, or 3 pt around it on
/// the lines it touches (`filterCharacters`). A plan's rectangle, made for a
/// box with a band, takes a letter whose middle (`LetterBoxMiddle`) shares
/// area with it, in place of that box's own rectangle. A rectangle under a
/// widened box takes nothing here.
enum TextPathFilter {
    static func filter(
        _ entries: [CharacterInfo], _ rectangles: [TextPathRectangle], frame: PageFrame
    ) async throws -> FilterResult {
        let ordinary = rectangles.filter { $0.kind == .ordinary }.map(\.rect)
        let plans = rectangles.filter { $0.kind == .plansRectangle }.map(\.rect)
        let byBox = try await filterCharacters(characters: entries, redactionRects: ordinary)
        guard !plans.isEmpty else { return byBox }
        let kept = byBox.surviving.filter { entry in
            !plans.contains { TextPathPaintMarks.middleUnder($0, entry, frame: frame) }
        }
        return FilterResult(
            surviving: kept,
            totalCharacters: byBox.totalCharacters,
            excludedCount: byBox.excludedCount + byBox.surviving.count - kept.count)
    }
}
