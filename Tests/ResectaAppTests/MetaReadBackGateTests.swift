import Testing
import Foundation

// The app keeps an export only when its read-back held: the coordinator's
// gate before the atomic rename reads `metaReadBackHeld` beside the page
// count and the whole-patch flag, as the engine's own page loop does.

@Suite("The export is kept only when its read-back held")
struct MetaReadBackGateTests {

    private func source(_ path: String) throws -> String {
        try String(contentsOf: URL(fileURLWithPath: "\(#filePath)")
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(path), encoding: .utf8)
    }

    @Test("The coordinator's gate before the rename reads the read-back")
    func coordinatorGateReadsTheReadBack() throws {
        let text = try source("Sources/ResectaApp/State/PipelineCoordinator+Rasterization.swift")
        let gate = try #require(text.range(of: "await reconstructor.metaReadBackHeld else {"), "the gate reads the read-back")
        let rename = try #require(text.range(of: "replaceItemAt(outputURL, withItemAt: tempURL)"), "the rename")
        #expect(gate.upperBound < rename.lowerBound)
        let guardStart = try #require(text.range(of: "guard await reconstructor.writtenPageCount == pages.count,"))
        let between = text[guardStart.lowerBound..<gate.upperBound]
        #expect(between.contains("await reconstructor.infoPatchesWhole,"))
        #expect(text.components(separatedBy: "metaReadBackHeld").count == 2, "read once, in the gate")
    }
}
