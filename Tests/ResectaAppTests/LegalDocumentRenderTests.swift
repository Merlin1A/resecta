import Testing
import Foundation
@testable import ResectaApp

// LR1 (LR-6) — the audit-lint override markers in the bundled legal docs
// must never render at the first-launch gate.
//
// EULA.md carries two same-line `<!-- LegalPhrases:safe -->` HTML comments
// (audit-lint M-1 overrides — the .md sources keep them; the site copies
// drop them at publish). `AttributedString(markdown:)` under
// `.inlineOnlyPreservingWhitespace` passes inline HTML through as literal
// text (reproduced on-sim at the gate, LR-6), so `LegalDocumentView`
// strips comment spans before parsing. This suite pins that pre-pass.
@Suite("Gate legal-document rendering (LR-6)")
struct LegalDocumentRenderTests {

    @Test("Marker-bearing paragraph renders without the HTML comment")
    func markerParagraphRendersClean() {
        // Shape of the real EULA §4 marker line: end-of-line comment after
        // a single space, inside a multi-line paragraph block.
        let paragraph = "sensitive text, images, and metadata have been redacted before you share a\n"
            + "document. No tool can guarantee perfection. Always verify. <!-- LegalPhrases:safe -->"

        let rendered = String(LegalDocumentView.inlineMarkdown(paragraph).characters)

        let commentVisible = rendered.contains("<!--") || rendered.contains("LegalPhrases")
        #expect(commentVisible == false,
            "HTML comment leaked into the rendered gate text: \(rendered)")
        #expect(rendered.hasSuffix("No tool can guarantee perfection. Always verify."), // LegalPhrases:safe (renders the EULA's own disclaimer)
            "surrounding legal text must survive the comment strip: \(rendered)")
    }

    @Test("Mid-paragraph comment strips without joining words")
    func midParagraphCommentStripsClean() {
        // Shape of the real EULA §2 marker line: comment at end of an
        // interior line, so text continues on the next line after it.
        let paragraph = "redaction before relying on or sharing it. No tool can guarantee perfection. <!-- LegalPhrases:safe -->\n"
            + "Always verify."

        let rendered = String(LegalDocumentView.inlineMarkdown(paragraph).characters)

        let commentVisible = rendered.contains("<!--") || rendered.contains("LegalPhrases")
        #expect(commentVisible == false,
            "HTML comment leaked into the rendered gate text: \(rendered)")
        #expect(rendered.contains("No tool can guarantee perfection.\nAlways verify."), // LegalPhrases:safe (renders the EULA's own disclaimer)
            "line structure around the stripped comment must be preserved: \(rendered)")
    }

    @Test("Bundled EULA renders with no visible comment in any paragraph")
    func bundledEULARendersClean() throws {
        let bundle = Bundle(for: AppCoordinator.self)
        let url = try #require(
            bundle.url(forResource: LegalDocument.eula.resourceName, withExtension: "md"),
            "EULA.md missing from the app bundle")
        let contents = try String(contentsOf: url, encoding: .utf8)

        // Premise guard: the fixture must actually carry markers, or this
        // test goes false-green the day they are removed from the source.
        let markerCount = contents.components(separatedBy: "<!--").count - 1
        #expect(markerCount >= 2, "EULA.md no longer carries the lint markers this test exists for")

        for paragraph in contents.components(separatedBy: "\n\n") {
            let rendered = String(LegalDocumentView.inlineMarkdown(paragraph).characters)
            let commentVisible = rendered.contains("<!--") || rendered.contains("LegalPhrases")
            #expect(commentVisible == false,
                "HTML comment leaked into a rendered EULA paragraph: \(rendered)")
        }
    }
}
