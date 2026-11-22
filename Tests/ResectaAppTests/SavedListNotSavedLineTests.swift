import Testing
import Foundation
@testable import ResectaApp

@Suite("Saved lists: the line for a change that was not stored")
@MainActor
struct SavedListNotSavedLineTests {

    @Test("The line reads as its words of record")
    func words() {
        #expect(ListChange.notSavedMessage == "Could not save this change. Try again.")
    }

    enum Prompt: CaseIterable, Sendable {
        case saveFromSearch, savedPatternsAdd, alwaysFlagAdd, neverFlagAdd, savedSearchSave, savedSearchRename

        var file: String {
            switch self {
            case .saveFromSearch: "Views/Search/SearchAndRedactSheet+SaveRegex.swift"
            case .savedPatternsAdd: "Views/SavedRegexLibraryView.swift"
            case .alwaysFlagAdd, .neverFlagAdd: "Views/CustomTermsView.swift"
            case .savedSearchSave, .savedSearchRename: "Views/Search/SavedSearchListSheet.swift"
            }
        }

        /// The add's arm, plus each delete of that list whose line it is.
        var uses: Int {
            switch self {
            case .savedPatternsAdd: 3      // add, swipe-delete, Delete All
            case .alwaysFlagAdd: 3         // add, swipe-delete, Delete All
            case .neverFlagAdd: 2          // add, swipe-delete
            default: 1
            }
        }

        var line: String {
            switch self {
            case .saveFromSearch: "savedRegexSaveError = ListChange.notSavedMessage"
            case .savedPatternsAdd: "addError = ListChange.notSavedMessage"
            case .alwaysFlagAdd: "alwaysError = ListChange.notSavedMessage"
            case .neverFlagAdd: "neverError = ListChange.notSavedMessage"
            case .savedSearchSave: "savePromptError = ListChange.notSavedMessage"
            case .savedSearchRename: "renameError = ListChange.notSavedMessage"
            }
        }
    }

    @Test("Each prompt and list shows the line when its change was not stored", arguments: Prompt.allCases)
    func promptShowsTheLine(_ prompt: Prompt) throws {
        #expect(Prompt.allCases.count == 6)
        let source = try String(
            contentsOf: URL(fileURLWithPath: "\(#filePath)")
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/ResectaApp").appendingPathComponent(prompt.file),
            encoding: .utf8)
        #expect(source.components(separatedBy: prompt.line).count - 1 == prompt.uses)
    }

    @Test("The saved-search list's deletes that were not stored are announced with the line")
    func savedSearchDeletesAnnounced() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: "\(#filePath)")
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/ResectaApp/Views/Search/SavedSearchListSheet.swift"),
            encoding: .utf8)
        #expect(source.contains("AccessibilityNotification.Announcement(ListChange.notSavedMessage).post()"))
        #expect(source.components(separatedBy: "!= .saved { Self.reportNotSaved() }").count - 1 == 2)
    }
}
