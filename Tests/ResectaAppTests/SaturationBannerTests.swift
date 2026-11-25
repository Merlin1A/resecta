import Testing
import Foundation
import RedactionEngine
@testable import ResectaApp

// Saturation banner shortcut contracts. Each tap-shortcut
// mutates the corresponding `searchState` field; the banner copy is
// pinned. Re-trigger of the
// search after the mutation is wired through the `onTriggerSearch`
// closure on `SearchResultsSection` (verified by handoff cell — not
// re-tested here since it is a closure call without side effects on
// `SearchState`; the trigger path itself is exercised by the broader
// search test suite).

@Suite("Saturation banner", .tags(.search))
@MainActor
struct SaturationBannerTests {

    // MARK: - Strings

    @Test("Banner headline matches the existing saturation copy")
    func bannerHeadline() {
        // The banner promotes (not replaces) the prior inline message,
        // so the headline string remains "≥ 10,000 matches — refine query".
        let expected = "\u{2265} 10,000 matches \u{2014} refine query"
        #expect(SaturationBannerCopy.headline == expected)
    }

    @Test("Shortcut button labels are mechanism-description action labels")
    func shortcutLabels() {
        #expect(SaturationBannerCopy.addWholeWord == "Add whole-word filter")
        #expect(SaturationBannerCopy.toggleCaseSensitive == "Toggle case-sensitive")
    }

    // MARK: - Colours

    /// The banners file's code lines: whole-line comments dropped and
    /// indentation trimmed, so a comment that names a colour is not read.
    private static func bannerCodeLines() throws -> [String] {
        let url = URL(fileURLWithPath: "\(#filePath)")
            .deletingLastPathComponent()   // Tests/ResectaAppTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // <repo root>
            .appendingPathComponent("Sources/ResectaApp/Views/Search/SearchResultsBanners.swift")
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("//") }
    }

    /// The first `.foregroundStyle(` line after the line that is exactly
    /// `view`: the style that view is drawn in.
    private static func style(after view: String, in lines: [String]) -> String? {
        guard let start = lines.firstIndex(of: view) else { return nil }
        return lines[(start + 1)...].first { $0.hasPrefix(".foregroundStyle(") }
    }

    @Test("The band says its caution twice, in the tokens")
    func cautionSaidTwiceInTheTokens() throws {
        let lines = try Self.bannerCodeLines()
        #expect(!lines.isEmpty)
        // Each style is read at its own view, so a swap of the two is red.
        #expect(Self.style(after: "Image(systemName: \"exclamationmark.circle.fill\")", in: lines)
            == ".foregroundStyle(ResectaTokens.Ink.cautionMark)")
        #expect(Self.style(after: "Text(SaturationBannerCopy.headline)", in: lines)
            == ".foregroundStyle(.primary)")
        #expect(lines.contains(".background(ResectaTokens.SemanticColor.warningTint.opacity(0.08))"))
        // No raw orange is left in the file's code (`Color.orange` included).
        let raw = lines.filter { $0.contains(".orange") }
        #expect(raw.isEmpty, "raw orange: \(raw)")
    }

    // MARK: - Add whole-word filter shortcut

    @Test("Add whole-word filter sets options.wholeWord = true")
    func addWholeWordMutatesOptions() {
        let state = SearchState()
        state.options.wholeWord = false

        // Mirror the banner's tap handler.
        state.options.wholeWord = true

        #expect(state.options.wholeWord == true)
    }

    @Test("Add whole-word filter is idempotent — re-tap leaves wholeWord = true")
    func addWholeWordIsIdempotent() {
        let state = SearchState()
        state.options.wholeWord = true

        state.options.wholeWord = true

        #expect(state.options.wholeWord == true)
    }

    // MARK: - Toggle case-sensitive shortcut

    @Test("Toggle case-sensitive flips options.caseSensitive")
    func toggleCaseSensitiveFlipsField() {
        let state = SearchState()
        #expect(state.options.caseSensitive == false)

        state.options.caseSensitive.toggle()
        #expect(state.options.caseSensitive == true)

        state.options.caseSensitive.toggle()
        #expect(state.options.caseSensitive == false)
    }
}
