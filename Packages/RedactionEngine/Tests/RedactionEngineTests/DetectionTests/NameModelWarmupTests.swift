import Testing
import Foundation
import NaturalLanguage
@testable import RedactionEngine

// On iOS 27 the name model tags in a process only when the process has asked
// which tag schemes are available before its first name tag pass; a tag pass
// first leaves the model silent for the rest of the process. The detector's
// tagger factory asks once per process before the first tagger. Before iOS 27
// nothing is asked.

@Suite("Name model: asked for before the first name tag pass (iOS 27)")
struct NameModelWarmupTests {

    static var onIOS27: Bool {
        if #available(iOS 27, *) { return true }
        return false
    }

    @Test("The tagger factory asks once per process on iOS 27, however many taggers at once; never before iOS 27")
    func asksOncePerProcess() async {
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<32 { group.addTask { _ = NameDetector.makeNameTagger(for: "Line \(i) for Delia Hartwell.") } }
        }
        #expect(NameDetector.nameModelQueried == Self.onIOS27)
        #expect(NameDetector._nameModelQueryCount.value == (Self.onIOS27 ? 1 : 0))
    }

    @Test("iOS 27: names are found when the detector's tag pass is the first NL use of the process")
    func detectorFirstFindsNames() {
        guard Self.onIOS27 else {
            TestGate.skip("[iOS 27 gate] the name model needs no warm-up before iOS 27; skipping.")
            return
        }
        // No availability probe, no PIIDetector load: the name detector alone, as the process's first name tag pass
        // when this test runs on its own.
        let text = "The account holder Michael Johnson paid Delia Hartwell on Monday, and the bank sent the statement to both of them by mail."
        let names = NameDetector(nameGazetteer: nil, contextLoader: nil).detect(in: text).filter { $0.kind == .name }.map(\.text)
        print("NameModelWarmup: detector-first names \(names)")
        #expect(!names.isEmpty, "the first name tag pass of the process found no names: \(names)")
    }
}
