import Testing
import Foundation

// The fields where a search term, a pattern or a saved name is typed keep
// the keyboard from correcting it: a corrected term searches for other words, and a
// corrected name saves a name nobody typed. SwiftUI shows a test no
// keyboard setting, so each field's modifiers are read from its source: the
// lines after the field that begin with "." (comments between them skipped)
// are its modifier chain.

@Suite("The term and name fields turn the keyboard's correction off", .tags(.search))
struct TypingFieldCorrectionTests {

    /// Each field, as (its file under Sources/ResectaApp/Views, its line).
    static let fields: [(String, String)] = [
        ("Search/SearchAndRedactSheet+SearchBar.swift", #"TextField("Add term…", text: $searchState.queryText)"#),
        ("Search/SearchAndRedactSheet+SearchBar.swift", #"TextField("Search text…", text: $searchState.queryText)"#),
        ("CustomTermsView.swift", #"TextField(placeholder, text: $pattern)"#),
        ("SavedRegexLibraryView.swift", #"TextField("Pattern", text: $newPattern)"#),
        ("SearchAndRedactSheet.swift", #"TextField("Label", text: $savedRegexSaveLabel)"#),
        ("SavedRegexLibraryView.swift", #"TextField("Label", text: $newLabel)"#),
        ("Search/SavedSearchListSheet.swift", #"TextField("Name", text: $renameText)"#),
        ("Search/SavedSearchListSheet.swift", #"TextField("Name", text: $savePromptName)"#),
    ]

    @Test("A term, pattern or name field has autocorrection disabled", arguments: fields)
    func fieldHasCorrectionOff(file: String, field: String) throws {
        let root = URL(fileURLWithPath: "\(#filePath)")
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/ResectaApp/Views/\(file)"), encoding: .utf8)
        let lines = source.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let at = lines.indices.filter { lines[$0] == field }
        try #require(at.count == 1, "\(field) is in \(file) once")
        let chain = lines[(at[0] + 1)...].prefix { $0.hasPrefix(".") || $0.hasPrefix("//") }.filter { $0.hasPrefix(".") }
        #expect(chain.contains { $0 == ".autocorrectionDisabled(true)" || $0 == ".autocorrectionDisabled()" },
                "\(field) in \(file): modifiers \(Array(chain))")
    }
}
