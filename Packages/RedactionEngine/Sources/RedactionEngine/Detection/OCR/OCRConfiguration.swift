import Vision

// Shared Vision OCR request configuration.
//
// One type owns every VNRecognizeTextRequest the engine builds, so the two
// OCR call sites (OCREngine.recognizeText — search; VerificationEngine
// Layer 2 — output verification) configure Vision through a single,
// testable surface. The VERIFICATION preset is frozen by design.

struct OCRConfiguration: Sendable {

    /// Vision recognition level (.fast for verification, .accurate for
    /// search).
    public var recognitionLevel: VNRequestTextRecognitionLevel

    /// Vision's language-model correction. Search keeps the
    /// historical `true`; Layer 2 keeps `false` (prevents hallucinated
    /// corrections re-introducing "text" on redacted rasters).
    var usesLanguageCorrection: Bool

    /// Pinned Vision revision. `nil` = Vision's "latest installed"
    /// default — which can silently change OCR output across OS updates.
    var revision: Int?

    /// Minimum text height as a fraction of image height.
    /// `nil` = Vision default.
    var minimumTextHeight: Float?

    /// Domain vocabulary passed to Vision. Empty = not set.
    var customWords: [String]

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
    func makeRequest() -> VNRecognizeTextRequest {
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
    static let pinnedTextRecognitionRevision = VNRecognizeTextRequestRevision3

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

    /// The ink fit's token read (`DocumentSearcher.inkTokens`): one .accurate
    /// pass over a page whose text layer is hidden over its image, read for
    /// where each word's ink lies, so no language-model correction (a
    /// corrected token would not align with the layer's text). The revision
    /// pin applies.
    static let inkFitTokens = OCRConfiguration(
        recognitionLevel: .accurate,
        usesLanguageCorrection: false,
        revision: pinnedTextRecognitionRevision
    )

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
    static let verificationLayer2 = OCRConfiguration(
        recognitionLevel: .fast,
        usesLanguageCorrection: false,
        revision: pinnedTextRecognitionRevision
    )
}
