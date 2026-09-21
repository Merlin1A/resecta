import CryptoKit
import Foundation
import Testing
@testable import RedactionEngine

// Signed gazetteer manifest verification tests.
//
// Signing scheme: Ed25519, rotation per major release,
//   degrade-with-banner on failure.
//
// Wire-format contract:
//   - DataPipeline `manifest_signing.py` signs the canonical-form JSON
//     bytes of `gazetteer_manifest.json` with an Ed25519 private key.
//   - The detached signature is PEM-wrapped:
//       -----BEGIN ED25519 SIGNATURE-----
//       <base64 of the 64 raw signature bytes>
//       -----END ED25519 SIGNATURE-----
//   - The public key is exported in the standard SubjectPublicKeyInfo PEM
//     envelope:
//       -----BEGIN PUBLIC KEY-----
//       <base64 of DER>
//       -----END PUBLIC KEY-----
//
// Tests use CryptoKit's own keypair generation to construct fixtures so
// the suite stays self-contained (no fixture file shipped, no dependency
// on a `make sign-manifest` having run).

@Suite("SignedManifest")
struct SignedManifestTests {

    // Cross-test invariant (BackupExclusionTests): no test must create
    // entries at the bare `FileManager.default.temporaryDirectory` root
    // during a parallel `testNoWriteAtTempRootDuringSession` run, since that
    // test snapshots the root before / after and flags unexpected new
    // entries. We nest every fixture under a single shared sandbox
    // (`SECURITY_NEUTRAL_SANDBOX`) and use a one-time `Once`-style
    // initializer so the parent appears in the "before" snapshot whether
    // SignedManifestTests runs first or BackupExclusionTests runs first.
    static let sandboxRoot: URL = {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "RedactionEngineTests-SignedManifestTests-Sandbox", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }()

    // MARK: - Fixture helpers

    /// Build a temp bundle containing the manifest, the detached signature,
    /// and the public key — all under a `Gazetteers/` subdirectory, matching
    /// the production resource layout.
    static func makeFixtureBundle(
        manifestBytes: Data,
        signaturePEM: Data,
        publicKeyPEM: Data,
    ) throws -> (bundle: Bundle, root: URL) {
        let root = Self.sandboxRoot
            .appending(path: "sec6-fixture-\(UUID().uuidString)", directoryHint: .isDirectory)
        let gazetteers = root.appending(path: "Gazetteers", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: gazetteers, withIntermediateDirectories: true)

        try manifestBytes.write(to: gazetteers.appending(path: "gazetteer-manifest.json"))
        try signaturePEM.write(to: gazetteers.appending(path: "gazetteer_manifest.sig"))
        try publicKeyPEM.write(to: gazetteers.appending(path: "manifest_public_key.pem"))

        guard let bundle = Bundle(path: root.path()) else {
            throw FixtureError.bundleConstructionFailed
        }
        return (bundle, root)
    }

    /// Sample manifest payload — canonical-form JSON shape that matches
    /// the production manifest produced by the bloom builder.
    static let sampleManifestBytes: Data = Data("""
        {
          "assets": [],
          "filters": [],
          "hashAlgorithm": "MurmurHash3_x64_128",
          "seed": 20260416,
          "version": "1.1.0"
        }

        """.utf8)

    /// A signed fixture whose manifest lists `listed` under `assets[]` and
    /// whose tree holds `files` (bundle-relative path → bytes). Entries are
    /// computed from `files` unless overridden in `listed`, so a test states
    /// only the discrepancy it is about.
    static func makeSignedAssetFixture(
        files: [String: Data],
        listed: [String: (sha256: String, bytes: Int)]? = nil,
        version: String = "1.1.0",
        includeAssetsSection: Bool = true
    ) throws -> (bundle: Bundle, root: URL) {
        let root = Self.sandboxRoot
            .appending(path: "assets-fixture-\(UUID().uuidString)", directoryHint: .isDirectory)
        for (path, bytes) in files {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: url)
        }
        var entries: [[String: Any]] = []
        let table = listed ?? files.mapValues { bytes in
            (sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(), bytes: bytes.count)
        }
        for path in table.keys.sorted() {
            let entry = table[path]!
            entries.append(["path": path, "sha256": entry.sha256, "bytes": entry.bytes])
        }
        var manifest: [String: Any] = [
            "filters": [], "hashAlgorithm": "MurmurHash3_x64_128", "seed": 20260416, "version": version,
        ]
        if includeAssetsSection { manifest["assets"] = entries }
        let manifestBytes = try JSONSerialization.data(
            withJSONObject: manifest, options: [.sortedKeys, .prettyPrinted])
        let privateKey = Curve25519.Signing.PrivateKey()
        let signature = try privateKey.signature(for: manifestBytes)
        let gazetteers = root.appending(path: "Gazetteers", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: gazetteers, withIntermediateDirectories: true)
        try manifestBytes.write(to: gazetteers.appending(path: "gazetteer-manifest.json"))
        try Self.encodeSignaturePEM(signature).write(to: gazetteers.appending(path: "gazetteer_manifest.sig"))
        try Self.encodePublicKeyPEM(privateKey.publicKey)
            .write(to: gazetteers.appending(path: "manifest_public_key.pem"))
        guard let bundle = Bundle(path: root.path()) else { throw FixtureError.bundleConstructionFailed }
        return (bundle, root)
    }

    /// Encode an Ed25519 public key in the same SubjectPublicKeyInfo PEM
    /// envelope that the Python `cryptography` library produces. The DER
    /// prefix is fixed for Ed25519; we wrap the 32-byte raw key with it.
    static func encodePublicKeyPEM(_ key: Curve25519.Signing.PublicKey) -> Data {
        let der: [UInt8] = [
            0x30, 0x2A, 0x30, 0x05, 0x06, 0x03, 0x2B, 0x65, 0x70, 0x03, 0x21, 0x00,
        ] + Array(key.rawRepresentation)
        let base64 = Data(der).base64EncodedString()
        // 64-char-wrapped body, matching the PEM convention.
        var wrapped = ""
        for chunk in stride(from: 0, to: base64.count, by: 64) {
            let start = base64.index(base64.startIndex, offsetBy: chunk)
            let end = base64.index(start, offsetBy: min(64, base64.count - chunk))
            wrapped += base64[start..<end]
            wrapped += "\n"
        }
        return Data("""
            -----BEGIN PUBLIC KEY-----
            \(wrapped)-----END PUBLIC KEY-----

            """.utf8)
    }

    /// Wrap a raw 64-byte Ed25519 signature in the same PEM envelope that
    /// the DataPipeline `manifest_signing.py` writes.
    static func encodeSignaturePEM(_ signature: Data) -> Data {
        let base64 = signature.base64EncodedString()
        var wrapped = ""
        for chunk in stride(from: 0, to: base64.count, by: 64) {
            let start = base64.index(base64.startIndex, offsetBy: chunk)
            let end = base64.index(start, offsetBy: min(64, base64.count - chunk))
            wrapped += base64[start..<end]
            wrapped += "\n"
        }
        return Data("""
            -----BEGIN ED25519 SIGNATURE-----
            \(wrapped)-----END ED25519 SIGNATURE-----

            """.utf8)
    }

    enum FixtureError: Error {
        case bundleConstructionFailed
    }

    // MARK: - Tests

    @Test("Valid signature: load succeeds")
    func testValidSignatureLoadsGazetteers() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let manifest = Self.sampleManifestBytes
        let signature = try privateKey.signature(for: manifest)
        let signaturePEM = Self.encodeSignaturePEM(signature)
        let publicKeyPEM = Self.encodePublicKeyPEM(privateKey.publicKey)

        let (bundle, root) = try Self.makeFixtureBundle(
            manifestBytes: manifest,
            signaturePEM: signaturePEM,
            publicKeyPEM: publicKeyPEM
        )
        defer { try? FileManager.default.removeItem(at: root) }

        // Bool wrapper — returns true on success.
        #expect(GazetteerLoader.isManifestSignatureValid(bundle: bundle))

        // Throwing wrapper — does not throw.
        #expect(throws: Never.self) {
            try GazetteerLoader.verifySignedManifest(bundle: bundle)
        }
    }

    @Test("Tampered manifest throws detectionCorpusInvalid")
    func testTamperedManifestThrowsDetectionCorpusInvalid() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let originalManifest = Self.sampleManifestBytes

        // Sign the ORIGINAL manifest, then write a tampered copy into the
        // fixture so verification reads modified bytes against a signature
        // produced over the un-modified ones.
        let signature = try privateKey.signature(for: originalManifest)
        let signaturePEM = Self.encodeSignaturePEM(signature)
        let publicKeyPEM = Self.encodePublicKeyPEM(privateKey.publicKey)

        var tampered = originalManifest
        // Flip one byte in the body (avoid the trailing LF so the JSON
        // structure stays parseable — the verifier should care about the
        // signature, not the JSON validity).
        let tamperIndex = tampered.count - 5
        tampered[tamperIndex] ^= 0x01
        #expect(tampered != originalManifest, "tamper must change the bytes")

        let (bundle, root) = try Self.makeFixtureBundle(
            manifestBytes: tampered,
            signaturePEM: signaturePEM,
            publicKeyPEM: publicKeyPEM
        )
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(!GazetteerLoader.isManifestSignatureValid(bundle: bundle))

        do {
            try GazetteerLoader.verifySignedManifest(bundle: bundle)
            Issue.record("verifySignedManifest must throw on tampered manifest")
        } catch let error as PipelineError { // LegalPhrases:safe — Swift catch clause, not English
            guard case .detectionError(.detectionCorpusInvalid) = error else {
                Issue.record("expected .detectionError(.detectionCorpusInvalid), got \(error)")
                return
            }
        } catch { // LegalPhrases:safe — Swift catch clause, not English
            Issue.record("expected PipelineError, got \(type(of: error)): \(error)")
        }
    }

    @Test("Missing signature file throws detectionCorpusInvalid")
    func testMissingSignatureFileThrows() throws {
        // Build a fixture with manifest + public key but no signature.
        let root = Self.sandboxRoot
            .appending(path: "sec6-no-sig-\(UUID().uuidString)", directoryHint: .isDirectory)
        let gazetteers = root.appending(path: "Gazetteers", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: gazetteers, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let privateKey = Curve25519.Signing.PrivateKey()
        try Self.sampleManifestBytes.write(to: gazetteers.appending(path: "gazetteer-manifest.json"))
        try Self.encodePublicKeyPEM(privateKey.publicKey)
            .write(to: gazetteers.appending(path: "manifest_public_key.pem"))
        // Intentionally do NOT write gazetteer_manifest.sig.

        guard let bundle = Bundle(path: root.path()) else {
            Issue.record("Failed to construct test bundle")
            return
        }

        #expect(!GazetteerLoader.isManifestSignatureValid(bundle: bundle))

        do {
            try GazetteerLoader.verifySignedManifest(bundle: bundle)
            Issue.record("verifySignedManifest must throw when signature is absent")
        } catch let error as PipelineError { // LegalPhrases:safe — Swift catch clause, not English
            #expect(
                {
                    if case .detectionError(.detectionCorpusInvalid) = error {
                        return true
                    } else {
                        return false
                    }
                }(),
                "expected .detectionError(.detectionCorpusInvalid), got \(error)"
            )
        } catch { // LegalPhrases:safe — Swift catch clause, not English
            Issue.record("expected PipelineError, got \(type(of: error)): \(error)")
        }
    }

    // MARK: - The assets[] section (per-asset digests behind the signature)

    @Test("Listed assets that match: the corpus is trusted and the report counts them")
    func matchingAssetsAreTrusted() throws {
        let (bundle, root) = try Self.makeSignedAssetFixture(files: [
            "Gazetteers/dl_patterns.json": Data("gated".utf8),
            "Classifier/preset-thresholds.json": Data("ungated".utf8),
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let verdict = GazetteerTrust.corpusVerdict(bundle: bundle)
        #expect(verdict.isTrusted)
        #expect(verdict.report == AssetIntegrity.Report(gated: [], ungated: [], verifiedCount: 2))
    }

    @Test("A trust-gated asset whose bytes differ from its signed digest withholds the corpus")
    func gatedDigestMismatchWithholds() throws {
        let (bundle, root) = try Self.makeSignedAssetFixture(
            files: ["Gazetteers/dl_patterns.json": Data("shipped".utf8)],
            listed: ["Gazetteers/dl_patterns.json": (sha256: String(repeating: "0", count: 64), bytes: 7)])
        defer { try? FileManager.default.removeItem(at: root) }
        let verdict = GazetteerTrust.corpusVerdict(bundle: bundle)
        #expect(!verdict.isTrusted)
        #expect(verdict.report?.gated == [.digestMismatch(path: "Gazetteers/dl_patterns.json")])
        #expect(verdict.failureReason?.contains("SHA-256 differs") == true)
    }

    @Test("A trust-gated asset whose size differs is refused before it is hashed")
    func gatedSizeMismatchWithholds() throws {
        let (bundle, root) = try Self.makeSignedAssetFixture(
            files: ["Gazetteers/surnames.bloom": Data("bloom".utf8)],
            listed: ["Gazetteers/surnames.bloom": (sha256: String(repeating: "0", count: 64), bytes: 99)])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(GazetteerTrust.corpusVerdict(bundle: bundle).report?.gated
                == [.sizeMismatch(path: "Gazetteers/surnames.bloom", expected: 99, actual: 5)])
    }

    @Test("A listed trust-gated asset that is not bundled withholds the corpus")
    func gatedMissingWithholds() throws {
        let (bundle, root) = try Self.makeSignedAssetFixture(
            files: [:],
            listed: ["Gazetteers/context-keywords.json": (sha256: String(repeating: "a", count: 64), bytes: 1)])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(GazetteerTrust.corpusVerdict(bundle: bundle).report?.gated
                == [.missing(path: "Gazetteers/context-keywords.json")])
    }

    @Test("A trust-gated file present in the bundle but absent from assets[] withholds the corpus")
    func gatedUnlistedWithholds() throws {
        let (bundle, root) = try Self.makeSignedAssetFixture(
            files: ["Gazetteers/negative-context.json": Data("swapped in".utf8)], listed: [:])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(GazetteerTrust.corpusVerdict(bundle: bundle).report?.gated
                == [.unlisted(path: "Gazetteers/negative-context.json")])
    }

    @Test("An ungated asset whose bytes differ is reported, not withheld")
    func ungatedDigestMismatchIsReportedOnly() throws {
        let (bundle, root) = try Self.makeSignedAssetFixture(
            files: [
                "Gazetteers/dl_patterns.json": Data("gated".utf8),
                "Audit/rule-catalog.json": Data("catalog".utf8),
            ],
            listed: [
                "Gazetteers/dl_patterns.json": (
                    sha256: SHA256.hash(data: Data("gated".utf8)).map { String(format: "%02x", $0) }.joined(),
                    bytes: 5),
                "Audit/rule-catalog.json": (sha256: String(repeating: "f", count: 64), bytes: 7),
            ])
        defer { try? FileManager.default.removeItem(at: root) }
        let verdict = GazetteerTrust.corpusVerdict(bundle: bundle)
        #expect(verdict.isTrusted)
        #expect(verdict.report?.ungated == [.digestMismatch(path: "Audit/rule-catalog.json")])
        #expect(AssetIntegrity.diagnosticsCase(forPath: "Audit/rule-catalog.json") == .assetIntegrity)
        #expect(AssetIntegrity.diagnosticsCase(forPath: "Classifier/preset-thresholds.json") == .presetThresholds)
    }

    @Test("A signed manifest at the previous version is refused by the fence, not decoded around")
    func previousVersionIsRefused() throws {
        let (bundle, root) = try Self.makeSignedAssetFixture(
            files: [:], version: "1.0.0", includeAssetsSection: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let verdict = GazetteerTrust.corpusVerdict(bundle: bundle)
        #expect(!verdict.isTrusted)
        #expect(verdict.report?.gated
                == [.unsupportedManifestVersion(actual: "1.0.0", supported: GazetteerManifest.supportedVersions)])
    }

    @Test("A signed manifest at the current version without assets[] is refused")
    func missingAssetSectionIsRefused() throws {
        let (bundle, root) = try Self.makeSignedAssetFixture(files: [:], includeAssetsSection: false)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(GazetteerTrust.corpusVerdict(bundle: bundle).report?.gated
                == [.noAssetSection(version: "1.1.0")])
    }

    @Test("An invalid signature stops before the digests are read")
    func invalidSignatureSkipsDigests() throws {
        let (bundle, root) = try Self.makeSignedAssetFixture(
            files: ["Gazetteers/dl_patterns.json": Data("gated".utf8)])
        defer { try? FileManager.default.removeItem(at: root) }
        // Re-sign nothing: append a byte to the manifest so the signature fails.
        let manifestURL = root.appending(path: "Gazetteers/gazetteer-manifest.json")
        var bytes = try Data(contentsOf: manifestURL)
        bytes.append(Data(" ".utf8))
        try bytes.write(to: manifestURL)
        let verdict = GazetteerTrust.corpusVerdict(bundle: bundle)
        #expect(verdict == .signatureInvalid)
        #expect(verdict.report == nil)
    }

    @Test("Degrade banner surfaces on failure: loadWithDiagnostics flags all gazetteers + sets didDegrade")
    func testDegradeBannerSurfacesOnFailure() throws {
        // When signature verification fails inside
        // `PIIDetector.loadWithDiagnostics`, every gazetteer entry in the
        // `GazetteerLoadDiagnostics` value must report as failed so the
        // app-side `PipelineCoordinator.surfaceGazetteerLoadDiagnostics`
        // sees `didDegrade == true` and flips
        // `RedactionState.autoDetectionDegraded` (the persistent banner +
        // first-time warning toast).
        //
        // Easiest signal: empty bundle — signature files are missing, so
        // verification throws and `loadWithDiagnostics` short-circuits.
        let (detector, diagnostics) = PIIDetector.loadWithDiagnostics(bundle: Bundle())

        #expect(diagnostics.didDegrade)
        // The signature-fail short-circuit appends every SIGNATURE-COVERED loader.
        // Trackers NOT covered by the gazetteer-manifest signature —
        // documentTypeClassifier, nerNameModel, the three Classifier/
        // quality-asset trackers, and the three JSON reference tables
        // (institution / address-components / ZIP-state, whose ungated
        // static loads a signature failure never reaches) — are deliberately
        // excluded from that loop, so they never appear on the
        // signature-failure list. Membership is the enum's own
        // `outsideManifestSignature` set, so this pin and the production loop
        // cannot drift apart.
        let signatureCovered = GazetteerLoadDiagnostics.Gazetteer.allCases.filter {
            !GazetteerLoadDiagnostics.outsideManifestSignature.contains($0)
        }
        #expect(diagnostics.failedGazetteers.count == signatureCovered.count)
        for gazetteer in signatureCovered {
            #expect(diagnostics.failedGazetteers.contains(gazetteer.rawValue),
                    "expected \(gazetteer.rawValue) to appear in failedGazetteers")
            let reason = diagnostics.failureReasons[gazetteer.rawValue]
            #expect(reason != nil)
            #expect(
                reason?.contains("signature verification failed") == true,
                "expected signature-verification reason, got \(String(describing: reason))"
            )
        }
        // Non-signature-covered trackers must NOT be attributed to a
        // signature failure — the classifier and NER trackers, and the three
        // reference tables whose ungated static loads keep serving.
        #expect(!diagnostics.failedGazetteers.contains(
            GazetteerLoadDiagnostics.Gazetteer.documentTypeClassifier.rawValue))
        #expect(!diagnostics.failedGazetteers.contains(
            GazetteerLoadDiagnostics.Gazetteer.nerNameModel.rawValue))
        #expect(!diagnostics.failedGazetteers.contains(
            GazetteerLoadDiagnostics.Gazetteer.institutionGazetteer.rawValue))
        #expect(!diagnostics.failedGazetteers.contains(
            GazetteerLoadDiagnostics.Gazetteer.addressComponentsGazetteer.rawValue))
        #expect(!diagnostics.failedGazetteers.contains(
            GazetteerLoadDiagnostics.Gazetteer.zipStateTableLoader.rawValue))

        // Manual redaction tools remain available: regex-only detectors
        // still run against the constructed detector. Detector is
        // non-nil; gazetteer-backed paths short-circuit on nil and the
        // SSN state machine / DEA letter check / email regex run as
        // usual (covered in detail by `PIIDetectorInitDegradedTests`).
        _ = detector
    }

    // This is the regression that a stale .gitignore entry hid. Unlike the
    // cases above (which write a freshly re-signed pair into a temp bundle
    // and so always pass), this asserts over the bytes as BUNDLED from the
    // committed tree (Package.swift `.copy("Resources/Gazetteers")`). A
    // missing / re-ignored / stale committed pair fails here instead of
    // degrading silently to the degraded-detection banner on device.
    @Test("Committed gazetteer signature pair verifies the shipped manifest")
    func committedSignaturePairVerifiesShippedManifest() throws {
        #expect(GazetteerLoader.isManifestSignatureValid(bundle: .module))
    }
}
