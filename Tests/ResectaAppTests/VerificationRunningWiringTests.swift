import Testing
import Foundation
import PDFKit
@testable import ResectaApp
@testable import RedactionEngine

/// The running screen's wiring. `VerificationProgressLineTests` pins the
/// pure functions; these pin the places that call them: the runner
/// publishes progress on every engine event, the editor stamps the moment
/// the results appear, the bar's trailing button reads that stamp, and the
/// running screen speaks its reminder.
@Suite("The running screen's wiring")
@MainActor
struct VerificationRunningWiringTests {

    // MARK: - The runner

    /// Every event a run sends its sink, in order.
    final class Recorder {
        var events: [PipelineRunEvent] = []
    }

    /// A one-page Secure run with one box, through the runner, its events
    /// recorded and applied as the coordinator's own sink applies them.
    static func recordedRun() async throws -> (progress: [DocumentState.VerificationProgress], report: VerificationReport) {
        let coord = makeLoadedCoordinator()
        coord.redactionState.addRegion(
            RedactionRegion(id: UUID(), normalizedRect: CGRect(x: 0.1, y: 0.8, width: 0.8, height: 0.05), source: .manual),
            page: 0, undoManager: nil)
        let recorder = Recorder()
        let runner = PipelineRunner(coordinator: coord, sink: { event in
            recorder.events.append(event)
            coord.apply(event)
        })
        let settings = PipelineCoordinator.RunSettings.snapshot(from: coord.settingsState)
        _ = try await runner.run(kind: .full(effectiveMode: .secureRasterization, runSettings: settings))
        var progress: [DocumentState.VerificationProgress] = []
        var report: VerificationReport?
        for event in recorder.events {
            switch event {
            case .phase(.verifying(let step)): progress.append(step)
            case .verified(let verified, _): report = verified
            default: break
            }
        }
        return (progress, try #require(report, "the run ended with a report"))
    }

    @Test("A real run publishes progress on every check's finish: the last step counts every check, none running",
          .timeLimit(.minutes(3)))
    func runnerPublishesEveryFinish() async throws {
        let (progress, report) = try await Self.recordedRun()
        let last = try #require(progress.last, "the run published progress")
        let ran = report.layers.map(\.layer)
        #expect(!ran.isEmpty)
        #expect(Set(last.completedLayers.map(\.layer)).isSubset(of: Set(ran)),
                "the last step names only checks the report has")
        #expect(last.completedLayers.count == last.totalLayers, "never one short")
        #expect(last.running == nil, "nothing still running once every check is done")
        // One step per finish: the count of finished checks rises by one
        // at each step that adds one, and never falls.
        let counts = progress.map(\.completedLayers.count)
        #expect(zip(counts, counts.dropFirst()).allSatisfy { $0 <= $1 }, "never falls: \(counts)")
        let rises = zip(counts, counts.dropFirst()).filter { $0 < $1 }
        #expect(rises.allSatisfy { $1 == $0 + 1 }, "each finish is its own step: \(counts)")
        #expect(rises.count == last.totalLayers - (counts.first ?? 0), "one step per finish: \(counts)")
    }

    // MARK: - A typed search

    static func request(_ kind: AppliedSearchQuery.Kind, origin: SearchRecheckRequest.Origin) -> SearchRecheckRequest {
        SearchRecheckRequest(
            record: AppliedSearchRecord(query: AppliedSearchQuery(kind: kind, options: SearchOptions()), foundCount: 1),
            appliedCount: 1, appliedPages: [0], origin: origin)
    }

    @Test("A typed search is a request the user applied that is not a Scan; a Scan or the run's own sweep is not one")
    func appliedTypedSearchCases() {
        let typed = Self.request(.text("Okafor"), origin: .applied)
        let pattern = Self.request(.regex("[0-9]{3}"), origin: .applied)
        let terms = Self.request(.multiTerm(["Okafor", "Hartwell"]), origin: .applied)
        let scan = Self.request(.piiScan(categories: [.ssn]), origin: .applied)
        let sweep = Self.request(.piiScan(categories: Set(PIICategory.allCases)), origin: .sweep)
        let sweptText = Self.request(.text("Okafor"), origin: .sweep)
        #expect(PipelineRunner.appliedTypedSearch([typed]))
        #expect(PipelineRunner.appliedTypedSearch([pattern]))
        #expect(PipelineRunner.appliedTypedSearch([terms]))
        #expect(!PipelineRunner.appliedTypedSearch([scan]), "a Scan is not typed")
        #expect(!PipelineRunner.appliedTypedSearch([sweep]), "the run's sweep is not applied")
        #expect(!PipelineRunner.appliedTypedSearch([sweptText]), "only an applied request counts")
        #expect(!PipelineRunner.appliedTypedSearch([scan, sweep]))
        #expect(PipelineRunner.appliedTypedSearch([scan, sweep, typed]), "one typed search among others")
    }

    // MARK: - The views' source

    /// A repository file read relative to this test's own path, each run
    /// of white space read as one space.
    static func source(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    @Test("Source pin: the editor stamps the moment the running checks give way to the results, and hands it to the bar")
    func editorStampsResultsMoment() throws {
        let source = try Self.source("Sources/ResectaApp/Views/DocumentEditorView.swift")
        #expect(source.contains(
            ".onChange(of: documentState.phaseKind) { oldKind, newKind in if oldKind == .verifying, newKind == .verified { resultsAppearedAt = Date() } }"))
        #expect(source.components(separatedBy: "resultsAppearedAt = ").count - 1 == 1, "set in that one place")
        #expect(source.contains("openSettings: openSettings, resultsAppearedAt: resultsAppearedAt )"))
    }

    @Test("Source pin: the bar's Settings button reads the stamp before it opens Settings")
    func toolbarReadsTheStamp() throws {
        let source = try Self.source("Sources/ResectaApp/Views/DocumentEditorToolbar.swift")
        #expect(source.contains(
            "Button(\"Settings\", systemImage: \"gearshape\") { guard Self.acceptsTrailingTap(resultsAppearedAt: resultsAppearedAt, now: Date()) else { return } openSettings() }"))
    }

    @Test("Source pin: the running screen speaks its still-checking reminder when one falls due")
    func reminderSpoken() throws {
        let source = try Self.source("Sources/ResectaApp/Views/VerificationProgressView.swift")
        #expect(source.contains(
            ".onChange(of: Self.stillCheckingDue(progress, now: context.date)) { _, due in guard due != nil else { return } AccessibilityNotification.Announcement( VerificationProgressLine.stillChecking(finished: state.finished, total: state.total) ).post() }"))
    }
}
