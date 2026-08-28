import Testing
import Foundation
@testable import ResectaApp

// Source-scanning contract pins for `DocumentEditorView.swift` surfaces
// that render through a `private` type or a `@ViewBuilder` computed
// property with no pure-function seam to unit-test directly — mirrors
// `HonestySurfacesTests.loadRepoFile`'s technique.
//
//  - `DetectionSummaryBanner`'s glyph tint gates on
//    `model.isWarning` instead of an unconditional `.orange`.
//  - The editor toolbar's routine actions render
//    neutral (`.tint(.primary)` on the three `ToolbarItemGroup`s); the
//    Redact button is the one designated emphasis action and carries
//    the brand tint explicitly.
//  - 1.1.0 Home swap: the iPhone overflow group leads with Home and the
//    former file-import entry is gone from the editor.
//  - The home screen's Settings gear renders neutral (the same toolbar
//    rule applied to `HomeView.swift`).

@Suite("DocumentEditorView source contracts")
struct DocumentEditorViewSourceContractsTests {

    @Test("DetectionSummaryBanner glyph has no unconditional .orange and gates on isWarning")
    func detectionSummaryBannerTintGatesOnIsWarning() throws {
        let source = try loadRepoFile("Sources/ResectaApp/Views/DocumentEditorView.swift")
        guard let structRange = source.range(of: "private struct DetectionSummaryBanner"),
              let bodyEnd = source.range(of: "\n    }", range: structRange.upperBound..<source.endIndex)
        else {
            Issue.record("Could not locate DetectionSummaryBanner")
            return
        }
        let body = source[structRange.upperBound..<bodyEnd.lowerBound]
        #expect(!body.contains(".foregroundStyle(.orange)"),
                "the glyph must not carry an unconditional .orange tint")
        #expect(body.contains("model.isWarning") && body.contains("SemanticColor.warningTint"),
                "the glyph tint must gate on model.isWarning and reference the warningTint token")
    }

    @Test("The three toolbar groups render neutral")
    func toolbarGroupsCarryNeutralTint() throws {
        let source = try loadRepoFile("Sources/ResectaApp/Views/DocumentEditorView.swift")
        let occurrences = source.components(separatedBy: ".tint(.primary)").count - 1
        #expect(occurrences == 3,
                "expected 3 neutral-tint toolbar groups (leading, trailing, secondaryAction); found \(occurrences)")
    }

    @Test("The Redact button is the one designated emphasis action")
    func redactButtonCarriesBrandTint() throws {
        let source = try loadRepoFile("Sources/ResectaApp/Views/DocumentEditorView.swift")
        guard let buttonRange = source.range(of: "Button(\"Redact\", systemImage: \"scissors\")") else {
            Issue.record("Could not locate the Redact button")
            return
        }
        let windowEnd = source.index(
            buttonRange.upperBound,
            offsetBy: 300,
            limitedBy: source.endIndex
        ) ?? source.endIndex
        let window = source[buttonRange.upperBound..<windowEnd]
        #expect(window.contains(".tint(ResectaTokens.BrandTeal.tint)"),
                "the Redact button must carry the explicit brand tint")
        // Exactly one brand-tint literal in the whole file — the ONE
        // designated emphasis action, not a second quiet re-introduction
        // of teal elsewhere in the toolbar.
        let brandTintOccurrences = source.components(
            separatedBy: ".tint(ResectaTokens.BrandTeal.tint)").count - 1
        #expect(brandTintOccurrences == 1,
                "expected exactly 1 explicit brand-tint literal (the Redact button); found \(brandTintOccurrences)")
    }

    @Test("1.1.0 Home swap — the file-import entry is gone and Home leads the overflow group")
    func homeLeadsSecondaryActionGroup() throws {
        let source = try loadRepoFile("Sources/ResectaApp/Views/DocumentEditorView.swift")
        #expect(!source.contains("Open Document"),
                "the editor's former file-import entry must not return (opening a file is HomeView's job)")
        #expect(!source.contains("openDocumentButton"),
                "the retired property must stay deleted with its mount")
        guard let groupStart = source.range(of: "private var secondaryActionToolbarItems: some View {"),
              let groupEnd = source.range(of: ".tint(.primary)",
                                          range: groupStart.upperBound..<source.endIndex)
        else {
            Issue.record("Could not locate secondaryActionToolbarItems")
            return
        }
        let group = source[groupStart.upperBound..<groupEnd.lowerBound]
        guard let home = group.range(of: "homeButton"),
              let selection = group.range(of: "selectionMenu")
        else {
            Issue.record("secondaryActionToolbarItems must mount homeButton and selectionMenu")
            return
        }
        #expect(home.lowerBound < selection.lowerBound,
                "Home must be the first of our items in the overflow group")
    }

    @Test("HomeView's Settings button renders neutral, like the editor toolbar")
    func homeSettingsButtonCarriesNeutralTint() throws {
        let source = try loadRepoFile("Sources/ResectaApp/Views/HomeView.swift")
        guard let buttonRange = source.range(of: "Button(\"Settings\", systemImage: \"gearshape\")") else {
            Issue.record("Could not locate HomeView's Settings button")
            return
        }
        let windowEnd = source.index(
            buttonRange.upperBound,
            offsetBy: 600,
            limitedBy: source.endIndex
        ) ?? source.endIndex
        let window = source[buttonRange.upperBound..<windowEnd]
        #expect(window.contains(".tint(.primary)"),
                "the home screen's Settings gear must carry the neutral tint")
    }

    /// Mirrors `HonestySurfacesTests.loadRepoFile`.
    private func loadRepoFile(
        _ relativePath: String, from file: StaticString = #filePath
    ) throws -> String {
        let repoRoot = URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()   // Tests/ResectaAppTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // <repo root>
        return try String(
            contentsOf: repoRoot.appendingPathComponent(relativePath),
            encoding: .utf8)
    }
}
