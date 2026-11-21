import CoreGraphics
import Foundation

/// The paint marks: a word is marked when a painted rectangle shares area
/// with the middle (`LetterBoxMiddle`) of one of its letters' own boxes, and
/// the whole-word closure then takes it whole. Paint is the rectangle the
/// fill used, mapped back outward into the frame the entries are in. Paint
/// marks are not alphabet marks: they never enter the count of runs left
/// out, and they never decide whether a page left with no word is a picture.
/// With no painted rectangle nothing is marked.
enum TextPathPaintMarks {
    /// The word indices of `survivors` with a letter's middle under paint.
    /// White space is no letter of a word and marks nothing.
    static func marks(_ survivors: [CharacterInfo], painted: [CGRect], frame: PageFrame) -> Set<Int> {
        guard !painted.isEmpty else { return [] }
        var marked = Set<Int>()
        for entry in survivors where !marked.contains(entry.wordIndex)
            && !SandwichMetrics.isLineageWhitespace(entry.character) {
            if painted.contains(where: { middleUnder($0, entry, frame: frame) }) {
                marked.insert(entry.wordIndex)
            }
        }
        return marked
    }

    /// Whether `rect` shares area with the middle of `entry`'s own box. A box
    /// with no width or no height has no middle and shares area with
    /// nothing, as `LetterBoxMiddle` reads it: it shows no ink to cover.
    static func middleUnder(_ rect: CGRect, _ entry: CharacterInfo, frame: PageFrame) -> Bool {
        guard let middle = LetterBoxMiddle.middle(of: entry.bounds, rotation: frame.rotation) else {
            return false
        }
        return sharesArea(rect, middle)
    }

    /// Two rectangles share area: their intersection has width and height.
    static func sharesArea(_ a: CGRect, _ b: CGRect) -> Bool {
        let shared = a.standardized.intersection(b.standardized)
        return !shared.isNull && shared.width > 0 && shared.height > 0
    }
}
