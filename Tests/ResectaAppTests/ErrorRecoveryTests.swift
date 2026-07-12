import Testing
import Foundation
@testable import ResectaApp
@testable import RedactionEngine

// UI_UX §3.3: Pipeline error recovery and .failed state transition tests.

@Suite("Pipeline Error Recovery")
@MainActor
struct ErrorRecoveryTests {

    // MARK: - Failed State Transitions

    @Test("Failed from redaction recoverable to editing")
    func failedFromRedactionRecoverableToEditing() {
        let doc = DocumentState()
        doc.phase = .failed(
            error: .redactionError(.reconstructionFailed),
            returnPhase: .editing)

        let success = doc.transition(to: .editing)
        #expect(success)
        #expect(doc.phaseKind == .editing)
    }

    @Test("Failed from import recoverable to empty")
    func failedFromImportRecoverableToEmpty() {
        let doc = DocumentState()
        doc.phase = .failed(
            error: .importError(.corrupt),
            returnPhase: .empty)

        let success = doc.transition(to: .empty)
        #expect(success)
        #expect(doc.phaseKind == .empty)
    }

    @Test("Failed from verification recoverable to verified")
    func failedFromVerificationRecoverableToVerified() {
        let doc = DocumentState()
        doc.phase = .failed(
            error: .verificationError(.engineCrash(layerIndex: 2)),
            returnPhase: .verified(report: .skipped))

        let success = doc.transition(to: .verified(report: .skipped))
        #expect(success)
        #expect(doc.phaseKind == .verified)
    }

    // MARK: - Error Context Preservation

    @Test("Redaction error clears output URL (no partial output)")
    func redactionErrorClearsOutput() {
        let doc = DocumentState()
        let redaction = RedactionState()
        redaction.outputURL = URL(fileURLWithPath: "/tmp/partial.pdf")

        // Simulate what PipelineCoordinator does on redaction error (lines 100-106)
        redaction.clearOutput()
        doc.phase = .failed(
            error: .redactionError(.reconstructionFailed),
            returnPhase: .editing)

        #expect(redaction.outputURL == nil)
        #expect(doc.phaseKind == .failed)
    }

    @Test("Verification error preserves output URL (CS-4-1)")
    func verificationErrorPreservesOutput() {
        let doc = DocumentState()
        let redaction = RedactionState()
        let outputURL = URL(fileURLWithPath: "/tmp/valid_output.pdf")
        redaction.outputURL = outputURL

        // Simulate what PipelineCoordinator does on verification error (lines 93-98)
        // Output URL is NOT cleared — redacted document is valid
        doc.phase = .failed(
            error: .verificationError(.engineCrash(layerIndex: 0)),
            returnPhase: .verified(report: .skipped))

        #expect(redaction.outputURL == outputURL,
                "Verification error must preserve output URL (CS-4-1)")
    }

    // MARK: - PipelineError LocalizedDescription

    @Test("All PipelineError import cases have non-empty localizedDescription",
          arguments: [
            PipelineError.importError(.corrupt),
            PipelineError.importError(.passwordProtected),
            PipelineError.importError(.tooLarge(bytesRead: 100_000_000)),
            PipelineError.importError(.unsupportedFormat),
            PipelineError.importError(.invalidPageDimensions(pageIndex: 0)),
          ])
    func importErrorDescriptions(error: PipelineError) {
        #expect(!error.localizedDescription.isEmpty)
    }

    @Test("All PipelineError redaction cases have non-empty localizedDescription",
          arguments: [
            PipelineError.redactionError(.bitmapCreationFailed(pageIndex: 0)),
            PipelineError.redactionError(.reconstructionFailed),
            PipelineError.redactionError(.renderTimeout(pageIndex: 0)),
            PipelineError.redactionError(.insufficientMemory(pageIndex: 0)),
          ])
    func redactionErrorDescriptions(error: PipelineError) {
        #expect(!error.localizedDescription.isEmpty)
    }

    @Test("All PipelineError verification cases have non-empty localizedDescription",
          arguments: [
            PipelineError.verificationError(.engineCrash(layerIndex: 0)),
          ])
    func verificationErrorDescriptions(error: PipelineError) {
        #expect(!error.localizedDescription.isEmpty)
    }
}
