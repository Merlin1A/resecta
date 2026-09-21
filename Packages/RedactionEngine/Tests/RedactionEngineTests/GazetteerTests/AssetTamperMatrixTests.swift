import Foundation
import Testing
@testable import RedactionEngine

// The adversarial tamper matrix as ONE harness: every shipped engine asset
// (the eighteen files under Resources/Gazetteers, Classifier and Audit) is
// tampered in each of four ways in a scratch copy of the shipped tree, and
// the detector's load outcome is measured against an expected table.
//
// Measured per cell, through `PIIDetector.loadWithDiagnostics(bundle:)`:
//   withheld    — the five signature-gated loaders are nil (the corpus verdict
//                 is false, exactly as a bad manifest signature).
//   diagnostics — the set of loader names attributed in `failedGazetteers`.
//   banner      — `didDegrade` (drives the app's degraded-detection banner).
//
// The expected table is the ruling: a tampered TRUST-GATED asset (the files the
// five gated loaders read, plus the manifest triple) withholds the corpus; a
// tampered reference / Classifier / Audit asset reports under its own loader's
// diagnostic and raises the banner while the loader keeps its fail-open
// fallback. Cells that today's tree gets wrong are the reason the per-asset
// digests and the loader version fences exist. The measured table is printed
// (and written to `$RESECTA_TAMPER_TABLE_OUT` when set) so the evidence pair
// — today's column beside the ruling — is the record.
@Suite("Asset tamper matrix", .serialized)
struct AssetTamperMatrixTests {

    // MARK: - The universe

    /// Every file under the shipped resource tree except `.gitkeep`.
    enum Asset: String, CaseIterable {
        case surnamesBloom = "Gazetteers/surnames.bloom"
        case givenNamesBloom = "Gazetteers/given-names.bloom"
        case nameCommonWords = "Gazetteers/name-common-words.json"
        case dlPatterns = "Gazetteers/dl_patterns.json"
        case passportPatterns = "Gazetteers/passport_patterns.json"
        case contextKeywords = "Gazetteers/context-keywords.json"
        case negativeContext = "Gazetteers/negative-context.json"
        case institutions = "Gazetteers/institutions.json"
        case addressComponents = "Gazetteers/address_components.json"
        case zipScfStates = "Gazetteers/zip_scf_states.json"
        case doctypeKeywords = "Classifier/doctype-keywords.json"
        case contextScorer = "Classifier/context-scorer.json"
        case doctypeTemperature = "Classifier/doctype-temperature.json"
        case presetThresholds = "Classifier/preset-thresholds.json"
        case ruleCatalog = "Audit/rule-catalog.json"
        case manifest = "Gazetteers/gazetteer-manifest.json"
        case signature = "Gazetteers/gazetteer_manifest.sig"
        case publicKey = "Gazetteers/manifest_public_key.pem"

        var isJSON: Bool { rawValue.hasSuffix(".json") }

        /// The assets whose tampering must withhold the corpus: the files the
        /// five signature-gated loaders read, and the manifest triple itself.
        var isTrustGated: Bool {
            switch self {
            case .surnamesBloom, .givenNamesBloom, .nameCommonWords,
                 .dlPatterns, .passportPatterns, .contextKeywords, .negativeContext,
                 .manifest, .signature, .publicKey:
                return true
            case .institutions, .addressComponents, .zipScfStates,
                 .doctypeKeywords, .contextScorer, .doctypeTemperature, .presetThresholds,
                 .ruleCatalog:
                return false
            }
        }

        /// The diagnostics name a tampered UNGATED asset reports under.
        var ownDiagnostic: String? {
            switch self {
            case .institutions: return GazetteerLoadDiagnostics.Gazetteer.institutionGazetteer.rawValue
            case .addressComponents: return GazetteerLoadDiagnostics.Gazetteer.addressComponentsGazetteer.rawValue
            case .zipScfStates: return GazetteerLoadDiagnostics.Gazetteer.zipStateTableLoader.rawValue
            case .doctypeKeywords: return GazetteerLoadDiagnostics.Gazetteer.documentTypeClassifier.rawValue
            case .contextScorer: return GazetteerLoadDiagnostics.Gazetteer.contextScorerWeights.rawValue
            case .doctypeTemperature: return GazetteerLoadDiagnostics.Gazetteer.doctypeTemperature.rawValue
            case .presetThresholds: return GazetteerLoadDiagnostics.Gazetteer.presetThresholds.rawValue
            // The rule catalog has no detection loader of its own; a digest
            // failure on it reports under the integrity pass's own name.
            case .ruleCatalog: return "AssetIntegrity"
            default: return nil
            }
        }
    }

    enum Tamper: String, CaseIterable {
        /// One bit flipped in the middle byte of the file.
        case bitFlipped = "bit-flipped"
        /// The file removed.
        case missing = "missing"
        /// The top-level `version` rewritten to 0 (the manifest: "0.0.0").
        case staleVersion = "stale-version (0)"
        /// The top-level `version` rewritten to 99 (the manifest: "99.0.0").
        case versionBumped = "version-bumped (99)"

        /// Version tampers only apply to JSON assets carrying `version`.
        func applies(to asset: Asset) -> Bool {
            switch self {
            case .bitFlipped, .missing: return true
            case .staleVersion, .versionBumped: return asset.isJSON
            }
        }
    }

    struct Outcome: Equatable, CustomStringConvertible {
        let withheld: Bool
        let diagnostics: Set<String>
        let banner: Bool
        var description: String {
            let names = diagnostics.isEmpty ? "—" : diagnostics.sorted().joined(separator: " · ")
            return "withheld \(withheld ? "Y" : "n") · banner \(banner ? "Y" : "n") · \(names)"
        }
    }

    static let fiveGated: Set<String> = [
        GazetteerLoadDiagnostics.Gazetteer.nameGazetteer.rawValue,
        GazetteerLoadDiagnostics.Gazetteer.dlPatternGazetteer.rawValue,
        GazetteerLoadDiagnostics.Gazetteer.passportPatternGazetteer.rawValue,
        GazetteerLoadDiagnostics.Gazetteer.contextKeywordsLoader.rawValue,
        GazetteerLoadDiagnostics.Gazetteer.negativeContextGazetteer.rawValue,
    ]

    /// The expected table — the ruling, not today's behaviour.
    static func expected(_ asset: Asset, _ tamper: Tamper) -> Outcome {
        if asset.isTrustGated {
            return Outcome(withheld: true, diagnostics: fiveGated, banner: true)
        }
        return Outcome(withheld: false, diagnostics: [asset.ownDiagnostic!], banner: true)
    }

    // MARK: - Scratch bundles

    private enum HarnessError: Error {
        case cannotCreateBundle(String)
        case notJSONObject(String)
    }

    // Nested under one sandbox so the bare temp root gains no entries during
    // a parallel `BackupExclusionTests` snapshot (see SignedManifestTests).
    static let sandboxRoot: URL = {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "RedactionEngineTests-AssetTamperMatrix-Sandbox", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }()

    /// A fresh copy of the shipped resource tree (the test bundle carries
    /// byte-identical copies of Gazetteers/, Classifier/ and Audit/). A new
    /// directory per cell — `Bundle` caches by path.
    static func makeScratchBundle() throws -> (bundle: Bundle, root: URL) {
        let source = try #require(Bundle.module.resourceURL)
        let root = sandboxRoot.appending(path: "cell-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for subdir in ["Gazetteers", "Classifier", "Audit"] {
            try FileManager.default.copyItem(
                at: source.appending(path: subdir, directoryHint: .isDirectory),
                to: root.appending(path: subdir, directoryHint: .isDirectory)
            )
        }
        guard let bundle = Bundle(path: root.path()) else {
            throw HarnessError.cannotCreateBundle(root.path())
        }
        return (bundle, root)
    }

    static func apply(_ tamper: Tamper, to asset: Asset, in root: URL) throws {
        let url = root.appending(path: asset.rawValue)
        switch tamper {
        case .bitFlipped:
            var bytes = try Data(contentsOf: url)
            bytes[bytes.count / 2] ^= 0x01
            try bytes.write(to: url)
        case .missing:
            try FileManager.default.removeItem(at: url)
        case .staleVersion, .versionBumped:
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
            guard var dict = object as? [String: Any] else {
                throw HarnessError.notJSONObject(asset.rawValue)
            }
            let number = tamper == .staleVersion ? 0 : 99
            dict["version"] = asset == .manifest ? "\(number).0.0" : number
            let rewritten = try JSONSerialization.data(
                withJSONObject: dict, options: [.sortedKeys, .prettyPrinted])
            try rewritten.write(to: url)
        }
    }

    // MARK: - Measurement

    private static let gatedLabels = [
        "nameGazetteer", "dlPatternGazetteer", "passportPatternGazetteer",
        "contextLoader", "negativeContextGazetteer",
    ]

    private static func isNilOptional(_ value: Any) -> Bool {
        let mirror = Mirror(reflecting: value)
        return mirror.displayStyle == .optional && mirror.children.isEmpty
    }

    static func measure(_ bundle: Bundle) -> Outcome {
        let (detector, diagnostics) = PIIDetector.loadWithDiagnostics(bundle: bundle)
        var nilCount = 0
        for child in Mirror(reflecting: detector).children {
            guard let label = child.label, gatedLabels.contains(label) else { continue }
            if isNilOptional(child.value) { nilCount += 1 }
        }
        return Outcome(
            withheld: nilCount == gatedLabels.count,
            diagnostics: Set(diagnostics.failedGazetteers),
            banner: diagnostics.didDegrade
        )
    }

    // MARK: - Tests

    @Test("The asset universe is exactly the shipped resource tree")
    func universeMatchesShippedTree() throws {
        let source = try #require(Bundle.module.resourceURL)
        var found: Set<String> = []
        for subdir in ["Gazetteers", "Classifier", "Audit"] {
            let dir = source.appending(path: subdir, directoryHint: .isDirectory)
            for name in try FileManager.default.contentsOfDirectory(atPath: dir.path())
            where name != ".gitkeep" {
                found.insert("\(subdir)/\(name)")
            }
        }
        #expect(found == Set(Asset.allCases.map(\.rawValue)),
                "a shipped asset without a matrix row, or a row without a file")
    }

    @Test("Untampered scratch tree: nothing withheld, nothing reported")
    func untamperedScratchTreeIsClean() throws {
        let (bundle, root) = try Self.makeScratchBundle()
        defer { try? FileManager.default.removeItem(at: root) }
        let outcome = Self.measure(bundle)
        #expect(outcome == Outcome(withheld: false, diagnostics: [], banner: false),
                "the shipped tree itself must load clean: \(outcome)")
    }

    @Test("Every asset × every tamper matches the expected table")
    func matrix() throws {
        var rows: [String] = []
        var redCells: [String] = []
        for asset in Asset.allCases {
            for tamper in Tamper.allCases {
                guard tamper.applies(to: asset) else {
                    rows.append("| `\(asset.rawValue)` | \(tamper.rawValue) | n/a | n/a | — |")
                    continue
                }
                let (bundle, root) = try Self.makeScratchBundle()
                defer { try? FileManager.default.removeItem(at: root) }
                try Self.apply(tamper, to: asset, in: root)
                let measured = Self.measure(bundle)
                let expected = Self.expected(asset, tamper)
                let verdict: String
                if measured == expected {
                    verdict = "MATCH"
                } else if !measured.banner {
                    verdict = "✗ SILENT"
                } else {
                    verdict = "✗ PARTIAL"
                }
                rows.append("| `\(asset.rawValue)` | \(tamper.rawValue) | \(measured) | \(expected) | \(verdict) |")
                if measured != expected {
                    redCells.append("\(asset.rawValue) × \(tamper.rawValue): measured \(measured); expected \(expected)")
                }
                #expect(measured == expected,
                        "\(asset.rawValue) × \(tamper.rawValue): measured \(measured), expected \(expected)")
            }
        }
        let table = (["| asset | tamper | measured | expected | verdict |", "|---|---|---|---|---|"] + rows)
            .joined(separator: "\n")
        let summary = "\(rows.count) cells · \(redCells.count) RED"
        print("ASSET TAMPER MATRIX — \(summary)\n\(table)")
        if let out = ProcessInfo.processInfo.environment["RESECTA_TAMPER_TABLE_OUT"] {
            let url = URL(fileURLWithPath: out)
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? "# Asset tamper matrix — \(summary)\n\n\(table)\n\n## RED cells\n\n"
                .appending(redCells.map { "- \($0)" }.joined(separator: "\n"))
                .appending("\n")
                .write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
