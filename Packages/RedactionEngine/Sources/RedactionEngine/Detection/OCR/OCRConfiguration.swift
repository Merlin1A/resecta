import Vision

// OCR quality program — shared Vision OCR request configuration.
//
// One type now owns every VNRecognizeTextRequest the engine builds, so the
// three OCR call sites (OCREngine.recognizeText — search;
// DetectionOrchestrator.runOCR — detection; VerificationEngine Layer 2 —
// output verification) configure Vision through a single, testable surface.
// The Tier-5 quality program tunes the DETECTION preset step by step, each
// step measured against the RealDocOCRQualityTests harness before it
// ships; the VERIFICATION preset is frozen by design.

public struct OCRConfiguration: Sendable {

    /// Vision recognition level (.fast for detection/verification,
    /// .accurate for search — search DPI/accuracy are out of the program's
    /// scope).
    public var recognitionLevel: VNRequestTextRecognitionLevel

    /// Vision's language-model correction. Detection and search keep the
    /// historical `true`; Layer 2 keeps `false` (prevents hallucinated
    /// corrections re-introducing "text" on redacted rasters).
    public var usesLanguageCorrection: Bool

    /// Pinned Vision revision. `nil` = Vision's "latest installed"
    /// default — which can silently change OCR output across OS updates.
    public var revision: Int?

    /// Minimum text height as a fraction of image height.
    /// `nil` = Vision default.
    public var minimumTextHeight: Float?

    /// Domain vocabulary passed to Vision. Empty = not set.
    public var customWords: [String]

    public init(
        recognitionLevel: VNRequestTextRecognitionLevel,
        usesLanguageCorrection: Bool,
        revision: Int? = nil,
        minimumTextHeight: Float? = nil,
        customWords: [String] = []
    ) {
        self.recognitionLevel = recognitionLevel
        self.usesLanguageCorrection = usesLanguageCorrection
        self.revision = revision
        self.minimumTextHeight = minimumTextHeight
        self.customWords = customWords
    }

    /// Build a Vision request carrying exactly this configuration.
    /// Optional knobs are applied only when set, so a preset that leaves
    /// a knob `nil` keeps the request's Vision default for it (load-bearing
    /// for the Layer-2 pin's unset knobs).
    public func makeRequest() -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = recognitionLevel
        request.usesLanguageCorrection = usesLanguageCorrection
        if let revision {
            request.revision = revision
        }
        if let minimumTextHeight {
            request.minimumTextHeight = minimumTextHeight
        }
        if !customWords.isEmpty {
            request.customWords = customWords
        }
        return request
    }

    // MARK: - Presets (one per call site)

    /// Pinned Vision text-recognition revision.
    /// Without a pin, Vision uses "latest installed", so an OS update can
    /// silently change OCR output for the same document. iOS 26 SDK ships
    /// revisions 1–3 with 1 and 2 deprecated; 3 is the current latest, so
    /// this pin is measurement-neutral today (step-1 run: counts identical
    /// to baseline) and exists to freeze behavior across future OS updates.
    ///
    /// UPGRADE POLICY: when a new Vision revision ships,
    /// (1) run G6SyntheticRecallTests on the new revision, (2) run the
    /// RealDocOCRQualityTests fixture probes on it, (3) bump only if recall
    /// improves ≥ 2 pp on a category AND precision does not decrease,
    /// (4) log the bump in resecta-datapipeline/SOURCES.md with iOS version, date, test delta.
    public static let pinnedTextRecognitionRevision = VNRecognizeTextRequestRevision3

    /// Detection-path minimum text height, as a
    /// fraction of image height. Targets 7–9 pt tax-form box labels:
    /// at 200 DPI (2200 px letter) the floor is 15.4 px vs 19.4 px for
    /// 7 pt text; at 150 DPI (1650 px) it is 11.6 px vs 14.6 px — the
    /// value holds at BOTH detection DPIs, so a later DPI revert does not
    /// require recomputing it. Vision's documented
    /// default is 1/32 ≈ 0.03125 (≈ 24.8 pt at letter size).
    public static let detectionMinimumTextHeight: Float = 0.007

    /// Detection-pipeline OCR (DetectionOrchestrator.runOCR). The Tier-5
    /// program's knobs land here, one measured step at a time.
    /// Program state: steps 1 (revision pin), 2 (customWords), and
    /// 3 (minimumTextHeight) applied.
    public static func detection(
        recognitionLevel: VNRequestTextRecognitionLevel
    ) -> OCRConfiguration {
        OCRConfiguration(
            recognitionLevel: recognitionLevel,
            usesLanguageCorrection: true,
            revision: pinnedTextRecognitionRevision,
            // Small-text floor; detection only. This also names
            // OCREngine (search) as an insertion point, but the
            // instruments measure the detection path only, so the search
            // preset keeps Vision's default until a search-side probe
            // exists (measure-then-ship; recorded as a deviation).
            minimumTextHeight: detectionMinimumTextHeight,
            // Loader-derived financial vocabulary (≤150 words,
            // process-lifetime cache; consumed by Vision only when
            // usesLanguageCorrection is true, which detection sets).
            customWords: OCRCustomWordsBuilder.financialCustomWords
        )
    }

    /// Search-path OCR (OCREngine.recognizeText, used by DocumentSearcher
    /// at .accurate / 300 DPI). DPI and accuracy are charter-protected;
    /// the insertion points named for OCREngine apply here when
    /// their steps land. The revision pin applies (determinism is
    /// wanted on every non-verifier OCR path; same upgrade policy).
    public static func search(
        recognitionLevel: VNRequestTextRecognitionLevel
    ) -> OCRConfiguration {
        OCRConfiguration(
            recognitionLevel: recognitionLevel,
            usesLanguageCorrection: true,
            revision: pinnedTextRecognitionRevision
        )
    }

    /// Layer-2 output verification (VerificationEngine.runLayer2OCR).
    /// FROZEN: .fast + usesLanguageCorrection=false + the revision
    /// pin, nothing else — the verifier's behavior must stay byte-identical
    /// through the OCR program (OCRQualityProgramTests pins
    /// this against a virgin request). Revision pinned so Layer 2 stays
    /// deterministic across OS updates — the Part A fill-hallucination class is
    /// Vision-revision-sensitive. Behavior-neutral on the 26.4 baseline
    /// (revision 3 == current latest there); upgrades follow the
    /// policy on `pinnedTextRecognitionRevision`. Region-scoping and any
    /// retune are a backlog item.
    public static let verificationLayer2 = OCRConfiguration(
        recognitionLevel: .fast,
        usesLanguageCorrection: false,
        revision: pinnedTextRecognitionRevision
    )
}
