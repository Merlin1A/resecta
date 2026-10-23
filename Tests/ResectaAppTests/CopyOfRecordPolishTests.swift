import Testing
import Foundation
import RedactionEngine
@testable import ResectaApp

// One wording per concept across the Search sheet and Custom Terms: the
// strings below follow their sibling on the same screen, or name only
// what the code does. Behaviour pins where a pure function returns the
// copy; source pins where the copy is only a view literal.

@Suite("Copy of record: one wording per concept")
@MainActor
struct CopyOfRecordPolishTests {

    private func source(_ path: String) throws -> String {
        try String(contentsOf: URL(fileURLWithPath: "\(#filePath)")
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(path), encoding: .utf8)
    }

    @Test("The canvas banner after a Scan names the Scan; a scan that could not start says so, in the sheet's words")
    func detectionBannerWording() {
        let none3 = DocumentEditorView.detectionBannerModel(outcome: .nothingFound(pageCount: 3), scanSummary: nil)
        #expect(none3?.message == "Scan found no items across 3 pages.")
        let none1 = DocumentEditorView.detectionBannerModel(outcome: .nothingFound(pageCount: 1), scanSummary: nil)
        #expect(none1?.message == "Scan found no items across 1 page.")
        let failed = DocumentEditorView.detectionBannerModel(outcome: .failed, scanSummary: nil)
        #expect(failed?.message == "The last scan couldn't start because the document wasn't ready.")
        #expect(failed?.message == SearchEmptyStateCopy.description(for: .piiScanStartFailed))
    }

    @Test("The filtered-out description names the four filters Show All clears")
    func filteredOutNamesTheFilters() {
        #expect(SearchEmptyStateCopy.filteredOutDescription
                == "Your active filters hide all results. Adjust the source, OCR confidence, category, or applied filters to see them.")
    }

    @Test("The Scan side's saved-list copy promises no categories a recall never restores")
    func savedScanCopy() {
        #expect(SavedSearchListSheet.emptyStateDescription(for: .scan)
                == "Save a scan to reuse it later on this or other documents. Saved searches are listed on the Search side.")
        #expect(!SavedSearchListSheet.savePromptMessage(for: .scan).contains("categor"))
    }

    @Test("Custom Terms: one rejection sentence and one too-long sentence on the add row")
    func customTermsAddRowCopy() async {
        let invalid = await AddTermRow.validateSubmission(rawPattern: "([a-z", isRegex: true)
        if case .invalidRegex(let message) = invalid {
            #expect(message == "Term rejected. The pattern may be invalid or fail the regex safety check.")
        } else {
            Issue.record("an uncompilable regex must read the rejection sentence, got \(invalid)")
        }
        let long = String(repeating: "a", count: UserTermsStore.patternLengthCap + 1)
        let tooLong = await AddTermRow.validateSubmission(rawPattern: long, isRegex: false)
        if case .tooLong(let message) = tooLong {
            #expect(message == "Pattern too long (max \(UserTermsStore.patternLengthCap) characters).")
        } else {
            Issue.record("an over-cap pattern must read the too-long sentence, got \(tooLong)")
        }
    }

    @Test("A Scan's cap banner drops the refine clause (a scan has no query); a search's keeps it")
    func capBannerPerInterface() {
        let scan = SearchFooterSection.capBannerText(resultCount: 1000, unscannedPageCount: 2, interface: .scan)
        #expect(scan == "Showing first 1000 results. 2 pages were never scanned.")
        let search = SearchFooterSection.capBannerText(resultCount: 1000, unscannedPageCount: 0, interface: .search)
        #expect(search.hasSuffix(" Refine your search for more specific matches."))
    }

    @Test("The parked strip reads the live count while a Scan runs, the interface name otherwise")
    func compactStripTitle() {
        #expect(SearchAndRedactSheet.compactStripTitleText(interface: .scan, isSearching: true, found: 7) == "Scanning… 7 found")
        #expect(SearchAndRedactSheet.compactStripTitleText(interface: .scan, isSearching: false, found: 7)
                == SearchInterface.scan.displayName)
        #expect(SearchAndRedactSheet.compactStripTitleText(interface: .search, isSearching: true, found: 7)
                == SearchInterface.search.displayName, "a Search keeps its name: item 9 is not ruled")
    }

    @Test("View-only copy: the Settings footer is gone, the rationale popover closes with Done, the regex save reads the store voice, the OCR chip names its pages")
    func viewOnlyCopy() throws {
        let settings = try source("Sources/ResectaApp/Views/SettingsView.swift")
        #expect(!settings.contains("staged for your review"))
        let popover = try source("Sources/ResectaApp/Views/DiagnosticsPanel/ReverseRationalePopover.swift")
        #expect(popover.contains("Button(\"Done\") { dismiss() }"))
        #expect(!popover.contains("Button(\"Close\")"))
        let sheet = try source("Sources/ResectaApp/Views/SearchAndRedactSheet.swift")
        #expect(sheet.contains("return PatternAdmission.storeRejectedMessage"))
        let toolbar = try source("Sources/ResectaApp/Views/Search/SearchToolbarSection.swift")
        #expect(toolbar.contains("optionChip(\"Include OCR Pages\""))
        let trigger = try source("Sources/ResectaApp/Views/Search/SearchAndRedactSheet+Trigger.swift")
        #expect(trigger.contains("Turn on Include OCR Pages to search scanned content."))
        #expect(trigger.contains("argument: \"Scanning page \\(current) of \\(total)\""))
    }

    @Test("The Search options' warnings and the result-cap banner use the warning token, not a raw colour")
    func warningToken() throws {
        let toolbar = try source("Sources/ResectaApp/Views/Search/SearchToolbarSection.swift")
        let footer = try source("Sources/ResectaApp/Views/Search/SearchFooterSection.swift")
        #expect(!toolbar.contains(".foregroundStyle(.orange)"))
        #expect(!footer.contains(".foregroundStyle(.orange)"))
        #expect(footer.contains(".foregroundStyle(ResectaTokens.SemanticColor.warnText)"))
    }
}
