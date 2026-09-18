import Testing
import Foundation
@testable import ResectaApp

// The reverse-rationale context rule, pinned on the four paths the sheet
// meets: the primary path (the engine's window contains the match), the
// fallback (a hand-built snippet that does not), a match spanning a line
// break (the engine keeps the match verbatim inside its window), and the
// OCR path (match and window both drawn from the normalized concatenation).
// Every value is fixture vocabulary.

@Suite("Reverse rationale context", .tags(.search))
struct ReverseRationaleContextTests {

    @Test("Primary: a window containing the match is the context, unchanged")
    func primaryPathIsTheSnippet() {
        let snippet = "…holder Delia R. Hartwell, statement…"
        #expect(ReverseRationaleContext.make(snippet: snippet, matchedText: "Hartwell") == snippet)
        #expect(ReverseRationaleContext.make(snippet: snippet, matchedText: "Delia R. Hartwell") == snippet)
    }

    @Test("Fallback: a snippet without the match is followed by the match")
    func fallbackAppendsTheMatch() {
        #expect(ReverseRationaleContext.make(snippet: "statement period", matchedText: "Hartwell")
                == "statement period Hartwell")
        #expect(ReverseRationaleContext.make(snippet: "", matchedText: "Hartwell") == " Hartwell")
    }

    @Test("A match spanning a line break is located verbatim inside a window that kept it")
    func lineBreakInsideMatchIsPrimary() {
        let window = "alpha\nbeta gamma delta"
        #expect(ReverseRationaleContext.make(snippet: window, matchedText: "alpha\nbeta") == window)
        // A window that flattened the break would not contain the match —
        // the engine's window builder keeps the match span verbatim so this
        // fallback is never the producer's path.
        #expect(ReverseRationaleContext.make(snippet: "alpha beta gamma delta", matchedText: "alpha\nbeta")
                == "alpha beta gamma delta alpha\nbeta")
    }

    @Test("OCR: match and window drawn from the same normalized concatenation stay primary")
    func ocrPathIsPrimary() {
        let concatenated = "Reference SSN 123-45-6789 on file\nQuarterly report"
        let matched = "123-45-6789"
        let window = "…SSN 123-45-6789 on file…"
        #expect(concatenated.contains(matched))
        #expect(ReverseRationaleContext.make(snippet: window, matchedText: matched) == window)
    }
}
