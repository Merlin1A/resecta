import Testing
import Foundation
@testable import ResectaApp
import RedactionEngine

// Paranoid Mode forces Secure Rasterization: the run, the verify-only
// re-run and the editor's Switch Mode read one rule, so Switch Mode never
// offers a mode the run would not use, and it says why it is unavailable
// with the Settings sentence.

@Suite("Effective pipeline mode")
struct EffectivePipelineModeTests {

    @Test("Paranoid Mode forces Secure Rasterization over any override or setting")
    func paranoidForcesSecure() {
        for override in [nil, PipelineMode.secureRasterization, .searchableRedaction] {
            for setting in PipelineMode.allCases {
                #expect(PipelineMode.effective(paranoid: true, override: override, setting: setting)
                        == .secureRasterization)
            }
        }
    }

    @Test("Without Paranoid Mode the document's override wins, else the setting")
    func overrideThenSetting() {
        #expect(PipelineMode.effective(paranoid: false, override: .searchableRedaction, setting: .secureRasterization)
                == .searchableRedaction)
        #expect(PipelineMode.effective(paranoid: false, override: nil, setting: .searchableRedaction)
                == .searchableRedaction)
    }

    @MainActor
    @Test("Switch Mode is unavailable under Paranoid Mode and says why with the Settings sentence")
    func switchModeUnderParanoid() {
        #expect(SettingsView.paranoidForcesSecureLine == "Pipeline mode is forced to Secure Rasterization.")
        #expect(!DocumentEditorView.switchModeAvailable(phaseKind: .editing, paranoid: true))
        #expect(DocumentEditorView.switchModeAvailable(phaseKind: .editing, paranoid: false))
        #expect(!DocumentEditorView.switchModeAvailable(phaseKind: .verified, paranoid: false))
        #expect(DocumentEditorView.switchModeHint(paranoid: true) == SettingsView.paranoidForcesSecureLine)
        #expect(DocumentEditorView.switchModeHint(paranoid: false) == "")
    }

    @Test("On iOS 27 the Switch Mode list draws each mode's name with no hyphenation, so a name breaks only at its space")
    func modeNamesHaveNoHyphenationOnIOS27() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent(
            "Sources/ResectaApp/Views/DocumentEditorView+ModeOverride.swift"), encoding: .utf8)
        let function = try #require(source.range(of: "static func modeName(_ words: String) -> Text {")?.lowerBound)
        let body = source[function...].prefix(400)
        #expect(body.contains("if #available(iOS 27, *) {"))
        #expect(body.contains("name.languageIdentifier = \"zxx\""))
        #expect(body.contains("return Text(words)"), "earlier systems draw the plain name")
        #expect(source.contains("Label { Self.modeName(\"Secure Rasterization\") }"))
        #expect(source.contains("Label { Self.modeName(\"Searchable Redaction\") }"))
        #expect(source.contains("Label { Text(\"Switch Mode\") }"))
        // The trial's launch argument never reaches the app's sources.
        let sources = root.appendingPathComponent("Sources/ResectaApp")
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var read = 0
        for case let file as URL in files where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(!text.contains("modeMenuVariant"), "\(file.lastPathComponent)")
            read += 1
        }
        #expect(read > 100, "the app's sources were read")
    }
}
