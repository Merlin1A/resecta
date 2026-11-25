import Testing
import Foundation

// The fields where a search term, a pattern or a saved name is typed keep
// the keyboard from correcting it and keep Writing Tools out: a corrected
// term searches for other words, a corrected name saves a name nobody
// typed, and words meant to be redacted are not handed to a rewrite tool.
// SwiftUI shows a test no keyboard setting, so each field's modifiers are
// read from its source: the lines after the field that begin with "."
// (comments between them skipped) are its modifier chain.

@Suite("The term and name fields turn the keyboard's correction and Writing Tools off", .tags(.search))
struct TypingFieldCorrectionTests {

    /// Each field, as (a short name, its file under Sources/ResectaApp/Views, its line).
    nonisolated static let fields: [(String, String, String)] = [
        ("add-term", "Search/SearchAndRedactSheet+SearchBar.swift", #"TextField("Add term…", text: $searchState.queryText)"#),
        ("search-text", "Search/SearchAndRedactSheet+SearchBar.swift", #"TextField("Search text…", text: $searchState.queryText)"#),
        ("custom-term", "CustomTermsView.swift", #"TextField(placeholder, text: $pattern)"#),
        ("pattern", "SavedRegexLibraryView.swift", #"TextField("Pattern", text: $newPattern)"#),
        ("save-label", "SearchAndRedactSheet.swift", #"TextField("Label", text: $savedRegexSaveLabel)"#),
        ("library-label", "SavedRegexLibraryView.swift", #"TextField("Label", text: $newLabel)"#),
        ("rename", "Search/SavedSearchListSheet.swift", #"TextField("Name", text: $renameText)"#),
        ("save-name", "Search/SavedSearchListSheet.swift", #"TextField("Name", text: $savePromptName)"#),
    ]

    @Test("A term, pattern or name field has autocorrection and Writing Tools disabled", arguments: fields)
    func fieldHasCorrectionOff(name: String, file: String, field: String) throws {
        let root = URL(fileURLWithPath: "\(#filePath)")
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/ResectaApp/Views/\(file)"), encoding: .utf8)
        let lines = source.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let at = lines.indices.filter { lines[$0] == field }
        try #require(at.count == 1, "field \(name): its line is in \(file) once")
        let chain = lines[(at[0] + 1)...].prefix { $0.hasPrefix(".") || $0.hasPrefix("//") }.filter { $0.hasPrefix(".") }
        #expect(chain.contains { $0 == ".autocorrectionDisabled(true)" || $0 == ".autocorrectionDisabled()" },
                "field \(name): no .autocorrectionDisabled in \(Array(chain))")
        #expect(chain.contains(".writingToolsBehavior(.disabled)"),
                "field \(name): no .writingToolsBehavior in \(Array(chain))")
    }
}
