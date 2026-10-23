import Testing
@testable import ResectaApp

// The detection summary banner's pure model builder
// (`DocumentEditorView.detectionBannerModel`): one model per run
// outcome. Successful scans auto-dismiss; nothing-found and failed
// records persist until dismissed or replaced by the next run.

@Suite("Detection banner model")
@MainActor
struct DetectionBannerModelTests {

    @Test("A staged scan reports the record's own counts and auto-dismisses")
    func stagedScanReportsCounts() {
        let model = DocumentEditorView.detectionBannerModel(
            outcome: .staged,
            scanSummary: .init(foundCount: 12, pageCount: 3))
        #expect(model == .init(
            message: "Scan found 12 items across 3 pages",
            autoDismisses: true, isWarning: false))

        let singular = DocumentEditorView.detectionBannerModel(
            outcome: .staged,
            scanSummary: .init(foundCount: 1, pageCount: 1))
        #expect(singular?.message == "Scan found 1 item across 1 page")
    }

    @Test("A staged record without counts builds no banner")
    func stagedWithoutSummaryBuildsNothing() {
        #expect(DocumentEditorView.detectionBannerModel(
            outcome: .staged, scanSummary: nil) == nil)
    }

    @Test("Nothing found persists without a warning")
    func nothingFoundPersists() {
        let model = DocumentEditorView.detectionBannerModel(
            outcome: .nothingFound(pageCount: 3),
            scanSummary: .init(foundCount: 0, pageCount: 3))
        #expect(model == .init(
            message: "Scan found no items across 3 pages.",
            autoDismisses: false, isWarning: false))

        let singular = DocumentEditorView.detectionBannerModel(
            outcome: .nothingFound(pageCount: 1), scanSummary: nil)
        #expect(singular?.message == "Scan found no items across 1 page.")
    }

    @Test("A failed run is a persistent warning in the Search sheet's words")
    func failedIsPersistentWarning() {
        let model = DocumentEditorView.detectionBannerModel(
            outcome: .failed,
            scanSummary: .init(foundCount: 0, pageCount: 0))
        #expect(model == .init(
            message: "The last scan couldn't start because the document wasn't ready.",
            autoDismisses: false, isWarning: true))
    }
}
