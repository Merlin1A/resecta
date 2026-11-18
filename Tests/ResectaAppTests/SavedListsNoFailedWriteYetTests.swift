import Testing
import Foundation
import RedactionEngine
@testable import ResectaApp

// No write reports its outcome yet, so no change to a saved list can answer
// "not saved". In a folder that cannot be written the answer is still
// "saved": that is the shipped defect, and this file goes, whole, in the
// commit that makes a write report.

@Suite("Saved lists: no change answers not saved yet", .serialized)
@MainActor
struct SavedListsNoFailedWriteYetTests {

    enum Situation: CaseIterable, Sendable {
        case ordinary, refused, held, unwritableFolder
    }

    private static func suite() -> UserDefaults {
        let name = "app.resecta.tests.NoFailedWriteYet.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name)!
        suite.removePersistentDomain(forName: name)
        return suite
    }

    /// Every answer of every change of the three lists, in one situation.
    private static func answers(in situation: Situation) throws -> [ListChange] {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("NoFailedWriteYet-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            UnreadableFile.unlockFolder(folder)
            try? FileManager.default.removeItem(at: folder)
        }
        let termsURL = folder.appendingPathComponent("user-terms.v1.json")
        let regexURL = folder.appendingPathComponent("saved-regexes.v1.json")
        let searchURL = folder.appendingPathComponent("saved-searches.v2.json")
        let stored = SavedSearch(name: "Stored", mode: .text, queryText: "stored")
        #expect(UserTermsStore(fileURL: termsURL, legacyDefaults: suite())
            .addAlwaysFlag(UserTerm(pattern: "taken", isRegex: false)) == .saved)
        #expect(SavedRegexStore(fileURL: regexURL, legacyDefaults: suite())
            .add(label: "Taken", pattern: "[0-9]{2}") == .saved)
        #expect(SavedSearchStore(fileURL: searchURL, legacyDefaults: suite()).add(stored) == .saved)
        switch situation {
        case .ordinary, .refused: break
        case .held:
            for url in [termsURL, regexURL, searchURL] { try UnreadableFile.take(url) }
        case .unwritableFolder:
            try UnreadableFile.lockFolder(folder)
        }
        defer { for url in [termsURL, regexURL, searchURL] { UnreadableFile.restore(url) } }

        let terms = UserTermsStore(fileURL: termsURL, legacyDefaults: suite())
        let regexes = SavedRegexStore(fileURL: regexURL, legacyDefaults: suite())
        let searches = SavedSearchStore(fileURL: searchURL, legacyDefaults: suite())
        let refuse = situation == .refused
        let term = UserTerm(pattern: refuse ? "taken" : "fresh", isRegex: false)
        let label = refuse ? "Taken" : "Fresh"
        let name = refuse ? "Stored" : "Fresh"
        return [
            terms.addAlwaysFlag(term),
            terms.addNeverFlag(UserTerm(pattern: refuse ? "a" : "fresh", isRegex: false)),
            terms.removeAlwaysFlag(at: IndexSet()),
            terms.removeNeverFlag(at: IndexSet()),
            terms.clearAllTerms(),
            regexes.add(label: label, pattern: "[0-9]{3}"),
            regexes.deleteUserSaved(at: IndexSet()),
            regexes.clearAllUserSaved(),
            searches.add(SavedSearch(name: name, mode: .text, queryText: "x")),
            searches.rename(id: refuse ? UUID() : stored.id, to: "Other"),
            searches.remove(id: stored.id),
            searches.clearAll(interface: .search),
        ]
    }

    @Test("Until a write reports, no change to a saved list answers not saved",
          arguments: Situation.allCases)
    func noneAnswersNotSaved(_ situation: Situation) throws {
        #expect(Situation.allCases.count == 4)
        let answers = try Self.answers(in: situation)
        #expect(answers.count == 12, "five Custom Terms changes, three Saved Regexes, four saved searches")
        #expect(!answers.contains(.notSaved))
        switch situation {
        case .ordinary, .unwritableFolder:
            // The unwritable folder still answers saved: the shipped defect.
            #expect(answers.allSatisfy { $0 == .saved })
        case .refused:
            #expect(answers.allSatisfy { if case .refused = $0 { true } else { $0 == .saved } })
            #expect(answers.filter { if case .refused = $0 { true } else { false } }.count == 5)
        case .held:
            #expect(answers.allSatisfy { $0 == .held })
        }
    }
}
