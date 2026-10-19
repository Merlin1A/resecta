import Testing
import CoreGraphics
import Foundation
@testable import RedactionEngine

// OCRTextNormalizer turns confusable OCR digits into the form the PII
// detectors match ("l23-4S-6789" → "123-45-6789"); the search path's OCR
// leg applies it per line.
//
// Privacy rule: test names use locate/match/resolve vocabulary (audit-lint M-1).
// No outcome-promise language.

@Suite("DetectionOrchestrator OCR normalizer (Gap B)", .serialized)
struct DetectionOrchestratorOCRNormalizerTests {

    // MARK: - Unit seam

    @Test("OCRTextNormalizer transforms confusable digits before PII detection")
    func ssnDetectedAfterNormalization() async {
        // Verify that the normalizer the Gap B code uses actually corrects
        // the confusable OCR output that would otherwise defeat the SSN regex.
        let normalizer = OCRTextNormalizer()

        // "l23-4S-6789": 'l'→'1' (digit context: clear digit '2','3' dominate),
        // '4' and '6','7','8','9' are unambiguous digits → digit context,
        // 'S'→'5'. Result: "123-45-6789".
        let raw = "l23-4S-6789"
        let normalized = normalizer.normalize(raw)
        #expect(normalized == "123-45-6789")

        // Now verify the SSN detector fires on the normalized text.
        let detector = PIIDetector()
        let matches = await detector.detect(in: normalized, categories: [.ssn])
        let ssnMatches = matches.filter { $0.category == .ssn }
        #expect(!ssnMatches.isEmpty,
                "SSN detector should produce a hit on normalized text '\(normalized)'")
    }
}
