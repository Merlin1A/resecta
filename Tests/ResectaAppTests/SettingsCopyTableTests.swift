import Testing
@testable import ResectaApp

// Each line the Redaction Boxes section and the edited Settings lines show,
// byte for byte against the words of record.

@Suite("Settings: the words of each line")
@MainActor
struct SettingsCopyTableTests {

    nonisolated enum Line: CaseIterable, Sendable {
        case set01
        case set02
        case set03
        case set03TwoKinds
        case set06
        case set10
        case set11
        case set12
        case fr08c
    }

    @Test("Settings shows nine lines of record")
    func lineCount() {
        #expect(Line.allCases.count == 9)
    }

    private static func shown(_ line: Line) -> String {
        switch line {
        case .set01: RedactionBoxesCopy.sectionHeader
        case .set02: RedactionBoxesCopy.switchName
        case .set03: RedactionBoxesCopy.footer()
        case .set03TwoKinds: RedactionBoxesCopy.footer(measured: [.leftAlignedParagraph, .justifiedParagraph])
        case .set06: SettingsView.secureModeDescription
        case .set10: SettingsView.runInProgressTitle
        case .set11: SettingsView.runInProgressBody
        case .set12: SettingsView.paranoidModeFooter
        case .fr08c: RedactionBoxesCopy.switchHint
        }
    }

    private static func wanted(_ line: Line) -> String {
        switch line {
        case .set01: "Redaction Boxes"
        case .set02: "Cover Other Words"
        case .set03: "A box removes the text under it, but its width can still show how long that text was. That can be enough to tell which name or month it was, or how many digits an amount has.\n\nWhere it can, Cover Other Words runs a box across every line it touches, out to where the lines above and below reach, and stops short of words that belong to another column, cell, or field. It can cover the other words there too, and that is its cost. It leaves a box as it is over a scan or a picture, on a page with text with no ink of its own, or on a page that is half or more a picture. It also leaves a box as it is over print that does not run upright and left to right, where there is too little unselected text above and below it to show its column, and where you drew, moved, or resized the box by hand. A widened box can still show about how long its text was: in a paragraph, by where the lines break, and more closely each time the same text appears."
        case .set03TwoKinds: "A box removes the text under it, but its width can still show how long that text was. That can be enough to tell which name or month it was, or how many digits an amount has.\n\nWhere it can, Cover Other Words runs a box across every line it touches, out to where the lines above and below reach, and stops short of words that belong to another column, cell, or field. It can cover the other words there too, and that is its cost. It leaves a box as it is over a scan or a picture, on a page with text with no ink of its own, or on a page that is half or more a picture. It also leaves a box as it is over print that does not run upright and left to right, where there is too little unselected text above and below it to show its column, and where you drew, moved, or resized the box by hand. In Resecta's test, Cover Other Words reduced what the page shows about how long the text was on lines of a left-aligned paragraph and lines of a justified paragraph. A widened box can still show about how long its text was: in a paragraph, by where the lines break, and more closely each time the same text appears."
        case .set06: "Produces image-only output with all text removed, so the PDF has no text to search or copy. The simplest approach — recommended when redaction confidence is the top priority. A court or regulator that requires searchable PDFs may refuse an image-only PDF."
        case .set10: "Redaction in progress"
        case .set11: "A redaction is running. Changes apply to the next one."
        case .set12: "Paranoid Mode always runs the checks."
        case .fr08c: "Where it can, runs boxes out along their lines, stopping short of words in another column, cell, or field. Can cover the other words there."
        }
    }

    @Test("Each line reads as its words of record", arguments: Line.allCases)
    func eachLine(_ line: Line) {
        #expect(Self.shown(line) == Self.wanted(line))
    }
}
