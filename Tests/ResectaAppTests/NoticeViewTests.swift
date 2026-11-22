import Testing
import SwiftUI
import UIKit
@testable import ResectaApp

// The notice's view: where it is drawn, what it never does, its tappable
// frames, its marks and their colours, its heights at the default size,
// its spoken line and the size it is drawn at. Every expectation is a
// number, a name or a list written out here.

@Suite("Notice view")
@MainActor
struct NoticeViewTests {

    // MARK: - Reading the source

    static func repoRoot(file: StaticString = #filePath) -> URL {
        URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()   // Tests/ResectaAppTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // <repo root>
    }

    static func codeLines(_ relativePath: String) throws -> [String] {
        let text = try String(contentsOf: repoRoot().appendingPathComponent(relativePath), encoding: .utf8)
        return text.components(separatedBy: "\n").filter {
            !$0.drop(while: { $0 == " " || $0 == "\t" }).hasPrefix("//")
        }
    }

    /// Every Swift file under `directory`, relative to the repository root.
    static func swiftFiles(under directory: String) throws -> [String] {
        let root = repoRoot().appendingPathComponent(directory)
        let enumerator = FileManager.default.enumerator(atPath: root.path)
        var files: [String] = []
        while let path = enumerator?.nextObject() as? String {
            if path.hasSuffix(".swift") { files.append(directory + "/" + path) }
        }
        return files.sorted()
    }

    static let noticeFiles = [
        "Sources/ResectaApp/Views/Messages/NoticeView.swift",
        "Sources/ResectaApp/Views/DocumentEditorView+TopBanner.swift",
        "Sources/ResectaApp/Views/DocumentEditorView+ResumeBanner.swift",
    ]

    @Test("Notices change no state when they leave the screen")
    func noLeavingHook() throws {
        for file in Self.noticeFiles {
            #expect(!(try Self.codeLines(file)).contains { $0.contains("onDisappear") }, "\(file)")
        }
    }

    @Test("A notice is drawn only in the band and in Settings")
    func drawnOnlyInTheBandAndSettings() throws {
        let files = try Self.swiftFiles(under: "Sources/ResectaApp")
        #expect(files.count > 100, "the source tree was not found")
        var drawers: Set<String> = []
        for file in files where try Self.codeLines(file).contains(where: { $0.contains("NoticeView(") }) {
            drawers.insert(file)
        }
        // The band's file, the paused notice's file (its view keeps its
        // name there), the view's own measure, and Settings' form.
        #expect(drawers == [
            "Sources/ResectaApp/Views/DocumentEditorView+TopBanner.swift",
            "Sources/ResectaApp/Views/DocumentEditorView+ResumeBanner.swift",
            "Sources/ResectaApp/Views/Messages/NoticeView.swift",
            "Sources/ResectaApp/Views/SettingsView.swift",
        ])
    }

    @Test("No notice has a line limit or a scroll view")
    func noLineLimitNoScroll() throws {
        let lines = try Self.codeLines("Sources/ResectaApp/Views/Messages/NoticeView.swift")
        #expect(!lines.contains { $0.contains("lineLimit") })
        #expect(!lines.contains { $0.contains("ScrollView") })
    }

    @Test("The old warning banner is gone")
    func oldBannerIsGone() throws {
        let name = "InlineWarning" + "Banner"
        var found: [String] = []
        for file in try Self.swiftFiles(under: "Sources") + Self.swiftFiles(under: "Tests") {
            for line in try Self.codeLines(file) where line.contains(name) { found.append(file) }
        }
        #expect(found.isEmpty, "\(found)")
    }

    @Test("A notice's mark takes the message surface's own colour")
    func markTakesTheSurfacesColour() throws {
        let text = try Self.codeLines("Sources/ResectaApp/Views/Messages/NoticeView.swift").joined(separator: "\n")
        for name in ["Ink.cautionMark", "Ink.stopMark", "Ink.noteMark"] {
            #expect(text.contains(name), "\(name)")
        }
        for name in ["SemanticColor.warnText", "SemanticColor.failText", "SemanticColor.attentionText"] {
            #expect(!text.contains(name), "\(name)")
        }
    }

    // MARK: - Tappable frames

    @Test("The tappable frames of the close, the action and the folded mark")
    func tappableFrames() {
        #expect(ResectaTokens.TouchTarget.minimum == 46)
        #expect(NoticeView.touchSide == ResectaTokens.TouchTarget.minimum)
        // The close's 26-wide place, tappable 46 by 46.
        #expect(NoticeView.Metrics.closeBoxWidth == 26)
        #expect(NoticeView.Metrics.closeBoxHeight == 30)
        // The 32-point capsule, tappable 46 tall.
        #expect(NoticeView.Metrics.actionHeight == 32)
        #expect(NoticeView.touchSide > NoticeView.Metrics.actionHeight)
        // The close's frame reaches to the capsule's edge and not over it.
        let reach = (Int(NoticeView.touchSide) - Int(NoticeView.Metrics.closeBoxWidth)) / 2
        #expect(reach == 10)
        #expect(reach <= Int(NoticeView.Metrics.capsuleToCloseBox))
        // The folded mark is drawn 44 and tappable 46.
        #expect(NoticeView.Metrics.foldedSide == 44)
        #expect(NoticeView.touchSide >= NoticeView.Metrics.foldedSide)
    }

    // MARK: - Marks

    /// A colour resolved under a scheme, as 0...255 components and alpha in hundredths.
    static func resolved(_ color: Color, _ style: UIUserInterfaceStyle) -> [Int] {
        let ui = UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        return [Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()), Int((a * 100).rounded())]
    }

    @Test("Each tone's mark is its symbol, coloured for the opposite scheme")
    func marksAndTheirColours() {
        #expect(NoticeView.symbol(for: .caution) == "exclamationmark.triangle.fill")
        #expect(NoticeView.symbol(for: .stop) == "exclamationmark.octagon.fill")
        #expect(NoticeView.symbol(for: .note) == "info.circle.fill")
        // On ink (the light appearance, content in the dark scheme) and on
        // paper (the dark appearance, content in the light scheme).
        #expect(Self.resolved(NoticeView.markColor(for: .caution), .dark) == [0xFF, 0x9F, 0x0A, 100])
        #expect(Self.resolved(NoticeView.markColor(for: .caution), .light) == [0x9A, 0x5B, 0x00, 100])
        #expect(Self.resolved(NoticeView.markColor(for: .stop), .dark) == [0xFF, 0x7A, 0x72, 100])
        #expect(Self.resolved(NoticeView.markColor(for: .stop), .light) == [0xC2, 0x26, 0x2E, 100])
        #expect(Self.resolved(NoticeView.markColor(for: .note), .dark) == [0xFF, 0xFF, 0xFF, 82])
        #expect(Self.resolved(NoticeView.markColor(for: .note), .light) == [0x11, 0x12, 0x14, 72])
        // Never the pass green.
        let green = ResectaTokens.SemanticColor.passText
        for tone in [MessageTone.caution, .stop, .note] {
            for style in [UIUserInterfaceStyle.dark, .light] {
                #expect(Self.resolved(NoticeView.markColor(for: tone), style) != Self.resolved(green, style), "\(tone)")
            }
        }
    }

    // MARK: - Heights and size

    static let paused = NoticeContent(id: .pausedRun, closes: true, identifier: "pausedNotice")
    static let oneLine = NoticeContent(id: .runInProgressSettings, closes: false, identifier: "oneLine")

    @Test("A notice at the default size is 44, 64 or 84 points tall at one, two or three lines")
    func heightsAtTheDefaultSize() {
        // 402 wide: the notice is 370, 16 in from each side.
        // The paused notice beside its Restart and close takes three lines.
        let paused = NoticeView.height(of: Self.paused, size: .large, width: 402)
        #expect(abs(paused - 84) <= 1, "the paused notice is \(paused)")
        let one = NoticeView.height(of: Self.oneLine, size: .large, width: 402)
        #expect(abs(one - 44) <= 1, "one line is \(one)")
    }

    @Test("The spoken line is the spoken text when one is given")
    func spokenLine() {
        let given = NoticeContent(id: .runInProgressSettings, detail: "Second line.", spokenText: "Spoken words.",
                                  closes: false, identifier: "x")
        #expect(given.spokenLine == "Spoken words.")
        let withDetail = NoticeContent(id: .runInProgressSettings, detail: "Second line.", closes: false, identifier: "x")
        #expect(withDetail.spokenLine == SettingsView.runInProgressTitle + " Second line.")
        #expect(Self.paused.spokenLine == "Processing was paused. Your drawn regions are preserved.")
    }

    @Test("A notice is drawn at the step's size and never below the third accessibility size")
    func drawnAtTheStepsSize() {
        let height = { (size: DynamicTypeSize) in NoticeView.height(of: Self.paused, size: size, width: 402) }
        // At the default size, within 262: drawn at it.
        #expect(MessageSizing.drawSize(person: .large, limit: 262, height: height) == .large)
        var rows = 0
        for person in DynamicTypeSize.allCases {
            for limit: CGFloat in [1, 236, 262, 10_000] {
                let size = MessageSizing.drawSize(person: person, limit: limit, height: height)
                #expect(size <= person, "\(person) at \(limit)")
                #expect(size >= min(person, .accessibility3), "\(person) at \(limit)")
                // At the third accessibility size or below, the person's size.
                if person <= .accessibility3 { #expect(size == person, "\(person) at \(limit)") }
                rows += 1
            }
        }
        #expect(rows == DynamicTypeSize.allCases.count * 4)
    }
}
