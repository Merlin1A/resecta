import Testing
import Foundation

// The share-risk confirm starts the export only after its sheet is gone.
// The export presents the system share sheet from the top view controller;
// started while the confirm sheet is still up, the share sheet is presented
// on the confirm sheet and dismissed with it, and the editor stays on
// "Preparing for sharing…". The confirm records the family and closes the
// sheet; the sheet's onDismiss runs the completion. The UI test
// ShareRiskSheetUITests drives the path end to end; this pin reads the
// source so the order holds in the gating suite too.

@Suite("Share-risk confirm: the export starts after the sheet closes")
struct ShareRiskConfirmOrderTests {

    private func source() throws -> String {
        try String(contentsOf: URL(fileURLWithPath: "\(#filePath)")
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ResectaApp/Views/ShareRiskConfirm.swift"), encoding: .utf8)
    }

    /// The text of `ShareRiskConfirmPresentation`, up to the next type.
    private func presentation() throws -> String {
        let s = try source()
        let start = try #require(s.range(of: "struct ShareRiskConfirmPresentation"))
        let rest = s[start.upperBound...]
        let end = rest.range(of: "\nstruct ")?.lowerBound ?? rest.endIndex
        return String(rest[..<end])
    }

    @Test("onConfirm records the family and closes the sheet; it never starts the export itself")
    func confirmDoesNotExportWhileTheSheetIsUp() throws {
        let p = try presentation()
        let confirm = try #require(p.range(of: "onConfirm: {"))
        let cancel = try #require(p.range(of: "onCancel:", range: confirm.upperBound..<p.endIndex))
        let body = p[confirm.upperBound..<cancel.lowerBound]
        #expect(!body.contains("completeShareRiskConfirm"), "the export must not start while the confirm sheet is up")
        #expect(!body.contains("beginExport"))
        #expect(body.contains("kind = nil"), "the confirm closes the sheet")
    }

    @Test("The sheet's onDismiss runs the confirmed family's completion once")
    func onDismissRunsTheCompletion() throws {
        let p = try presentation()
        let dismiss = try #require(p.range(of: "onDismiss: {"))
        let content = try #require(p.range(of: "{ activeKind in", range: dismiss.upperBound..<p.endIndex))
        let body = p[dismiss.upperBound..<content.lowerBound]
        #expect(body.contains("completeShareRiskConfirm"))
        #expect(body.contains("confirmed = nil"), "a later dismissal (Go back, a swipe) does not export")
    }
}
