import Foundation
import Testing
import RedactionCore

/// The core target builds and tests with Foundation alone. These three
/// tests exist to prove the target, its test target and package-level
/// access work off Apple platforms; they pin nothing new about behaviour.
@Suite struct CoreSkeletonTests {
    @Test func pipelineModeHasItsTwoCases() {
        #expect(PipelineMode.allCases == [.secureRasterization, .searchableRedaction])
    }

    @Test func sensitiveTermDefaultsToSubstringMatching() {
        let term = SensitiveTerm(text: "sample")
        #expect(term.requiresTokenBoundary == false)
        #expect(term == SensitiveTerm(text: "sample", requiresTokenBoundary: false))
    }

    @Test func sigmoidInvertsLogitInsideTheClamp() {
        for p in [0.01, 0.25, 0.5, 0.75, 0.99] {
            #expect(abs(Logit.sigmoid(Logit.logit(p)) - p) < 1e-12)
        }
        #expect(Logit.clamp(0) == Logit.epsilon)
        #expect(Logit.clamp(1) == 1 - Logit.epsilon)
    }
}
