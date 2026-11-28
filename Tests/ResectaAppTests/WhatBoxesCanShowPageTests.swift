import Testing
import Foundation
@testable import ResectaApp

// What Boxes Can Show as the app draws it: each part in order and word for
// word, the paragraphs it shares with Settings and the results screen the
// same as there, the lint's one marker never drawn, and nothing left to
// fill in.

@Suite("What Boxes Can Show")
@MainActor
struct WhatBoxesCanShowPageTests {

    typealias Block = LegalDocumentView.Block

    static func page() throws -> String {
        let document = LegalDocument.whatBoxesCanShow
        let url = try #require(Bundle(for: AppCoordinator.self).url(
            forResource: document.resourceName, withExtension: document.fileExtension))
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// The page's parts as drawn: each paragraph through the viewer's inline pass.
    static func drawn() throws -> [Block] {
        LegalDocumentView.blocks(in: try page()).map { block in
            guard case .paragraph(let text) = block else { return block }
            return .paragraph(String(LegalDocumentView.inlineMarkdown(text).characters))
        }
    }

    static func heading(_ text: String) -> Block { .heading(level: 2, text: text) }

    static let expected: [Block] = [
        .paragraph("A box removes the text under it, but its width can still show how long that text was. That can be enough to tell which name or month it was, or how many digits an amount has."),
        heading("What a box can still show"),
        .paragraph("On a line with more words after the box, the next word starts where the boxed text ended, so a wider box does not help unless it also covers those words. On a line spread out to both margins, or a centred line, the spacing of the other words gives the same measure unless the whole line is covered."),
        .paragraph("Anyone with a short list of likely names, such as the other party to a contract or the people at an employer, can often pick the right one from the width. For a common surname the width helps even without a list."),
        .paragraph("When the possibilities are few, such as yes or no, a weekday, or a month, the width can show which one is under the box. For a number, a tight box shows how many digits it has."),
        .paragraph("Boxing a first name and a surname separately shows far more than one box over both. The same name boxed in more than one typeface, such as in the text, in capitals in a signature block, and in a heading, says more than any one of those boxes."),
        .paragraph("How much a box gives away also depends on the font: in text set in Calibri it gives away more than in Times New Roman or Arial."),
        .paragraph("The results screen counts every box as one that can still show how long its text is."),
        heading("What Cover Other Words does"),
        .paragraph("Where it can, Cover Other Words runs a box across every line it touches, out to where the lines above and below reach, and stops short of words that belong to another column, cell, or field. It can cover the other words there too, and that is its cost. It leaves a box as it is over a scan or a picture, on a page with text with no ink of its own, or on a page that is half or more a picture. It also leaves a box as it is over print that does not run upright and left to right, where there is too little unselected text above and below it to show its column, and where you drew, moved, or resized the box by hand. A widened box can still show about how long its text was: in a paragraph, by where the lines break, and more closely each time the same text appears."),
        .paragraph("The cost can be every other word on those lines. In 1,463 public contracts and benefits documents, that was about ten or eleven other words for each line a box touches."),
        .paragraph("It is off unless you turn it on."),
        heading("What stays in the document"),
        .paragraph("Resecta removes what the boxes cover. Everything else stays, including:"),
        .paragraph("Other mentions of a name that you did not box, including a short name a contract defines for a party, such as (“Acme”)."),
        .paragraph("Dates, job titles, places, employers, and amounts. Together, these can point to one person."),
        .paragraph("Addresses, product and network names, and web and e-mail addresses. In benefits documents these usually still name a vendor whose name is boxed."),
        .paragraph("Names in page headers and footers, and in logos."),
        .paragraph("Group, member, claim, and policy numbers. Scan has no kind for these, so search for them or box them by hand."),
        .paragraph("Handwritten signatures, barcodes, and QR codes. Box these by hand."),
        heading("What Checks Passed means"),
        .paragraph("Checks Passed means no check reported your boxed text in this PDF. In this version the checks do not show that they read every part of the file. What remains can still identify someone. Look over the redacted PDF in Preview before you share it."),
        heading("Using AI tools"),
        .paragraph("Some AI assistants read only the text of a long PDF. A Secure export has no text, so an assistant may get little from it and may not tell you. AI services keep uploaded files, including anything the boxes missed. How long is the service's decision: the ones we read in November 2026 said from 30 days to 5 years, and some have people review them. We know of no regulator or professional body that says how to redact a document before uploading it to an AI service, or when it is redacted enough. Redacting does not by itself permit an upload that a law, a policy, or a contract would otherwise forbid, and it does not answer a confidentiality clause. Redacting a document later does not recall a copy you already uploaded. An AI service knows which account uploaded a file, whatever the file says. Removing an employer's name may not hide the employer: public benefit-plan filings name the plan's insurer, contract number, and number of people covered."),
        heading("What Search does not look for"),
        .paragraph("Search finds the text you type, in capitals or not, and nothing else. Where the print runs words together, it finds them only where a capital, a digit or a mark shows the join, so not between two small letters (BankofAmerica), inside a value in capitals (JOHNDOE) or in a run of digits (6125550142). It does not look for other ways the same name or number can be written, such as a surname on its own, initials, a nickname, a misspelling, or a date or amount written differently. Search for each form you need."),  // LegalPhrases:safe (approved row words)
        .paragraph("Other forms Search does not try include an amount written in words beside its figures, a date in another format, a name whose words are joined another way, as in an e-mail or web address, letter-spaced capitals on a cover page, and an organisation's acronym."),
        .paragraph("On a scanned page or a photo, Search reads the words by text recognition, and a misread word will not match."),
        .paragraph("A page that carries text with no ink of its own over a picture of the page is searched by that text as stored, which can differ from what the page shows. With Include OCR Pages on, Search also reads the page's picture."),
        .paragraph("Small pictures on a typed page, such as a logo, a stamp, or a signature, are not read."),
        .paragraph("Barcodes and QR codes are not read."),
        .paragraph("Text drawn as shapes instead of characters is not read."),
        .paragraph("A page can show one word and store another; Search reads the stored one."),
        .paragraph("Search matches a word the page breaks with an added hyphen at the end of a line, whether you type it whole or with its hyphen. It can still miss one broken between digits, between a small letter and a capital, or across the end of a page, and a pattern search can miss it. On some pages it matches such a word only when you type it whole. In a phrase with two such breaks, type both words the same way."),
        .paragraph("Text typed into form fields is not searched."),
        .paragraph("With Whole word on, Search can miss a word on a tightly spaced line of a typeset PDF. Turn Whole word off for that search. Scan can also miss a date, a postal code, or an e-mail address on such a line. A phrase with a one-letter word in it, such as an initial, can still be missed there."),
        .paragraph("On a typed page, Search matches accents exactly unless the Accents option is on."),
        .paragraph("On a page where more than one line in ten is sideways among upright print, a phrase that wraps on the sideways lines can still be missed."),
    ]

    @Test("The page reads as written, part by part")
    func readsAsWritten() throws {
        let drawn = try Self.drawn()
        #expect(drawn.count == Self.expected.count)
        for (index, (got, want)) in zip(drawn, Self.expected).enumerated() {
            #expect(got == want, "part \(index)")
        }
    }

    @Test("Its headings, in order")
    func headingsInOrder() throws {
        let headings = try Self.drawn().compactMap { block -> String? in
            if case .heading(_, let text) = block { return text }
            return nil
        }
        #expect(headings == [
            "What a box can still show", "What Cover Other Words does", "What stays in the document",
            "What Checks Passed means", "Using AI tools", "What Search does not look for",
        ])
    }

    @Test("Its first paragraph is the one under the switch in Settings")
    func firstParagraph() throws {
        #expect(try Self.drawn().first == .paragraph(RedactionBoxesCopy.widthParagraph))
    }

    @Test("What the switch does reads as in Settings, with no measured sentence")
    func switchParagraph() throws {
        let drawn = try Self.drawn()
        let index = try #require(drawn.firstIndex(of: Self.heading("What Cover Other Words does")))
        #expect(drawn[index + 1] == .paragraph(RedactionBoxesCopy.switchParagraph(measured: [])))
    }

    @Test("What Checks Passed means is the small print on the results screen, then the Preview sentence")
    func checksPassed() throws {
        let drawn = try Self.drawn()
        let index = try #require(drawn.firstIndex(of: Self.heading("What Checks Passed means")))
        let sentences = ResultsScopeNote.checksPassedSentences(outputExists: true)
        #expect(sentences.count == 3)
        let preview = "Look over the redacted PDF in Preview before you share it."
        #expect(drawn[index + 1] == .paragraph((sentences + [preview]).joined(separator: " ")))
    }

    @Test("One line carries the lint's marker, and the page never draws it")
    func markerNeverDrawn() throws {
        let marked = try Self.page().split(separator: "\n").filter { $0.contains("LegalPhrases:safe") }
        #expect(marked.count == 1)
        #expect(marked.first?.contains("the text you type, in capitals or not, and nothing else.") == true)
        for block in try Self.drawn() {
            guard case .paragraph(let text) = block else { continue }
            #expect(!text.contains("<!--") && !text.contains("LegalPhrases"), "\(text.prefix(40))")
        }
    }

    @Test("Nothing is left to fill in, and the inline pass changes no paragraph")
    func nothingLeftToFill() throws {
        let page = try Self.page()
        #expect(!page.contains("\u{2039}") && !page.contains("\u{203A}"))
        for block in LegalDocumentView.blocks(in: page) {
            guard case .paragraph(let text) = block else { continue }
            let unmarked = text.replacingOccurrences(of: " <!-- LegalPhrases:safe -->", with: "")
            #expect(String(LegalDocumentView.inlineMarkdown(text).characters) == unmarked, "\(text.prefix(40))")
        }
    }
}
