import Testing
import Vision
@testable import RedactionEngine

// S8 OCR Quality Program — configuration pins (design 04 Tier-5 test plan).
// Each program step updates the DETECTION-preset assertions here in the
// same commit that changes the preset; the Layer-2 pin has changed once
// (approved revision-pin exception, 2026-06-28) and is otherwise frozen.

@Suite("OCR configuration program pins")
struct OCRQualityProgramTests {

    // MARK: - Layer-2 byte-identical pin (S8 exit criterion 3)

    /// The verifier's request must match the historical inline
    /// construction (.fast + usesLanguageCorrection=false) plus the pinned
    /// Vision revision (charter exception, 2026-06-28); every other
    /// knob stays at its Vision default. Compared field-by-field against a
    /// virgin request so a future preset edit (minimumTextHeight,
    /// customWords, languages) trips this pin loudly.
    @Test("Layer-2 verification request is byte-identical to historical params")
    func layer2RequestByteIdentical() {
        let request = OCRConfiguration.verificationLayer2.makeRequest()
        let virgin = VNRecognizeTextRequest()

        // The two parameters Layer 2 has always set:
        #expect(request.recognitionLevel == .fast)
        #expect(request.usesLanguageCorrection == false)

        // Charter exception (2026-06-28): revision pinned so Layer 2
        // stays deterministic across OS updates — the Part A
        // fill-hallucination class is Vision-revision-sensitive. Asserted
        // on the preset, not the virgin default, so a silent unpin (nil)
        // or bump fails here even on an OS whose default is still 3.
        #expect(OCRConfiguration.verificationLayer2.revision == VNRecognizeTextRequestRevision3,
                "Layer-2 revision pin removed or changed (charter exception 2026-06-28)")
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

    // MARK: - Detection preset (program-step state)

    /// Step state: steps 1–3 applied (design 04 §§5.4, 5.3, 5.2), each
    /// with its measurement row in the S8 evidence.
    @Test("Detection request: revision pin + customWords + minimumTextHeight")
    func detectionRequestCurrentState() {
        let fast = OCRConfiguration.detection(recognitionLevel: .fast).makeRequest()
        let accurate = OCRConfiguration.detection(recognitionLevel: .accurate).makeRequest()

        #expect(fast.recognitionLevel == .fast)
        #expect(accurate.recognitionLevel == .accurate)
        #expect(fast.usesLanguageCorrection == true)

        // Step 1 (§5.4):
        #expect(fast.revision == VNRecognizeTextRequestRevision3)
        #expect(accurate.revision == VNRecognizeTextRequestRevision3)

        // Step 2 (§5.3):
        #expect(fast.customWords == OCRCustomWordsBuilder.financialCustomWords)

        // Step 3 (§5.2):
        #expect(fast.minimumTextHeight == 0.007)
        #expect(accurate.minimumTextHeight == 0.007)
    }

    // MARK: - Step 2: customWords vocabulary (design §5.3 test plan)

    @Test("customWords list is loader-derived, in budget, and anchored")
    func customWordsListBuilt() throws {
        let words = OCRCustomWordsBuilder.financialCustomWords

        // Design test plan: between 50 and 200; design body: ≤ 150.
        #expect(words.count >= 50, "vocabulary too small — loaders missing?")
        #expect(words.count <= OCRCustomWordsBuilder.wordBudget)

        // Anchors present (case-preserved), no case-insensitive duplicates.
        for anchor in OCRCustomWordsBuilder.labelAnchors {
            #expect(words.contains(anchor), "missing anchor \(anchor)")
        }
        let lowered = words.map { $0.lowercased() }
        #expect(Set(lowered).count == lowered.count, "case-insensitive dup")

        // Derivation reads the loaders: institution tokens appear.
        let injected = OCRCustomWordsBuilder.build(
            contextKeywords: try ContextKeywordsLoader(),
            institutions: try InstitutionGazetteer()
        )
        #expect(injected == words,
                "cached list must equal a fresh loader-derived build")
    }

    // MARK: - Step 4: detection DPI policy (design §5.1 test plan)

    /// Exhaustive over DoctypeClass + nil: financial renders at 200,
    /// everything else (and unseeded pages) keeps the shipped 150 —
    /// the measured step-4 shape (200-global tripped the doctype-gate /
    /// face-detection interaction; see the S8 measurement evidence).
    @Test("detectionDPI: financial 200, all other doctypes and nil 150")
    func detectionDPI200ForFinancial() {
        #expect(DetectionRenderPolicy.detectionDPI(for: .financial) == 200)
        #expect(DetectionRenderPolicy.detectionDPI(for: nil) == 150)
        for doctype in [DoctypeClass.court, .medical, .foia, .generic] {
            #expect(DetectionRenderPolicy.detectionDPI(for: doctype) == 150,
                    "\(doctype) must keep the shipped 150 DPI")
        }
    }

    /// Large-format page (24×36 in = 1728×2592 pt) at the financial
    /// target: the cap holds the largest rendered dimension at 4096 px.
    /// Letter stays uncapped (2200 px < 4096).
    @Test("detection DPI cap: largest dimension never exceeds 4096 px")
    func detectionDPICapNotExceeded() {
        let letter = CGSize(width: 612, height: 792)
        #expect(DetectionRenderPolicy.cappedDetectionDPI(
            for: .financial, effectiveSize: letter) == 200)

        let blueprint = CGSize(width: 1728, height: 2592)
        let capped = DetectionRenderPolicy.cappedDetectionDPI(
            for: .financial, effectiveSize: blueprint)
        #expect(capped < 200)
        let largestPx = 2592 * capped / 72.0
        #expect(abs(largestPx - DetectionRenderPolicy.maxDetectionPixels) < 1,
                "capped render must land on the 4096-px ceiling")
    }

    // MARK: - Search preset (charter: DPI/accuracy untouched)

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
