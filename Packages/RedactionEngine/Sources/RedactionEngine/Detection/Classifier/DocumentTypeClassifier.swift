import Foundation
import OSLog

// Plan Stage 0 — per-page five-class document classifier.
// A4 / G5: binary keyword presence, per-class term cap (no frequency weighting,
// no keyword-stuffing leverage), structural regex bonuses as fixed increments.
// <5 ms/page target on A17 Pro.
//
// Phase 1 ships raw softmax as rank only. Temperature (doctype-temperature.json)
// lands in Phase 3; Stage 6 consumes calibrated softmax via CalibratedScorer.
// Missing JSON → classifier returns `.generic` for every page (graceful
// degradation per the pipeline's zero-telemetry invariant).

public struct DoctypeResult: Sendable {
    public let primary: DoctypeClass
    public let runnerUp: DoctypeClass?
    public let softmax: [DoctypeClass: Double]
    /// Top contributing keywords, for the G5 "Why this classification?" panel
    /// (Phase 3 UI). Kept in-memory only — never logged or persisted
    /// (ARCHITECTURE.md §12.2).
    public let topKeywords: [TopKeyword]

    public struct TopKeyword: Sendable, Equatable, Hashable {
        public let keyword: String
        public let classContributedTo: DoctypeClass
        /// The weight contribution from this keyword's presence (after term
        /// cap). For binary presence with cap C and K matched keywords in
        /// class, each keyword's share is `min(K, C) / K`.
        public let weight: Double

        public init(keyword: String, classContributedTo: DoctypeClass, weight: Double) {
            self.keyword = keyword
            self.classContributedTo = classContributedTo
            self.weight = weight
        }
    }

    public init(
        primary: DoctypeClass,
        runnerUp: DoctypeClass?,
        softmax: [DoctypeClass: Double],
        topKeywords: [TopKeyword]
    ) {
        self.primary = primary
        self.runnerUp = runnerUp
        self.softmax = softmax
        self.topKeywords = topKeywords
    }
}

/// W9 — detailed classifier output shared with the "Document profile" panel.
/// A read-out of the same internal state that `classify(...)` consumes;
/// lives alongside DoctypeResult because it reuses TopKeyword.
public struct DoctypeExplanation: Sendable {
    public let primary: DoctypeClass
    public let primaryProbability: Double
    /// Top-3 (class, probability) pairs sorted by probability desc.
    public let topProbabilities: [(DoctypeClass, Double)]
    public let keywordContributors: [DoctypeResult.TopKeyword]
    /// Structural-bonus pattern IDs that fired on the page.
    public let structuralBonuses: [String]

    public init(
        primary: DoctypeClass,
        primaryProbability: Double,
        topProbabilities: [(DoctypeClass, Double)],
        keywordContributors: [DoctypeResult.TopKeyword],
        structuralBonuses: [String]
    ) {
        self.primary = primary
        self.primaryProbability = primaryProbability
        self.topProbabilities = topProbabilities
        self.keywordContributors = keywordContributors
        self.structuralBonuses = structuralBonuses
    }
}

extension DoctypeExplanation: Equatable {
    public static func == (lhs: DoctypeExplanation, rhs: DoctypeExplanation) -> Bool {
        lhs.primary == rhs.primary
            && abs(lhs.primaryProbability - rhs.primaryProbability) < 1e-9
            && lhs.topProbabilities.count == rhs.topProbabilities.count
            && zip(lhs.topProbabilities, rhs.topProbabilities).allSatisfy { l, r in
                l.0 == r.0 && abs(l.1 - r.1) < 1e-9
            }
            && lhs.keywordContributors == rhs.keywordContributors
            && lhs.structuralBonuses == rhs.structuralBonuses
    }
}

public struct DocumentTypeClassifier: Sendable {

    /// Keyword set per class + structural regex bonuses + per-doc term cap.
    private let data: Data

    struct Data: Sendable {
        let termCapPerDoc: Int
        let perClass: [DoctypeClass: ClassConfig]
        let isEmpty: Bool
    }

    struct ClassConfig: Sendable {
        let keywords: Set<String>
        let structuralBonuses: [StructuralBonus]
    }

    struct StructuralBonus: Sendable {
        let id: String
        let compiledPattern: NSRegularExpression
        let bonus: Double
    }

    public init() {
        self.data = Self.loadData(from: .module).data
    }

    /// Testing init — inject a custom bundle for fixture-based tests.
    init(bundle: Bundle) {
        self.data = Self.loadData(from: bundle).data
    }

    /// Construct from a pre-loaded keyword table so
    /// `loadWithDiagnostics` builds the classifier and its load diagnostic from
    /// a single `loadData` pass.
    private init(data: Data) {
        self.data = data
    }

    // MARK: - Classification

    /// Intermediate output of the keyword / structural-bonus kernel.
    /// Shared by `classify(...)` and `explain(...)`; extracted so both
    /// entry points operate on identical numbers.
    struct Logits: Sendable {
        let rawScores: [DoctypeClass: Double]
        let keywordContributors: [DoctypeResult.TopKeyword]
        let structuralBonusesApplied: [String]
    }

    /// Run the keyword-intersection + structural-bonus pass. Returns raw
    /// pre-softmax scores; softmax is applied by the caller so both
    /// `classify(...)` and `explain(...)` agree on numerics.
    func computeLogits(pageText: String) -> Logits {
        if data.isEmpty {
            return Logits(
                rawScores: [:],
                keywordContributors: [],
                structuralBonusesApplied: []
            )
        }

        // Lowercased NFKC normalization — stable matching across unicode forms.
        let normalized = pageText.lowercased().precomposedStringWithCompatibilityMapping

        let tokens = normalized.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "-" && $0 != "'" })
        let tokenSet = Set(tokens.map(String.init))

        var rawScores: [DoctypeClass: Double] = [:]
        var keywordContributions: [DoctypeResult.TopKeyword] = []
        var structuralBonusesApplied: [String] = []

        for (cls, config) in data.perClass {
            let hits = tokenSet.intersection(config.keywords)
            let capped = min(hits.count, data.termCapPerDoc)
            let perHit = hits.isEmpty ? 0.0 : Double(capped) / Double(hits.count)
            var classScore = Double(capped)

            for hit in hits.prefix(5) {
                keywordContributions.append(.init(
                    keyword: hit,
                    classContributedTo: cls,
                    weight: perHit
                ))
            }

            let nsText = normalized as NSString
            let fullRange = NSRange(location: 0, length: nsText.length)
            for bonus in config.structuralBonuses {
                if bonus.compiledPattern.firstMatch(in: normalized, range: fullRange) != nil {
                    classScore += bonus.bonus
                    structuralBonusesApplied.append(bonus.id)
                }
            }

            rawScores[cls] = classScore
        }

        return Logits(
            rawScores: rawScores,
            keywordContributors: keywordContributions,
            structuralBonusesApplied: structuralBonusesApplied
        )
    }

    @concurrent
    public func classify(pageText: String) async -> DoctypeResult {
        // Graceful degradation: no loaded data → uniform softmax, primary = .generic.
        if data.isEmpty {
            return .uniform
        }

        let logits = computeLogits(pageText: pageText)
        let softmax = Self.softmax(logits.rawScores)
        // Exact softmax ties break on rawValue.
        // Without the secondary key, tie order is Dictionary iteration order,
        // which is per-launch randomized — the same page could gate under a
        // different doctype across launches.
        let ranked = softmax.sorted {
            if $0.value != $1.value { return $0.value > $1.value }
            return $0.key.rawValue < $1.key.rawValue
        }
        let primary = ranked.first?.key ?? .generic
        let runnerUp = ranked.dropFirst().first?.key

        // Keep top-5 keywords by weight, primary class preferred.
        let topKeywords = logits.keywordContributors
            .sorted { $0.weight > $1.weight }
            .prefix(5)

        return DoctypeResult(
            primary: primary,
            runnerUp: runnerUp,
            softmax: softmax,
            topKeywords: Array(topKeywords)
        )
    }

    // MARK: - W9 Explain

    /// W9 — expose classifier state as a top-3 probability breakdown plus
    /// top-5 keyword contributors and the structural bonuses that fired.
    /// Shares `computeLogits(...)` with `classify(...)` so the primary
    /// class + probability always agree with the triage sheet's G5 panel.
    @concurrent
    public func explain(pageText: String) async -> DoctypeExplanation {
        if data.isEmpty {
            let uniform = 1.0 / Double(DoctypeClass.canonicalOrder.count)
            return DoctypeExplanation(
                primary: .generic,
                primaryProbability: uniform,
                topProbabilities: DoctypeClass.canonicalOrder.prefix(3).map { ($0, uniform) },
                keywordContributors: [],
                structuralBonuses: []
            )
        }

        let logits = computeLogits(pageText: pageText)
        let softmax = Self.softmax(logits.rawScores)
        let paired: [(DoctypeClass, Double)] = DoctypeClass.canonicalOrder.map { ($0, softmax[$0] ?? 0.0) }
        // Same rawValue tie-break as classify(...) so the W9 panel and the
        // gating primary agree on exact ties.
        let sorted = paired.sorted {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            return $0.0.rawValue < $1.0.rawValue
        }
        let top3 = Array(sorted.prefix(3))
        let primary = sorted.first?.0 ?? .generic
        let primaryProbability = sorted.first?.1 ?? 0.0

        let topKeywords = logits.keywordContributors
            .sorted { $0.weight > $1.weight }
            .prefix(5)

        return DoctypeExplanation(
            primary: primary,
            primaryProbability: primaryProbability,
            topProbabilities: top3,
            keywordContributors: Array(topKeywords),
            structuralBonuses: logits.structuralBonusesApplied
        )
    }

    // MARK: - Phase 3b support — raw logits for softmax dump

    /// Emit pre-softmax logits in canonical order (court / medical / financial
    /// / foia / generic). Phase 3b SoftmaxDumpTests write these to
    /// `doctype_softmax_dump.json` for DataPipeline temperature fitting.
    @concurrent
    public func rawLogits(pageText: String) async -> [Double] {
        let result = await classify(pageText: pageText)
        return DoctypeClass.canonicalOrder.map { cls in
            // Recover log-odds from the softmax for dump purposes.
            let p = result.softmax[cls] ?? 0.0
            return p > 0 ? Foundation.log(p) : -30.0
        }
    }

    // MARK: - Softmax

    private static func softmax(_ raw: [DoctypeClass: Double]) -> [DoctypeClass: Double] {
        let values = raw.values
        let maxValue = values.max() ?? 0.0
        var exps: [DoctypeClass: Double] = [:]
        var sum = 0.0
        for cls in DoctypeClass.canonicalOrder {
            let v = raw[cls] ?? 0.0
            let e = Foundation.exp(v - maxValue)
            exps[cls] = e
            sum += e
        }
        if sum == 0 {
            return Dictionary(uniqueKeysWithValues: DoctypeClass.canonicalOrder.map { ($0, 1.0 / Double(DoctypeClass.canonicalOrder.count)) })
        }
        for cls in DoctypeClass.canonicalOrder {
            exps[cls] = (exps[cls] ?? 0) / sum
        }
        return exps
    }

    // MARK: - Loader

    /// Load the classifier and report WHY the keyword table is empty,
    /// so the caller can fold the outcome into `GazetteerLoadDiagnostics` instead
    /// of the classifier silently returning `.generic` for every page. Returns
    /// `(classifier, nil)` on success. `DetectionOrchestrator` owns the live
    /// classifier; `PIIDetector.loadWithDiagnostics` calls this purely for the
    /// load status.
    static func loadWithDiagnostics(
        bundle: Bundle = .module
    ) -> (classifier: DocumentTypeClassifier, diagnostic: GazetteerLoadDiagnostics?) {
        let loaded = loadData(from: bundle)
        let classifier = DocumentTypeClassifier(data: loaded.data)
        let diagnostic = loaded.failureReason.map {
            GazetteerLoadDiagnostics().appending(.documentTypeClassifier, reason: $0)
        }
        return (classifier, diagnostic)
    }

    /// Returns the decoded keyword table plus, on failure, a mechanism-only
    /// reason string. Failures still degrade to an empty table so the
    /// classifier returns `.generic` — graceful behavior is unchanged; the
    /// reason is additive for diagnostics. Never contains document content or
    /// file paths.
    private static func loadData(from bundle: Bundle) -> (data: Data, failureReason: String?) {
        guard let url = bundle.url(
            forResource: "doctype-keywords",
            withExtension: "json",
            subdirectory: "Classifier"
        ) else {
            logger.info("doctype-keywords.json not bundled; classifier returns .generic")
            return (Data(termCapPerDoc: 1, perClass: [:], isEmpty: true),
                    "doctype-keywords.json not bundled")
        }
        do {
            let bytes = try Foundation.Data(contentsOf: url)
            let wire = try JSONDecoder().decode(WireFormat.self, from: bytes)
            return (try wire.toData(), nil)
        } catch {
            logger.warning("doctype-keywords.json decode failed; classifier returns .generic: \(String(describing: error), privacy: .public)")
            return (Data(termCapPerDoc: 1, perClass: [:], isEmpty: true),
                    "doctype-keywords.json decode failed: \(String(describing: error))")
        }
    }
}

private extension DoctypeResult {
    static let uniform: DoctypeResult = {
        let uniform = 1.0 / Double(DoctypeClass.canonicalOrder.count)
        let softmax = Dictionary(uniqueKeysWithValues:
            DoctypeClass.canonicalOrder.map { ($0, uniform) })
        return DoctypeResult(
            primary: .generic,
            runnerUp: nil,
            softmax: softmax,
            topKeywords: []
        )
    }()
}

// MARK: - Wire format (DataPipeline/schemas/doctype_keywords.schema.json)

private struct WireFormat: Decodable {
    let version: Int
    let term_cap_per_doc: Int
    let classes: [ClassWire]

    struct ClassWire: Decodable {
        let name: String
        let keywords: [String]
        let structural_bonuses: [BonusWire]
    }

    struct BonusWire: Decodable {
        let id: String
        let pattern: String
        let bonus: Double
    }

    func toData() throws -> DocumentTypeClassifier.Data {
        var perClass: [DoctypeClass: DocumentTypeClassifier.ClassConfig] = [:]
        for cls in classes {
            guard let doctype = DoctypeClass(rawValue: cls.name) else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: [],
                    debugDescription: "Unknown doctype: \(cls.name)"
                ))
            }
            let compiled = cls.structural_bonuses.compactMap { bw -> DocumentTypeClassifier.StructuralBonus? in
                guard bw.pattern.count <= 200 else { return nil }
                guard let re = try? NSRegularExpression(pattern: bw.pattern) else { return nil }
                return DocumentTypeClassifier.StructuralBonus(
                    id: bw.id,
                    compiledPattern: re,
                    bonus: bw.bonus
                )
            }
            perClass[doctype] = DocumentTypeClassifier.ClassConfig(
                keywords: Set(cls.keywords.map { $0.lowercased() }),
                structuralBonuses: compiled
            )
        }
        return DocumentTypeClassifier.Data(
            termCapPerDoc: term_cap_per_doc,
            perClass: perClass,
            isEmpty: perClass.isEmpty
        )
    }
}

private let logger = Logger(subsystem: "app.resecta.engine", category: "DocumentTypeClassifier")
