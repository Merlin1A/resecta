import Testing
import Foundation
import SwiftUI
import UIKit
@testable import ResectaApp
@testable import RedactionEngine

// The small print under the results screen's buttons: shown only on a run
// titled Checks Passed and only with sentences, one paragraph joined by
// single spaces, and no room taken when it draws nothing.

@Suite("Results scope note", .tags(.display))
@MainActor
struct ResultsScopeNoteTests {

    static func height(_ view: some View, width: CGFloat = 390) -> CGFloat {
        UIHostingController(rootView: view).sizeThatFits(in: CGSize(width: width, height: 4_000)).height
    }

    @Test("The sentences are joined by single spaces; none gives nothing")
    func joining() {
        #expect(ResultsScopeNote.joined([]) == nil)
        #expect(ResultsScopeNote.joined(["One."]) == "One.")
        #expect(ResultsScopeNote.joined(["One.", "Two.", "Three."]) == "One. Two. Three.")
    }

    @Test("Shown only when it has words and the title is Checks Passed")
    func scopeNoteShowsOnlyWhenItHasWordsAndTheTitleIsChecksPassed() throws {
        let sentences = ["One.", "Two."]
        let rows: [(String, Bool)] = [
            ("secureAllPass", true), ("secureScreenshot", true),
            ("secureWarningOnly", false), ("secureFail", false), ("secureSkippedOff", false),
        ]
        for (name, shown) in rows {
            let report = try #require(VerificationDebugFixtures.all[name], "no seeded report \(name)")
            #expect(ResultsScopeNote.shows(report: report, sentences: sentences) == shown, "\(name)")
            #expect(ResultsScopeNote.paragraph(report: report, sentences: sentences)
                    == (shown ? "One. Two." : nil), "\(name)")
            // No sentences: never shown.
            #expect(!ResultsScopeNote.shows(report: report, sentences: []), "\(name)")
        }
        #expect(rows.count == 5)
    }

    @Test("Drawing nothing takes no room; drawing the paragraph does")
    func emptyNoteHasNoHeight() throws {
        let pass = try #require(VerificationDebugFixtures.all["secureAllPass"])
        let fail = try #require(VerificationDebugFixtures.all["secureFail"])
        #expect(Self.height(ResultsScopeNote(report: pass, sentences: [])) == 0)
        #expect(Self.height(ResultsScopeNote(report: fail, sentences: ["One."])) == 0)
        #expect(Self.height(ResultsScopeNote(report: pass, sentences: ["One."])) > 0)
    }
}
