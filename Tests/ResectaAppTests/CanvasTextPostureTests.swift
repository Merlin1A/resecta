import Testing
import Foundation
import PDFKit
import UIKit
@testable import ResectaApp

// The canvas text posture, pinned at the source: the page text never
// reaches the pasteboard, PDFKit's own selection is never created or read,
// markup mode is set once and never turned off, and the canvas view answers
// no to the edit actions and drops the edit, look-up, learn and share menus.

@Suite("Canvas text posture")
struct CanvasTextPostureTests {

    private static let repoRoot = URL(fileURLWithPath: "\(#filePath)")
        .deletingLastPathComponent()   // Tests/ResectaAppTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // <repo root>

    /// Every Swift file under `relativeDirectory`, keyed by its path from the repo root.
    private static func swiftSources(_ relativeDirectory: String) throws -> [String: String] {
        let root = repoRoot.appendingPathComponent(relativeDirectory)
        let enumerator = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var files: [String: String] = [:]
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let relative = String(url.path.dropFirst(repoRoot.path.count + 1))
            files[relative] = try String(contentsOf: url, encoding: .utf8)
        }
        return files
    }

    private static func occurrences(of pattern: String, in files: [String: String]) throws -> [String: Int] {
        let regex = try NSRegularExpression(pattern: pattern)
        var counts: [String: Int] = [:]
        for (path, text) in files {
            let n = regex.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
            if n > 0 { counts[path] = n }
        }
        return counts
    }

    private static let viewFile = "Sources/ResectaApp/Views/PDFDocumentView.swift"

    @Test("Markup mode is written once, to true, in the document view")
    func markupModeIsSetOnce() throws {
        let app = try Self.swiftSources("Sources")
        #expect(try Self.occurrences(of: #"isInMarkupMode"#, in: app) == [Self.viewFile: 1])
        #expect(try Self.occurrences(of: #"isInMarkupMode = true"#, in: app) == [Self.viewFile: 1])
    }

    @Test("No pasteboard and no PDFKit-owned selection in the app or the engine sources")
    func noPasteboardOrPDFKitSelection() throws {
        let sources = try Self.swiftSources("Sources")
            .merging(try Self.swiftSources("Packages/RedactionEngine/Sources")) { a, _ in a }
        #expect(sources.count > 50)
        for pattern in [#"UIPasteboard"#, #"\bcurrentSelection\b"#, #"setCurrentSelection"#,
                        #"highlightedSelections"#, #"selection\(forWordAt"#, #"withGranularity"#,
                        #"selectionForWord\(at"#, #"selectionForLine\(at"#, #"selection\(from:"#] {
            #expect(try Self.occurrences(of: pattern, in: sources).isEmpty, "\(pattern)")
        }
    }

    @Test("The edit suppression lives in the canvas view alone")
    func suppressionIsTheCanvasViewsAlone() throws {
        let app = try Self.swiftSources("Sources")
        #expect(try Self.occurrences(of: #"func canPerformAction\("#, in: app) == [Self.viewFile: 1])
        #expect(try Self.occurrences(of: #"func buildMenu\("#, in: app) == [Self.viewFile: 1])
        #expect(try Self.occurrences(of: #"selectAll\("#, in: app) == [Self.viewFile: 1])
        let view = try #require(app[Self.viewFile])
        let classStart = try #require(view.range(of: "final class FitFlooredPDFView"))
        let suppression = try #require(view.range(of: "override func canPerformAction("))
        let menu = try #require(view.range(of: "override func buildMenu(with builder"))
        let selectAll = try #require(view.range(of: "selectAll("))
        #expect(classStart.lowerBound < suppression.lowerBound)
        #expect(classStart.lowerBound < menu.lowerBound)
        #expect(classStart.lowerBound < selectAll.lowerBound)
        #expect(view.contains("[.standardEdit, .lookup, .learn, .share]"))
    }

    @Test("A canvas view holding a document answers no to the edit actions and keeps other actions")
    @MainActor
    func canvasViewRefusesEditActions() throws {
        let view = FitFlooredPDFView(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
        PDFViewCoordinator().assign(makeTextPDFDocument(text: "Jane Doe 123-45-6789"), to: view)
        view.layoutIfNeeded()
        for action in [#selector(UIResponderStandardEditActions.copy(_:)),
                       #selector(UIResponderStandardEditActions.cut(_:)),
                       #selector(UIResponderStandardEditActions.paste(_:)),
                       #selector(UIResponderStandardEditActions.select(_:)),
                       #selector(UIResponderStandardEditActions.selectAll(_:))] {
            #expect(!view.canPerformAction(action, withSender: nil), "\(action)")
        }
    }
}
