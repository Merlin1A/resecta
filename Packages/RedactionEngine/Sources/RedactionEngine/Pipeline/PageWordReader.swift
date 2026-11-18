import Foundation
import PDFKit
import RedactionCore

/// The one reader that fills a page's words from its text layer. It reads
/// the letter boxes the engine's extractor reads, one selection box per
/// character, through the extractor itself, so the words and the text path
/// see the same boxes. The boxes are in the page's own points as displayed:
/// zero-origin and turned by the page's rotation, as the extractor gives
/// them.
package enum PageWordReader {
    /// The page's words, partitioned from `page.string` and filled with the
    /// extractor's boxes.
    @concurrent package static func words(on page: PDFPage, hasHiddenOCG: Bool = false) async throws -> PageWords {
        let text = page.string ?? ""
        let characters = try await TextLayerExtractor().extractCharacters(from: page, hasHiddenOCG: hasHiddenOCG)
        return words(text: text, characters: characters)
    }

    /// The words of `text` with the extractor's `characters` grouped under
    /// them by their string offsets.
    package static func words(text: String, characters: [CharacterInfo]) -> PageWords {
        let boxes = characters.map { character in
            LetterBox(offset: character.stringIndex,
                      rect: PointRect(minX: Double(character.bounds.minX), minY: Double(character.bounds.minY),
                                      maxX: Double(character.bounds.maxX), maxY: Double(character.bounds.maxY)))
        }
        return PageWords(text: text, boxes: boxes, source: .textLayer)
    }
}
