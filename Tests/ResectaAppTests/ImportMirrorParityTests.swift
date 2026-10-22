import Testing
import Foundation
@testable import ResectaApp

// The engine test tree's robustness runner mirrors the import's validation
// stages (its `importMirror`, and `imageImportMirror` for the image route)
// so the host campaign reaches the refusals the app does. These pins read
// both sources and assert the ordered refusal classes are one list per
// route: a stage added on either side alone fails here.

@Suite("Import mirror parity", .tags(.importFlow))
struct ImportMirrorParityTests {

    @Test("The import's ordered refusal classes equal the robustness runner's mirror")
    func refusalClassesMatchTheMirror() throws {
        let loader = try loadRepoFile("Sources/ResectaApp/Services/Import/PDFImportLoader.swift")
        let runner = try loadRepoFile(
            "Packages/RedactionEngine/Tests/RedactionEngineTests/FuzzTests/RobustnessRunnerTests.swift")
        let mirror = try #require(
            functionText(from: "static func importMirror(", upTo: "// MARK: - Fixture table", in: runner))

        let appClasses = try matches(of: #"\.(?:importError|redactionError)\(\.(\w+)"#, in: loader)
        let mirrorClasses = try matches(of: #"(?:errorClass: "|pageError = ")(\w+)""#, in: mirror)

        #expect(appClasses.count >= 6, "the loader's stages were not read: \(appClasses)")
        #expect(appClasses == mirrorClasses, "app \(appClasses) vs mirror \(mirrorClasses)")
    }

    @Test("The image loader's ordered refusal classes equal the mirror's image route")
    func imageRefusalClassesMatchTheMirror() throws {
        let loader = try loadRepoFile("Sources/ResectaApp/Services/Import/ImageImportLoader.swift")
        let route = try loadRepoFile(
            "Packages/RedactionEngine/Tests/RedactionEngineTests/FuzzTests/ImportMirrorImageRoute.swift")
        // The per-image stages: from the page function to the end of the file
        // (the redraw and the page-image encode are its helpers).
        let stages = try #require(functionText(from: "static func pageImage(", upTo: "\n}\n", in: loader + "\n}\n"))
        let mirror = try #require(
            functionText(from: "static func imagePageMirror(", upTo: "// MARK: - The page", in: route))

        let appClasses = try matches(of: #"\.importError\(\.(\w+)"#, in: stages)
        let mirrorClasses = try matches(of: #"ImageMirrorRefusal\("(\w+)"\)"#, in: mirror)

        #expect(appClasses.count >= 8, "the image loader's stages were not read: \(appClasses)")
        #expect(appClasses == mirrorClasses, "app \(appClasses) vs mirror \(mirrorClasses)")
    }

    // MARK: - Helpers

    private func matches(of pattern: String, in text: String) throws -> [String] {
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    private func functionText(from start: String, upTo end: String, in text: String) -> String? {
        guard let startRange = text.range(of: start),
              let endRange = text.range(of: end, range: startRange.upperBound..<text.endIndex) else {
            return nil
        }
        return String(text[startRange.lowerBound..<endRange.lowerBound])
    }

    private func repoRoot(file: StaticString = #filePath) -> URL {
        URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()   // Tests/ResectaAppTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // <repo root>
    }

    private func loadRepoFile(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot().appendingPathComponent(relativePath), encoding: .utf8)
    }
}
