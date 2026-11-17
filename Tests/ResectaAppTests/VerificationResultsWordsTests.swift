import Testing
import Foundation
import RedactionEngine
@testable import ResectaApp

// The results screen's renamed words, read from the source files that draw
// them, and the Settings sentence that names the screen's title.

@Suite("The results screen's words")
@MainActor
struct VerificationResultsWordsTests {

    private func source(_ path: String) throws -> String {
        try String(contentsOf: URL(fileURLWithPath: "\(#filePath)")
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(path), encoding: .utf8)
    }

    @Test("The results screen's old words are gone from the files that drew them")
    func noOldWordsRemain() throws {
        let files = [
            "Sources/ResectaApp/Views/VerificationMasthead.swift",
            "Sources/ResectaApp/Extensions/VerificationStatus+Display.swift",
            "Sources/ResectaApp/Views/SettingsView.swift",
        ]
        let old = ["Verification Skipped", "with OCR on", "unapplied;", "Verify Before Export on to include",
                   "verifyBeforeExport) on to include"]
        for file in files {
            let text = try source(file)
            for words in old {
                #expect(!text.contains(words), "\(file) still holds \u{201C}\(words)\u{201D}")
            }
        }
    }

    @Test("Settings names the title the results screen shows when the checks are off")
    func settingsNamesTheTitle() throws {
        let settings = try source("Sources/ResectaApp/Views/SettingsView.swift")
        #expect(settings.contains("Off: documents export without the post-redaction checks. "
                                  + "The results screen will show \(VerificationStatus.skipped.title)."))
        #expect(VerificationStatus.skipped.title == "Checks Not Run")
    }
}
