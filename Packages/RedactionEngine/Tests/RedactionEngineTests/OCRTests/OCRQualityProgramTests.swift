import Testing
import Vision
@testable import RedactionEngine

// OCR configuration pins. The Layer-2 pin has changed once (a revision-pin
// exception) and is otherwise frozen.

@Suite("OCR configuration program pins")
struct OCRQualityProgramTests {

    // MARK: - Layer-2 byte-identical pin

    /// The verifier's request must match the historical inline
    /// construction (.fast + usesLanguageCorrection=false) plus the pinned
    /// Vision revision; every other knob stays at its Vision default.
    /// Compared field-by-field against a virgin request so a future
    /// preset edit (minimumTextHeight, customWords, languages) trips
    /// this pin loudly.
    @Test("Layer-2 verification request is byte-identical to historical params")
    func layer2RequestByteIdentical() {
        let request = OCRConfiguration.verificationLayer2.makeRequest()
        let virgin = VNRecognizeTextRequest()

        // The two parameters Layer 2 has always set:
        #expect(request.recognitionLevel == .fast)
        #expect(request.usesLanguageCorrection == false)

        // Revision pinned so Layer 2 stays deterministic across OS
        // updates — the Part A fill-hallucination class is
        // Vision-revision-sensitive. Asserted on the preset, not the
        // virgin default, so a silent unpin (nil) or bump fails here
        // even on an OS whose default is still 3.
        #expect(OCRConfiguration.verificationLayer2.revision == VNRecognizeTextRequestRevision3,
                "Layer-2 revision pin removed or changed")
        #expect(request.revision == VNRecognizeTextRequestRevision3,
                "Layer-2 request must carry the pinned revision")

        // Everything else must remain at Vision defaults:
        #expect(request.minimumTextHeight == virgin.minimumTextHeight,
                "Layer-2 must not set minimumTextHeight")
        #expect(request.customWords == virgin.customWords,
                "Layer-2 must not receive customWords")
        #expect(request.recognitionLanguages == virgin.recognitionLanguages)
        #expect(request.automaticallyDetectsLanguage == virgin.automaticallyDetectsLanguage)
    }

    // MARK: - Search preset (DPI/accuracy untouched)

    @Test("Search request: revision pinned; other knobs at production state")
    func searchRequestCurrentState() {
        let request = OCRConfiguration.search(recognitionLevel: .accurate).makeRequest()
        let virgin = VNRecognizeTextRequest()

        #expect(request.recognitionLevel == .accurate)
        #expect(request.usesLanguageCorrection == true)
        #expect(request.revision == VNRecognizeTextRequestRevision3)
        #expect(request.minimumTextHeight == virgin.minimumTextHeight)
        #expect(request.customWords == virgin.customWords)
    }
}
