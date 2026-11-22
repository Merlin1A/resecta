import Testing
import Foundation
@testable import ResectaApp
import RedactionEngine

// Secure Rasterization is the only mode. The run and the verify-only re-run
// read one rule, `PipelineMode.effective`, and it gives Secure Rasterization
// for every input: Paranoid Mode on or off, any document override, and any
// setting, including a stored Searchable setting, which is left as stored.
// A launch argument reaches the app as the same defaults key, so the
// stored-setting and run cases cover it; it is not set here, because the
// argument domain is the whole test process's. The screen test launches the
// app with it. No control offers a mode: the … menu has no Switch Mode row
// and Settings no picker.

@Suite("Effective pipeline mode", .serialized)
@MainActor
struct EffectivePipelineModeTests {

    @Test("Every input gives Secure Rasterization",
          arguments: [true, false], [nil, PipelineMode.secureRasterization, .searchableRedaction])
    func everyInputGivesSecure(paranoid: Bool, override: PipelineMode?) {
        for setting in PipelineMode.allCases {
            #expect(PipelineMode.effective(paranoid: paranoid, override: override, setting: setting)
                    == .secureRasterization, "setting \(setting)")
        }
    }

    @Test("A stored Searchable setting is left as stored and read as Secure Rasterization")
    func storedSearchableReadsAsSecure() throws {
        let suiteName = "effective-mode-stored-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("searchableRedaction", forKey: "pipelineMode.v2")
        let settings = SettingsState(defaults: defaults)
        #expect(settings.pipelineMode == .searchableRedaction, "the stored value is read back, not migrated")
        #expect(defaults.string(forKey: "pipelineMode.v2") == "searchableRedaction", "the stored value is left")
        #expect(PipelineMode.effective(paranoid: settings.paranoidMode, override: nil, setting: settings.pipelineMode)
                == .secureRasterization)
    }

    @Test("A run asked for Searchable, over a stored Searchable setting, writes its text page in Secure Rasterization",
          .timeLimit(.minutes(3)))
    func runAskedForSearchableIsSecure() async throws {
        let coord = try InkStripRunEntryTests.coordinator()
        coord.settingsState.paranoidMode = false
        coord.settingsState.pipelineMode = .searchableRedaction
        let region = InkStripRunEntryTests.hand(
            InkStripRunEntryTests.inkRect(line: 5, phrase: "Marisol", through: "Vance-Oduya"))
        coord.redactionState.addRegion(region, page: 0, undoManager: nil)
        coord.runFullPipeline(documentOverride: .searchableRedaction)
        let run = try #require(coord.documentState.activePipelineTask, "the run started")
        await run.value
        guard case .verified(let report) = coord.documentState.phase else {
            Issue.record("the run did not end verified: \(coord.documentState.phaseKind)")
            return
        }
        #expect(coord.documentState.lastUsedPipelineMode == .secureRasterization)
        #expect(report.perPageModes == [.secureRasterization], "the page's text layer is not kept")
    }

    @Test("No view offers a mode: no Switch Mode row, no mode picker, no Searchable label")
    func noViewOffersAMode() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let views = root.appendingPathComponent("Sources/ResectaApp")
        let files = try #require(FileManager.default.enumerator(at: views, includingPropertiesForKeys: nil))
        var read = 0
        for case let file as URL in files where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(!text.contains("\"Switch Mode\""), "\(file.lastPathComponent)")
            #expect(!text.contains("\"Searchable Redaction\""), "\(file.lastPathComponent)")
            #expect(!text.contains("\"Default Mode\""), "\(file.lastPathComponent)")
            #expect(!text.contains(".tag(PipelineMode.searchableRedaction)"), "\(file.lastPathComponent)")
            read += 1
        }
        #expect(read > 100, "the app's sources were read")
    }
}
