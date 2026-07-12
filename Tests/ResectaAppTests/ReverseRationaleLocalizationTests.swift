import Testing
import Foundation
@testable import ResectaApp

// LF-10 — the reverseRationale popover rendered raw keys because its
// `String(localized:)` call sites omitted `table: "Legal"`. The app has
// exactly one string catalog (Legal.xcstrings); there is no default
// Localizable table, so an un-tabled lookup finds nothing and Foundation
// falls back to returning the key string itself — silently, in shipped UI.
//
// Two tripwires:
// 1. Runtime resolution: each popover key must resolve from the "Legal"
//    table to something other than its raw key (catches key/table renames
//    and the catalog dropping out of the target).
// 2. Call-site scan: no `String(localized:` call in app sources may omit
//    `table:` — with no default table in the target, every un-tabled call
//    is this defect class. If a default Localizable.xcstrings is ever
//    added, rework this guard rather than deleting it.

@Suite("ReverseRationale localization resolution (LF-10)")
struct ReverseRationaleLocalizationTests {

    private var appBundle: Bundle { Bundle(for: AppCoordinator.self) }

    // nonisolated: consumed by `@Test(arguments:)` (hoisted nonisolated peer
    // under the s04 SE-0466 MainActor default — same posture as
    // LegalKeyExistenceTests.eulaKeys).
    nonisolated static let popoverKeys = [
        "reverseRationale.title",
        "reverseRationale.header",
        "reverseRationale.scopeFooter",
    ]

    @Test("Popover key resolves from the Legal table, not to its raw key", arguments: popoverKeys)
    func keyResolvesFromLegalTable(key: String) {
        let resolved = String(
            localized: String.LocalizationValue(key),
            table: "Legal",
            bundle: appBundle
        )
        #expect(
            resolved != key,
            "\(key) resolved to its own raw key — the Legal-table lookup failed (key/table drift, or Legal.xcstrings dropped from the app target); the ⓘ popover would render raw keys again"
        )
        #expect(!resolved.isEmpty, "\(key) resolved to an empty string")
    }

    @Test("No String(localized:) call site in app sources omits table:")
    func noUntabledLocalizedStringCallSites() throws {
        let sourcesRoot = URL(fileURLWithPath: "\(#filePath)")
            .deletingLastPathComponent()   // Tests/ResectaAppTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // <repo root>
            .appendingPathComponent("Sources/ResectaApp")
        let enumerator = try #require(
            FileManager.default.enumerator(
                at: sourcesRoot, includingPropertiesForKeys: nil),
            "cannot enumerate \(sourcesRoot.path)"
        )

        var untabled: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            for args in callArgumentSpans(of: "String(localized:", in: text)
            where !args.contains("table:") {
                untabled.append("\(url.lastPathComponent): String(localized: \(args.prefix(60))…")
            }
        }
        #expect(
            untabled.isEmpty,
            "String(localized:) without table: — the app has no default string table, so these render their raw keys: \(untabled.joined(separator: " | "))"
        )
    }

    /// Argument text of each `marker`-opened call in `text`, spanning from
    /// after the marker's `(` to its balanced `)`. Double-quoted literals are
    /// skipped when counting parens. An unterminated call fails the test via
    /// a sentinel span that never contains `table:`.
    private func callArgumentSpans(of marker: String, in text: String) -> [String] {
        var spans: [String] = []
        var search = text.startIndex
        while let hit = text.range(of: marker, range: search..<text.endIndex) {
            var depth = 1   // the marker's own `(`
            var index = hit.upperBound
            var inString = false
            while index < text.endIndex {
                let char = text[index]
                if inString {
                    if char == "\\" { index = text.index(after: index) }
                    else if char == "\"" { inString = false }
                } else {
                    switch char {
                    case "\"": inString = true
                    case "(": depth += 1
                    case ")": depth -= 1
                    default: break
                    }
                    if depth == 0 { break }
                }
                index = text.index(after: index)
            }
            spans.append(
                depth == 0
                    ? String(text[hit.upperBound..<index])
                    : "<unbalanced call — scanner could not find the closing paren>")
            search = index < text.endIndex ? text.index(after: index) : text.endIndex
        }
        return spans
    }
}
