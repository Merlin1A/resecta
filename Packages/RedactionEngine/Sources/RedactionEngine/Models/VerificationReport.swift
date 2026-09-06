/// Complete verification report produced by the verification engine.
public struct VerificationReport: Sendable {
    /// Why verification did not run, when `overallStatus` is `.skipped`.
    /// Meaningful only on skipped reports; other reports carry the
    /// default `.autoVerifyOff` and never read it.
    public enum SkipReason: Sendable, Equatable {
        /// Automatic verification is off in Settings and the run did not verify.
        case autoVerifyOff
        /// The user stopped verification, or the app was backgrounded mid-verify.
        case cancelled
        /// Verification failed to complete (engine error or unloadable output).
        case error
    }

    public let layers: [LayerResult]
    public let overallStatus: VerificationStatus
    public let durationSeconds: Double
    /// Per-page pipeline modes used during redaction. Indexed by page number.
    /// Allows the verification results UI to show which pages used which mode.
    public let perPageModes: [PipelineMode]
    /// Sibling of `perPageModes` — why each page rasterized in a
    /// Searchable-mode run (pre-flight trigger or runtime fallback). Nil
    /// entries are pages that kept searchable mode; all-nil for
    /// secure-raster-mode runs (rasterized by choice) and for reports built
    /// without per-page rasterize artifacts (verify-only resume of an old
    /// session). Empty when per-page data is absent entirely.
    public let perPageFallbackReasons: [TextLayerDetector.FallbackReason?]
    public let skipReason: SkipReason

    /// Set to true when the user explicitly overrides a FAIL result
    /// and chooses "Export Anyway — I Accept the Risk."
    public var userOverrodeFailure: Bool = false

    /// Set to true when the user confirms sharing a skipped-verification
    /// output ("Share" on the one-time skipped-share confirm). Report-scoped
    /// like `userOverrodeFailure`: a new report starts false, so the confirm
    /// re-arms whenever verification produces a fresh report.
    public var userAcknowledgedSkippedShare: Bool = false

    public init(layers: [LayerResult], overallStatus: VerificationStatus,
                durationSeconds: Double, perPageModes: [PipelineMode] = [],
                perPageFallbackReasons: [TextLayerDetector.FallbackReason?] = [],
                userOverrodeFailure: Bool = false,
                userAcknowledgedSkippedShare: Bool = false,
                skipReason: SkipReason = .autoVerifyOff) {
        self.layers = layers
        self.overallStatus = overallStatus
        self.durationSeconds = durationSeconds
        self.perPageModes = perPageModes
        self.perPageFallbackReasons = perPageFallbackReasons
        self.userOverrodeFailure = userOverrodeFailure
        self.userAcknowledgedSkippedShare = userAcknowledgedSkippedShare
        self.skipReason = skipReason
    }

    /// Sentinel value for when verification is skipped (autoVerify disabled).
    public static let skipped = VerificationReport(
        layers: [], overallStatus: .skipped, durationSeconds: 0
    )

    /// Skipped-report factory carrying the reason verification did not run.
    public static func skipped(reason: SkipReason) -> VerificationReport {
        VerificationReport(
            layers: [], overallStatus: .skipped, durationSeconds: 0,
            skipReason: reason
        )
    }
}

/// When adding cases, update all switch sites across the project.
public enum VerificationStatus: Sendable, Equatable {
    case pass
    case warn(String)
    case info(String)
    /// Sensitive text remains readable OUTSIDE every redacted region — the
    /// redaction operation itself completed, but an un-redacted occurrence
    /// of an applied term survives. User-recoverable (text search → redact),
    /// so it aggregates above `warn` and below `fail`; `fail` is reserved
    /// for defects in the redacted output itself.
    case attention(String)
    case fail(String)
    case skipped        // Verification was not run (autoVerify disabled)

    /// Equatable compares case identity only — the associated String is ignored.
    /// This allows `status == .fail` in test assertions without binding the message.
    /// To compare messages, use `if case .fail(let msg) = status { … }`.
    public static func == (lhs: VerificationStatus, rhs: VerificationStatus) -> Bool {
        switch (lhs, rhs) {
        case (.pass, .pass): true
        case (.warn, .warn): true
        case (.info, .info): true
        case (.attention, .attention): true
        case (.fail, .fail): true
        case (.skipped, .skipped): true
        default: false
        }
    }

    /// Case-identity helpers — clearer than `status != .fail("")`.
    public var isFail: Bool { if case .fail = self { true } else { false } }
    public var isWarn: Bool { if case .warn = self { true } else { false } }
    public var isInfo: Bool { if case .info = self { true } else { false } }
    public var isAttention: Bool { if case .attention = self { true } else { false } }
    public var isSkipped: Bool { if case .skipped = self { true } else { false } }
}

/// Result of a single verification layer.
/// Produced by Verification/ components, consumed by VerificationReport
/// and the verification results UI.
public struct LayerResult: Sendable {
    /// Human-readable layer name (e.g., "Text Extraction", "OCR Check")
    public let name: String
    /// SF Symbol name for the layer
    public let symbolName: String
    /// Result status for this layer
    public let status: VerificationStatus
    /// Brief description of what this check found (1 line, shown in collapsed row)
    public let shortDescription: String
    /// Detailed explanation (shown when the row is expanded)
    public let detailDescription: String
    /// Page indices where issues were found (nil if check is document-wide)
    public let pageReferences: [Int]?
    /// Wall-clock duration of this layer's check
    public let durationSeconds: Double
    /// Display-only: the applied term texts behind an `.attention` result,
    /// so the results UI can tell the user exactly which text to search for.
    /// Status messages stay content-free; this field exists
    /// solely for in-app display composition and is never logged or
    /// persisted. Nil for every other status.
    public let reviewTermTexts: [String]?
    /// Identity of the check that produced this result, when known. Nil for
    /// results built without one (synthetic rows, legacy persisted reports);
    /// consumers key on identity first and fall back to `name`.
    public let layer: VerificationLayer?
    /// Display-only: the Search Re-check's per-query lines (label · found ·
    /// applied · remaining · route). Like `reviewTermTexts`, this field
    /// exists solely for in-app display composition and is never logged or
    /// persisted. Nil for every other layer.
    public let queryLines: [SearchRecheckQueryLine]?

    public init(name: String, symbolName: String, status: VerificationStatus,
                shortDescription: String, detailDescription: String,
                pageReferences: [Int]?, durationSeconds: Double,
                reviewTermTexts: [String]? = nil,
                layer: VerificationLayer? = nil,
                queryLines: [SearchRecheckQueryLine]? = nil) {
        self.name = name
        self.symbolName = symbolName
        self.status = status
        self.shortDescription = shortDescription
        self.detailDescription = detailDescription
        self.pageReferences = pageReferences
        self.durationSeconds = durationSeconds
        self.reviewTermTexts = reviewTermTexts
        self.layer = layer
        self.queryLines = queryLines
    }
}

/// One per-query line of the Search Re-check's expanded detail: the query
/// label, the original run's found count, the applied count, the remaining
/// count on the output, and which evidence the pages were read from.
/// Display-only — composed by the results row, never logged or persisted.
public struct SearchRecheckQueryLine: Sendable, Equatable {
    /// Which evidence backed the pages this query was re-run on.
    public enum Route: Sendable, Equatable {
        case textLayer
        case ocr
        /// Both, by page count. `(0, 0)` when no page could be read.
        case mixed(textPages: Int, ocrPages: Int)
    }

    /// Per-term breakdown of a multi-term query. `found` and `applied` are
    /// nil until the record carries per-term counts; `remaining` is
    /// measured on the output.
    public struct PerTerm: Sendable, Equatable {
        public let term: String
        public let found: Int?
        public let applied: Int?
        public let remaining: Int

        public init(term: String, found: Int?, applied: Int?, remaining: Int) {
            self.term = term
            self.found = found
            self.applied = applied
            self.remaining = remaining
        }
    }

    public let label: String
    public let foundCount: Int
    /// The original run stopped at the result cap ("found 1,000+").
    public let foundHitCap: Bool
    public let appliedCount: Int
    public let remainingCount: Int
    public let route: Route
    /// "case-sensitive" / "whole word", in that order, when set.
    public let optionBadges: [String]
    public let perTerm: [PerTerm]?

    public init(
        label: String,
        foundCount: Int,
        foundHitCap: Bool,
        appliedCount: Int,
        remainingCount: Int,
        route: Route,
        optionBadges: [String] = [],
        perTerm: [PerTerm]? = nil
    ) {
        self.label = label
        self.foundCount = foundCount
        self.foundHitCap = foundHitCap
        self.appliedCount = appliedCount
        self.remainingCount = remainingCount
        self.route = route
        self.optionBadges = optionBadges
        self.perTerm = perTerm
    }
}
