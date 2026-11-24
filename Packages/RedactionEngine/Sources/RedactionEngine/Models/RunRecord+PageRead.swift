import CoreGraphics
import Foundation
import PDFKit
import RedactionCore

extension RunRecord {
    /// One page's read: its words, the text they partition and the page's
    /// facts, made once for a page and handed to every maker of its plan, so
    /// that the run's plan and any plan kept before it read the same words.
    public struct PageRead: Equatable, Sendable {
        package let words: PageWords
        package let text: String
        package let facts: PageTextFacts

        package init(words: PageWords, text: String, facts: PageTextFacts) {
            self.words = words
            self.text = text
            self.facts = facts
        }

        /// The page's read: its words filled with the extractor's letter
        /// boxes, the string they partition, and its facts with the page's
        /// own answer to whether its print is a picture. Nil when the page
        /// has no drawing to read or its letters cannot be read; a plan made
        /// with no read is made with no words.
        @concurrent package static func read(_ page: PDFPage, hasHiddenOCG: Bool) async -> PageRead? {
            guard let cgPage = page.pageRef else { return nil }
            let text = page.string ?? ""
            guard let characters = try? await TextLayerExtractor()
                .extractCharacters(from: page, hasHiddenOCG: hasHiddenOCG) else { return nil }
            let invisible = DocumentSearcher.showsInvisibleText(cgPage)
            let facts = PageTextFacts(showsInvisibleText: invisible,
                                      carriesPageScaleImage: DocumentSearcher.printIsAPicture(page, cgPage: cgPage))
            return PageRead(words: PageWordReader.words(text: text, characters: characters), text: text, facts: facts)
        }

        /// Each listed page's read, from a document no view draws (a private
        /// copy of the open one); a page that cannot be read is left out.
        @concurrent public static func reads(of document: SendablePDFDocument, pages: [Int],
                                             hasHiddenOCG: Bool) async -> [Int: PageRead] {
            var out: [Int: PageRead] = [:]
            for index in pages {
                guard let page = document.document.page(at: index),
                      let read = await read(page, hasHiddenOCG: hasHiddenOCG) else { continue }
                out[index] = read
            }
            return out
        }
    }

    /// Whether the run's plan reads the page's words: false under "as
    /// placed", which places every box as it stands, so a run then reads none.
    public static var planReadsWords: Bool { planSource != .asPlaced }
}
