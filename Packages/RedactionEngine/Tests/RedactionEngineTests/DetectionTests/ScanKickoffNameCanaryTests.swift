import Testing
import Foundation
import NaturalLanguage
@testable import RedactionEngine

// The PII Scan kickoff's name check. The shared detector's load-time check
// runs once per process, and its canary tag pass runs only when the name
// scheme is NOT listed, so on iOS 27 a scheme that is listed while the tagger
// tags nothing (or a tagger that goes silent later in the process) gives a
// Scan with no names and no degraded banner. On iOS 27 each kickoff tags a
// fixed literal name through the detector's tagger factory and reports the
// name model as failed when no name comes back. Before iOS 27 the kickoff
// reads the load-time diagnostics unchanged.

@Suite("Scan kickoff: the name canary")
struct ScanKickoffNameCanaryTests {

    static var onIOS27: Bool {
        if #available(iOS 27, *) { return true }
        return false
    }

    static let ner = GazetteerLoadDiagnostics.Gazetteer.nerNameModel.rawValue

    @Test("A silent name tagger at kickoff reports the name model on iOS 27; before iOS 27 the load diagnostics are unchanged")
    func silentTaggerReportsNameModel() async {
        let shared = DocumentSearcher.sharedLoadDiagnostics
        let diagnostics = await PIIDetector.$_nameCanaryOverride.withValue(false) {
            await DocumentSearcher.scanKickoffDiagnostics()
        }
        guard Self.onIOS27 else {
            #expect(diagnostics == shared, "before iOS 27 the kickoff must read the load diagnostics unchanged")
            return
        }
        #expect(diagnostics.failedGazetteers.contains(Self.ner),
                "a silent tagger must report \(Self.ner): \(diagnostics.failedGazetteers)")
        // The load-time failures stay, in order; the name model joins them once.
        let expected = shared.failedGazetteers.contains(Self.ner)
            ? shared.failedGazetteers : shared.failedGazetteers + [Self.ner]
        #expect(diagnostics.failedGazetteers == expected)
        for name in shared.failedGazetteers {
            #expect(diagnostics.failureReasons[name] == shared.failureReasons[name])
        }
        // Mechanism-only reason: never the canary text or document content.
        let reason = diagnostics.failureReasons[Self.ner] ?? ""
        #expect(!reason.isEmpty)
        #expect(!reason.contains("Michael"), "the reason must not carry the canary text: \(reason)")
    }

    @Test("A tagging canary at kickoff changes nothing, on every OS")
    func taggingCanaryChangesNothing() async {
        let diagnostics = await PIIDetector.$_nameCanaryOverride.withValue(true) {
            await DocumentSearcher.scanKickoffDiagnostics()
        }
        #expect(diagnostics == DocumentSearcher.sharedLoadDiagnostics)
    }

    // Run on its own for a meaningful count: another suite's name tag pass in
    // the same process asks first through the same factory.
    @Test("The live canary asks through the tagger factory, once per process, and names still tag after it")
    func liveCanaryGoesThroughFactory() async {
        let shared = DocumentSearcher.sharedLoadDiagnostics
        var kickoffs: [GazetteerLoadDiagnostics] = []
        for _ in 0..<3 { kickoffs.append(await DocumentSearcher.scanKickoffDiagnostics()) }
        // Before any detection: the kickoff itself made the process ask (iOS 27).
        #expect(NameDetector._nameModelQueryCount.value == (Self.onIOS27 ? 1 : 0),
                "the kickoff's canary must ask through makeNameTagger(for:)")
        #expect(NameDetector.nameModelQueried == Self.onIOS27)

        let text = "The account holder Michael Johnson paid Delia Hartwell on Monday, and the bank sent the statement to both of them by mail."
        let tagger = NameDetector.makeNameTagger(for: text)
        var names: [String] = []
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType) { tag, range in
            if tag == .personalName { names.append(String(text[range])) }
            return true
        }
        #expect(NameDetector._nameModelQueryCount.value == (Self.onIOS27 ? 1 : 0))
        print("ScanKickoffNameCanary: names after the canary \(names); load reports the name model: \(shared.failedGazetteers.contains(Self.ner))")
        guard !names.isEmpty else {
            // A load that found the model must still tag after the canary.
            #expect(shared.failedGazetteers.contains(Self.ner),
                    "a name tag pass after the kickoff canary found no names")
            TestGate.skip("[NER asset] the name model tags nothing in this process; the agreement check needs it.")
            return
        }
        // The model tags: every kickoff reads as the load did (no banner on a healthy tagger).
        for kickoff in kickoffs { #expect(kickoff == shared) }
    }

    @Test("Where a sentence tags names through the factory, the canary tags too")
    func canaryAgreesWithATagPass() {
        let text = "The account holder Michael Johnson paid Delia Hartwell on Monday, and the bank sent the statement to both of them by mail."
        func names(_ s: String, english: Bool) -> [String] {
            let tagger = NameDetector.makeNameTagger(for: s)
            if english { tagger.setLanguage(.english, range: s.startIndex..<s.endIndex) }
            var out: [String] = []
            tagger.enumerateTags(in: s.startIndex..<s.endIndex, unit: .word, scheme: .nameType) { tag, range in
                if tag == .personalName { out.append(String(s[range])) }
                return true
            }
            return out
        }
        let canary = (0..<3).map { _ in PIIDetector.nameCanaryTags() }
        let listed = NLTagger.availableTagSchemes(for: .word, language: .english).contains(.nameType)
        let sentence = names(text, english: false)
        print("ScanKickoffNameCanary: listed(en)=\(listed) canary=\(canary) canaryNoLanguage=\(names("Michael Johnson", english: false)) sentence=\(sentence) sentenceEnglish=\(names(text, english: true)) loadNERAvailable=\(PIIDetector.isNameNERAvailable())")
        guard !sentence.isEmpty else {
            TestGate.skip("[NER asset] the name model tags nothing in this process; the agreement check needs it.")
            return
        }
        #expect(canary.allSatisfy { $0 }, "the name model tags \(sentence) but the canary reads it as silent")
    }
}
