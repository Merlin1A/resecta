import Testing
import Foundation
@testable import RedactionEngine

// TEST §4.7 — Overall status derivation tests.
// Validates that aggregateStatus correctly prioritizes FAIL > WARN > PASS.

@Suite("Verification Status Derivation")
struct StatusDerivationTests {

    @Test("Any FAIL → overall FAIL")
    func failDominates() {
        let layers = [
            LayerResult.mock(status: .pass),
            LayerResult.mock(status: .fail("test")),
            LayerResult.mock(status: .warn("test")),
        ]
        let verifier = VerificationEngine()
        let overall = verifier.aggregateStatus(layers)
        #expect(overall == .fail(""))  // Case-identity comparison
    }

    @Test("No FAIL but any WARN → overall WARN")
    func warnWithoutFail() {
        let layers = [
            LayerResult.mock(status: .pass),
            LayerResult.mock(status: .warn("metadata")),
        ]
        let verifier = VerificationEngine()
        let overall = verifier.aggregateStatus(layers)
        #expect(overall == .warn(""))
    }

    @Test("All PASS → overall PASS")
    func allPass() {
        let layers = [
            LayerResult.mock(status: .pass),
            LayerResult.mock(status: .pass),
        ]
        let verifier = VerificationEngine()
        let overall = verifier.aggregateStatus(layers)
        #expect(overall == .pass)
    }

    @Test("Empty layers → vacuous PASS")
    func emptyLayers() {
        let verifier = VerificationEngine()
        let overall = verifier.aggregateStatus([])
        #expect(overall == .pass)
    }

    @Test("Multiple FAILs still produce single FAIL")
    func multipleFailsStillFail() {
        let layers = [
            LayerResult.mock(status: .fail("layer 1")),
            LayerResult.mock(status: .fail("layer 3")),
        ]
        let verifier = VerificationEngine()
        let overall = verifier.aggregateStatus(layers)
        #expect(overall == .fail(""))
    }

    @Test("VerificationStatus.Equatable compares case identity only")
    func equatableCaseIdentity() {
        #expect(VerificationStatus.fail("A") == VerificationStatus.fail("B"))
        #expect(VerificationStatus.warn("X") == VerificationStatus.warn("Y"))
        #expect(VerificationStatus.info("A") == VerificationStatus.info("B"))
        #expect(VerificationStatus.attention("A") == VerificationStatus.attention("B"))
        #expect(VerificationStatus.pass == VerificationStatus.pass)
        #expect(VerificationStatus.skipped == VerificationStatus.skipped)
        #expect(VerificationStatus.fail("A") != VerificationStatus.warn("A"))
        #expect(VerificationStatus.info("A") != VerificationStatus.warn("A"))
        #expect(VerificationStatus.info("A") != VerificationStatus.pass)
        #expect(VerificationStatus.attention("A") != VerificationStatus.fail("A"))
        #expect(VerificationStatus.attention("A") != VerificationStatus.warn("A"))
        #expect(VerificationStatus.attention("A") != VerificationStatus.pass)
        #expect(VerificationStatus.pass != VerificationStatus.fail(""))
        #expect(VerificationStatus.skipped != VerificationStatus.pass)
    }

    // Residual tier (attention): un-redacted occurrences of applied terms
    // OUTSIDE every region. Aggregation seat: below FAIL (an output defect
    // always wins the masthead), above WARN/INFO/PASS and the partial-skip
    // WARN (a residual is actionable, a note is not).

    @Test("ATTENTION outranks WARN, INFO, and PASS")
    func attentionOutranksWarn() {
        let layers = [
            LayerResult.mock(status: .pass),
            LayerResult.mock(status: .warn("note")),
            LayerResult.mock(status: .attention("residual")),
            LayerResult.mock(status: .info("meta")),
        ]
        let verifier = VerificationEngine()
        #expect(verifier.aggregateStatus(layers) == .attention(""))
    }

    @Test("FAIL outranks ATTENTION")
    func failOutranksAttention() {
        let layers = [
            LayerResult.mock(status: .attention("residual")),
            LayerResult.mock(status: .fail("output defect")),
        ]
        let verifier = VerificationEngine()
        #expect(verifier.aggregateStatus(layers).isFail)
    }

    @Test("ATTENTION outranks the partial-skip WARN")
    func attentionOutranksPartialSkip() {
        let layers = [
            LayerResult.mock(status: .attention("residual")),
            LayerResult.mock(status: .skipped),
            LayerResult.mock(status: .pass),
        ]
        let verifier = VerificationEngine()
        #expect(verifier.aggregateStatus(layers) == .attention(""))
    }

    @Test("ATTENTION aggregate carries the first attention layer's message")
    func attentionCarriesMessage() {
        let layers = [
            LayerResult.mock(status: .pass),
            LayerResult.mock(status: .attention("first residual")),
            LayerResult.mock(status: .attention("second residual")),
        ]
        let verifier = VerificationEngine()
        let overall = verifier.aggregateStatus(layers)
        if case .attention(let msg) = overall {
            #expect(msg == "first residual")
        } else {
            #expect(Bool(false), "expected attention aggregate; got \(overall)")
        }
    }

    @Test("INFO layers aggregate to PASS (overall status unaffected)")
    func infoLayersAggregateToPass() {
        let layers = [
            LayerResult.mock(status: .pass),
            LayerResult.mock(status: .info("auto-injected /Producer")),
        ]
        let verifier = VerificationEngine()
        #expect(verifier.aggregateStatus(layers) == .pass)
    }

    // CAT-372: a skipped check is not a silent pass. Some-but-not-all skipped
    // → WARN ("results may be incomplete"); all skipped → the .skipped sentinel.
    // Replaces the prior `skippedLayersIgnored` test, which asserted the old
    // dishonest behavior (skipped folded into PASS).

    @Test("Some but not all layers skipped → overall WARN")
    func partialSkipProducesWarn() {
        let layers = [
            LayerResult.mock(status: .pass),
            LayerResult.mock(status: .skipped),
            LayerResult.mock(status: .pass),
        ]
        let verifier = VerificationEngine()
        let overall = verifier.aggregateStatus(layers)
        #expect(overall.isWarn)
    }

    @Test("All layers skipped → overall SKIPPED")
    func allSkippedProducesSkipped() {
        let layers = [
            LayerResult.mock(status: .skipped),
            LayerResult.mock(status: .skipped),
        ]
        let verifier = VerificationEngine()
        let overall = verifier.aggregateStatus(layers)
        #expect(overall == .skipped)
    }

    @Test("FAIL outranks a skipped layer")
    func failOutranksSkip() {
        let layers = [
            LayerResult.mock(status: .skipped),
            LayerResult.mock(status: .fail("leak")),
            LayerResult.mock(status: .pass),
        ]
        let verifier = VerificationEngine()
        #expect(verifier.aggregateStatus(layers).isFail)
    }
}
