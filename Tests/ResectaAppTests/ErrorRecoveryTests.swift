import Testing
import Foundation
@testable import ResectaApp
@testable import RedactionEngine

// Pipeline error recovery and .failed state transition tests.

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
            PipelineError.redactionError(.unsupportedPageGeometry(pageIndex: 0)),
          ])
    func redactionErrorDescriptions(error: PipelineError) {
        #expect(!error.localizedDescription.isEmpty)
    }

    // MARK: - Geometry vs. memory copy

    // The rasterizer's pre-flight has two halves with their own cases; the
    // copy on each must describe only its own mechanism. The memory copy
    // used to carry the page-size clause because both refusals shared it.

    @Test("Unsupported page geometry: title and message name the page range and scale, not memory")
    func unsupportedPageGeometryCopy() {
        let error = PipelineError.redactionError(.unsupportedPageGeometry(pageIndex: 2))
        #expect(error.localizedTitle == "Unsupported Page Geometry")
        #expect(error.localizedRecovery.hasPrefix("Page 3 uses a page size or scale factor that is not processed."))
        #expect(error.localizedRecovery.contains("between 10 and 5,000 points per side at the standard scale"))
        #expect(error.localizedDescription.contains("Page 3 uses a page size or scale factor"))
        for text in [error.localizedTitle, error.localizedRecovery, error.localizedDescription] {
            #expect(!text.lowercased().contains("memory"),
                    "geometry copy must not mention memory: \(text)")
        }
    }

    @Test("Insufficient memory: title and message describe memory only, with no page-size clause")
    func insufficientMemoryCopy() {
        let error = PipelineError.redactionError(.insufficientMemory(pageIndex: 0))
        #expect(error.localizedTitle == "Not Enough Memory")
        #expect(error.localizedRecovery.contains("memory"))
        #expect(error.localizedDescription.contains("memory available"))
        for text in [error.localizedRecovery, error.localizedDescription] {
            let lower = text.lowercased()
            #expect(!lower.contains("5,000") && !lower.contains("points") && !lower.contains("scale"),
                    "memory copy must not carry the geometry clause: \(text)")
        }
    }

    @Test("The split copy carries no banned or forbidden vocabulary")
    func splitCopyVocabularyFence() {
        let errors: [PipelineError] = [
            .redactionError(.unsupportedPageGeometry(pageIndex: 0)),
            .redactionError(.insufficientMemory(pageIndex: 0)),
        ]
        // Forbidden absolutes assembled from halves so this source does not
        // itself trip the M-1 sweep (mirrors HonestySurfacesTests).
        let halves: [(String, String)] = [
            ("guaran", "tee"), ("ens", "ure"), ("imposs", "ible"),
            ("perfect", "ly"), ("flaw", "lessly"), ("10", "0%"),
        ]
        for error in errors {
            for text in [error.localizedTitle, error.localizedRecovery, error.localizedDescription] {
                let lower = text.lowercased()
                for banned in LegalPhrases.bannedTerms {
                    #expect(!lower.contains(banned.lowercased()),
                            "banned term '\(banned)' in: \(text)")
                }
                for (a, b) in halves {
                    #expect(!lower.contains(a + b), "forbidden phrase '\(a + b)' in: \(text)")
                }
            }
        }
    }

    @Test("All PipelineError verification cases have non-empty localizedDescription",
          arguments: [
            PipelineError.verificationError(.engineCrash(layerIndex: 0)),
          ])
    func verificationErrorDescriptions(error: PipelineError) {
        #expect(!error.localizedDescription.isEmpty)
    }
}
