import Testing
import Foundation
@testable import RedactionEngine

// The three `Classifier/` quality assets (context-scorer.json,
// doctype-temperature.json, preset-thresholds.json) degrade gracefully when
// missing or invalid: identity scorer, identity T = 1.0, built-in threshold
// defaults. These tests pin that each fallback REPORTS through
// `GazetteerLoadDiagnostics` — driving the same visible-degrade banner the
// corpus loaders use — and that the fallback values are unchanged (the
// diagnostics are reporting-only).
//
// Injection shape: scratch bundles holding altered copies of the canonical
// assets, loaded through the production entry points. The canonical bytes are
// reachable from the test target's `Bundle.module` via the Package.swift
// Classifier copy entry (same wiring as the Gazetteers entry).

@Suite("Asset load diagnostics")
struct AssetLoadDiagnosticsTests {

    // MARK: - Helpers

    private enum TestBundleError: Error {
        case cannotCreateBundle(String)
    }

    /// The canonical bytes of a `Classifier/` asset from the test bundle's
    /// copy of the engine resources.
    private static func canonicalAssetData(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(
            forResource: name, withExtension: "json", subdirectory: "Classifier"
        ), "test bundle must carry the canonical Classifier assets")
        return try Data(contentsOf: url)
    }

    /// A scratch bundle whose `Classifier/` holds exactly the supplied files.
    private static func makeClassifierBundle(files: [String: Data]) throws -> Bundle {
        let tempBase = FileManager.default.temporaryDirectory
            .appending(
                path: "asset-diagnostics-test-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        let classifierDir = tempBase.appending(path: "Classifier", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: classifierDir, withIntermediateDirectories: true
        )
        for (name, data) in files {
            try data.write(to: classifierDir.appending(path: "\(name).json"))
        }
        guard let bundle = Bundle(path: tempBase.path()) else {
            throw TestBundleError.cannotCreateBundle(tempBase.path())
        }
        return bundle
    }

    /// A scratch copy of the full engine resource layout (Gazetteers +
    /// Classifier) so `PIIDetector.loadWithDiagnostics(bundle:)` runs its
    /// valid-signature path against it. Each call uses a fresh directory —
    /// `Bundle` caches by path, so altered fixtures always get their own
    /// bundle instance.
    private static func makeScratchEngineBundle() throws -> (bundle: Bundle, root: URL) {
        let resourceRoot = try #require(Bundle.module.resourceURL)
        let tempBase = FileManager.default.temporaryDirectory
            .appending(
                path: "asset-diagnostics-engine-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
        for subdir in ["Gazetteers", "Classifier"] {
            try FileManager.default.copyItem(
                at: resourceRoot.appending(path: subdir, directoryHint: .isDirectory),
                to: tempBase.appending(path: subdir, directoryHint: .isDirectory)
            )
        }
        guard let bundle = Bundle(path: tempBase.path()) else {
            throw TestBundleError.cannotCreateBundle(tempBase.path())
        }
        return (bundle, tempBase)
    }

    // MARK: - Per-loader diagnostics (reporting + unchanged fallback values)

    @Test("Context scorer: hash-mismatched bytes report and fall back; canonical bytes stay silent")
    func contextScorerHashMismatchReportsIdentityFallback() throws {
        var altered = try Self.canonicalAssetData("context-scorer")
        altered[64] ^= 0xFF
        let alteredBundle = try Self.makeClassifierBundle(files: ["context-scorer": altered])
        let alteredResult = ContextScorerWeights.loadWithDiagnostics(from: alteredBundle)
        #expect(alteredResult.failureReason?.contains("hash mismatch") == true,
                "bytes that do not match the pinned hash must carry a reason")

        let canonical = try Self.canonicalAssetData("context-scorer")
        let canonicalBundle = try Self.makeClassifierBundle(files: ["context-scorer": canonical])
        let canonicalResult = ContextScorerWeights.loadWithDiagnostics(from: canonicalBundle)
        #expect(canonicalResult.failureReason == nil,
                "the shipped bytes must load without a diagnostic")
    }

    @Test("Context scorer: missing asset reports not-bundled")
    func contextScorerMissingAssetReports() throws {
        let emptyBundle = try Self.makeClassifierBundle(files: [:])
        let result = ContextScorerWeights.loadWithDiagnostics(from: emptyBundle)
        #expect(result.failureReason == "context-scorer.json not bundled")
    }

    @Test("Doctype temperature: invalid payloads report and fall back to T=1.0")
    func doctypeTemperatureInvalidPayloadReportsIdentityFallback() throws {
        let nonPositive = Data(#"{"version": 1, "temperature": -1.0}"#.utf8)
        let nonPositiveBundle = try Self.makeClassifierBundle(
            files: ["doctype-temperature": nonPositive])
        let nonPositiveResult = CalibratedScorer.loadTemperatureWithDiagnostics(from: nonPositiveBundle)
        #expect(nonPositiveResult.temperature == 1.0)
        #expect(nonPositiveResult.failureReason?.contains("non-positive") == true)

        let corrupt = Data("not a temperature payload".utf8)
        let corruptBundle = try Self.makeClassifierBundle(files: ["doctype-temperature": corrupt])
        let corruptResult = CalibratedScorer.loadTemperatureWithDiagnostics(from: corruptBundle)
        #expect(corruptResult.temperature == 1.0)
        #expect(corruptResult.failureReason != nil)

        let canonical = try Self.canonicalAssetData("doctype-temperature")
        let canonicalBundle = try Self.makeClassifierBundle(files: ["doctype-temperature": canonical])
        let canonicalResult = CalibratedScorer.loadTemperatureWithDiagnostics(from: canonicalBundle)
        #expect(canonicalResult.failureReason == nil)
        #expect(canonicalResult.temperature > 0)
    }

    @Test("Preset thresholds: corrupt asset reports and falls back to built-in defaults")
    func presetThresholdsCorruptAssetReportsBuiltInDefaults() throws {
        let corrupt = Data("not a preset table".utf8)
        let corruptBundle = try Self.makeClassifierBundle(files: ["preset-thresholds": corrupt])
        let corruptResult = PresetThresholdBundle.loadWithDiagnostics(from: corruptBundle)
        #expect(corruptResult.failureReason != nil)
        #expect(corruptResult.bundle.status == .placeholder,
                "fallback must be the built-in defaults, unchanged")
        #expect(corruptResult.bundle.version == 0)

        let canonical = try Self.canonicalAssetData("preset-thresholds")
        let canonicalBundle = try Self.makeClassifierBundle(files: ["preset-thresholds": canonical])
        let canonicalResult = PresetThresholdBundle.loadWithDiagnostics(from: canonicalBundle)
        #expect(canonicalResult.failureReason == nil)
    }

    // MARK: - Detector integration (the degraded-detection banner path)

    @Test("Altered quality assets surface through detector diagnostics; healthy bundle stays silent")
    func alteredAssetsSurfaceThroughDetectorDiagnostics() throws {
        // Healthy precondition: a faithful copy of the engine resources loads
        // with an empty failure list (NER forced available so the probe result
        // does not depend on the host's asset catalog).
        let healthy = try Self.makeScratchEngineBundle()
        let (_, healthyDiagnostics) = PIIDetector.$_nerAvailabilityOverride.withValue(true) {
            PIIDetector.loadWithDiagnostics(bundle: healthy.bundle)
        }
        #expect(healthyDiagnostics.failedGazetteers.isEmpty,
                "faithful copy must load clean: \(healthyDiagnostics.failedGazetteers)")

        // Altered copy: one byte of context-scorer flipped (defeats the pinned
        // hash), a non-positive temperature, corrupt preset bytes.
        let altered = try Self.makeScratchEngineBundle()
        let classifierDir = altered.root.appending(path: "Classifier", directoryHint: .isDirectory)
        let scorerURL = classifierDir.appending(path: "context-scorer.json")
        var scorerBytes = try Data(contentsOf: scorerURL)
        scorerBytes[64] ^= 0xFF
        try scorerBytes.write(to: scorerURL)
        try Data(#"{"version": 1, "temperature": -1.0}"#.utf8)
            .write(to: classifierDir.appending(path: "doctype-temperature.json"))
        try Data("not a preset table".utf8)
            .write(to: classifierDir.appending(path: "preset-thresholds.json"))

        let (_, diagnostics) = PIIDetector.$_nerAvailabilityOverride.withValue(true) {
            PIIDetector.loadWithDiagnostics(bundle: altered.bundle)
        }
        #expect(diagnostics.didDegrade)
        #expect(diagnostics.failedGazetteers == [
            "ContextScorerWeights", "DoctypeTemperature", "PresetThresholds",
        ], "exactly the three altered assets must report — nothing else")
        for name in diagnostics.failedGazetteers {
            #expect(diagnostics.failureReasons[name]?.isEmpty == false,
                    "reason for \(name) must not be empty")
        }
    }

    @Test("Signature-fail path does NOT attribute the quality-asset trackers (exclusion set)")
    func signatureFailPathDoesNotAttributeAssetTrackers() {
        // The empty bundle short-circuits at the manifest-signature check;
        // the three quality assets are not signature-covered, so they must
        // never be attributed there (mirrors the classifier / NER exclusions).
        let (_, diagnostics) = PIIDetector.loadWithDiagnostics(bundle: Bundle())
        #expect(diagnostics.didDegrade)
        #expect(!diagnostics.failedGazetteers.contains("ContextScorerWeights"))
        #expect(!diagnostics.failedGazetteers.contains("DoctypeTemperature"))
        #expect(!diagnostics.failedGazetteers.contains("PresetThresholds"))
    }

    @Test("Appending the quality-asset trackers flips didDegrade (banner wiring)")
    func appendingAssetTrackersDrivesDegrade() {
        // Environment-independent proof that the degraded-detection banner path
        // fires for the new trackers — same wiring pin the NER tracker carries.
        for tracker: GazetteerLoadDiagnostics.Gazetteer in [
            .contextScorerWeights, .doctypeTemperature, .presetThresholds,
        ] {
            let diag = GazetteerLoadDiagnostics()
                .appending(tracker, reason: "asset load reported")
            #expect(diag.didDegrade)
            #expect(diag.failedGazetteers == [tracker.rawValue])
            #expect(diag.failureReasons[tracker.rawValue] == "asset load reported")
        }
    }
}
