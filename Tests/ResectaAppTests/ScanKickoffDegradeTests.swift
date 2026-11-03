import Testing
import Foundation
@testable import ResectaApp
@testable import RedactionEngine

// The Scan kickoff's degrade surface when the name tagger is silent. On iOS 27
// each kickoff tags a fixed literal name; a miss reports the name model as
// failed, and the kickoff raises the names-only toast and banner through the
// same flag the load-time failures use (`DegradedBannerTests`). A session
// already degraded for another reason gains the name model in its failure
// list without a second toast. Before iOS 27, and on a tagging canary, the
// kickoff reads the load diagnostics unchanged.

@Suite("Scan kickoff: degrade on a silent name tagger")
@MainActor
struct ScanKickoffDegradeTests {

    static var onIOS27: Bool {
        if #available(iOS 27, *) { return true }
        return false
    }

    static let ner = GazetteerLoadDiagnostics.Gazetteer.nerNameModel.rawValue

    static func kickoffDiagnostics(canaryTags: Bool) async -> GazetteerLoadDiagnostics {
        await PIIDetector.$_nameCanaryOverride.withValue(canaryTags) {
            await DocumentSearcher.scanKickoffDiagnostics()
        }
    }

    @Test("A silent tagger at kickoff raises the names-only degrade on iOS 27; before iOS 27 nothing changes")
    func silentTaggerRaisesNamesOnlyDegrade() async {
        let shared = DocumentSearcher.sharedLoadDiagnostics
        let diagnostics = await Self.kickoffDiagnostics(canaryTags: false)
        let state = RedactionState()
        let toast = state.noteScanKickoffDiagnostics(diagnostics)

        guard Self.onIOS27 else {
            #expect(diagnostics == shared)
            #expect(state.autoDetectionDegraded == shared.didDegrade)
            #expect(state.autoDetectionDegradeFailures == shared.failedGazetteers)
            return
        }
        #expect(state.autoDetectionDegraded, "a silent tagger must raise the degrade")
        #expect(state.autoDetectionDegradeFailures.contains(Self.ner))
        #expect(toast == DetectionDegradeCopy.toast(failedGazetteers: state.autoDetectionDegradeFailures))
        // The verification degrade line reads the same flags.
        state.recordDetectionRun(.staged)
        #expect(state.lastDetectionRun?.degradeFailures?.contains(Self.ner) == true)
        if shared.didDegrade {
            TestGate.skip("[load diagnostics] this runtime already fails \(shared.failedGazetteers) at load; the names-only copy needs a clean load.")
            return
        }
        // A clean load: the name model alone, so the names-only copy.
        #expect(state.autoDetectionDegradeFailures == [Self.ner])
        #expect(DetectionDegradeCopy.isNEROnly(state.autoDetectionDegradeFailures))
        #expect(toast?.contains("name model") == true)
        #expect(DetectionDegradeCopy.banner(failedGazetteers: state.autoDetectionDegradeFailures)
            .contains("name model"))
    }

    @Test("A session already degraded for the corpus gains the name model without a second toast")
    func alreadyDegradedAppendsNameModel() {
        let state = RedactionState()
        state.autoDetectionDegraded = true
        state.autoDetectionDegradeFailures = ["NameGazetteer"]
        let diagnostics = GazetteerLoadDiagnostics()
            .appending(.nerNameModel, reason: "test")
        let toast = state.noteScanKickoffDiagnostics(diagnostics)
        #expect(toast == nil, "the session's degrade toast was already posted")
        #expect(state.autoDetectionDegraded)
        #expect(state.autoDetectionDegradeFailures == ["NameGazetteer", Self.ner])
        // A second kickoff with the same failure lists it once.
        #expect(state.noteScanKickoffDiagnostics(diagnostics) == nil)
        #expect(state.autoDetectionDegradeFailures == ["NameGazetteer", Self.ner])
        // The mixed list keeps the corpus copy.
        #expect(!DetectionDegradeCopy.isNEROnly(state.autoDetectionDegradeFailures))
    }

    @Test("A silent tagger on a session already degraded for the corpus: the name model joins on iOS 27, no second toast")
    func silentTaggerOnDegradedSession() async {
        let diagnostics = await Self.kickoffDiagnostics(canaryTags: false)
        let state = RedactionState()
        state.autoDetectionDegraded = true
        state.autoDetectionDegradeFailures = ["NameGazetteer"]
        let toast = state.noteScanKickoffDiagnostics(diagnostics)
        #expect(toast == nil)
        #expect(state.autoDetectionDegraded)
        // Before iOS 27 the kickoff reports the name model only when the
        // load did (the asset absent).
        let reportsName = Self.onIOS27
            || DocumentSearcher.sharedLoadDiagnostics.failedGazetteers.contains(Self.ner)
        #expect(state.autoDetectionDegradeFailures
            == (reportsName ? ["NameGazetteer", Self.ner] : ["NameGazetteer"]))
    }

    @Test("Where the name model tags a sentence in this process, the live kickoff adds nothing to the load")
    func liveKickoffOnATaggingModel() async {
        let text = "Last Friday Robert Miller met Sarah Thompson at the branch, and the clerk gave each of them a copy of the signed loan papers."
        let tagger = NameDetector.makeNameTagger(for: text)
        var names: [String] = []
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType) { tag, range in
            if tag == .personalName { names.append(String(text[range])) }
            return true
        }
        let shared = DocumentSearcher.sharedLoadDiagnostics
        let kickoff = await DocumentSearcher.scanKickoffDiagnostics()
        print("ScanKickoffDegrade: names=\(names) load=\(shared.failedGazetteers) kickoff=\(kickoff.failedGazetteers)")
        guard !names.isEmpty else {
            TestGate.skip("[NER asset] the name model tags nothing in this process; the healthy-tagger check needs it.")
            return
        }
        #expect(kickoff == shared, "a tagging name model must not raise the degrade at kickoff")
    }

    @Test("A tagging canary changes nothing: no flag, no toast, on a clean load")
    func taggingCanaryChangesNothing() async {
        let shared = DocumentSearcher.sharedLoadDiagnostics
        let diagnostics = await Self.kickoffDiagnostics(canaryTags: true)
        #expect(diagnostics == shared)
        let state = RedactionState()
        let toast = state.noteScanKickoffDiagnostics(diagnostics)
        #expect(state.autoDetectionDegraded == shared.didDegrade)
        #expect((toast != nil) == shared.didDegrade)
    }
}
