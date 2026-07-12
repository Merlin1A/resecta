import Testing
@testable import ResectaApp
import RedactionEngine

// Phase 2 redesign — pin the broadened `didAutoExpand` gate so the
// recompose's "PASS + uniform modes ships collapsed; WARN/FAIL or
// mixed modes auto-expands" contract can't silently regress. Mirrors
// the static-helper pattern from Session 1's
// `DocumentEditorAutoReturnHomeTests`. See the Phase 2 redesign
// "details section" and "augmentation changelog → Phase 2".

@Suite("Verification results auto-expand gate (Phase 2)")
@MainActor
struct VerificationResultsAutoExpandTests {

    @Test("PASS + uniform modes → collapsed")
    func passUniformStaysCollapsed() {
        #expect(
            VerificationResultsView.shouldAutoExpand(
                status: .pass,
                hasMixedModes: false
            ) == false
        )
    }

    @Test("PASS + mixed modes → auto-expand")
    func passMixedExpands() {
        #expect(
            VerificationResultsView.shouldAutoExpand(
                status: .pass,
                hasMixedModes: true
            ) == true
        )
    }

    @Test("WARN → auto-expand regardless of mode mix")
    func warnExpands() {
        #expect(
            VerificationResultsView.shouldAutoExpand(
                status: .warn("noted"),
                hasMixedModes: false
            ) == true
        )
        #expect(
            VerificationResultsView.shouldAutoExpand(
                status: .warn("noted"),
                hasMixedModes: true
            ) == true
        )
    }

    @Test("FAIL → auto-expand regardless of mode mix")
    func failExpands() {
        #expect(
            VerificationResultsView.shouldAutoExpand(
                status: .fail("issue"),
                hasMixedModes: false
            ) == true
        )
        #expect(
            VerificationResultsView.shouldAutoExpand(
                status: .fail("issue"),
                hasMixedModes: true
            ) == true
        )
    }

    @Test("INFO + uniform modes → collapsed (metadata-only doc)")
    func infoStaysCollapsed() {
        // A metadata-only doc (e.g. only Apple auto-injected /Producer)
        // ships collapsed — nothing to action, the masthead leads.
        #expect(
            VerificationResultsView.shouldAutoExpand(
                status: .info("auto-injected /Producer"),
                hasMixedModes: false
            ) == false
        )
    }

    @Test("INFO + mixed modes → auto-expand")
    func infoMixedExpands() {
        #expect(
            VerificationResultsView.shouldAutoExpand(
                status: .info("auto-injected /Producer"),
                hasMixedModes: true
            ) == true
        )
    }

    @Test("SKIPPED + uniform modes → collapsed")
    func skippedUniformStaysCollapsed() {
        #expect(
            VerificationResultsView.shouldAutoExpand(
                status: .skipped,
                hasMixedModes: false
            ) == false
        )
    }

    @Test("SKIPPED + mixed modes → auto-expand")
    func skippedMixedExpands() {
        #expect(
            VerificationResultsView.shouldAutoExpand(
                status: .skipped,
                hasMixedModes: true
            ) == true
        )
    }
}
