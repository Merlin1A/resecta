import CryptoKit
import Foundation
import Testing
@testable import RedactionEngine

// SEC-6 — Signed gazetteer manifest verification tests.
//
// SEC-6 signing scheme: Ed25519, rotation per major release,
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

@Suite("SignedManifest (SEC-6)")
struct SignedManifestTests {

    // SEC-2 cross-test invariant (BackupExclusionTests): no test must create
    // entries at the bare `FileManager.default.temporaryDirectory` root
    // during a parallel `testNoWriteAtTempRootDuringSession` run, since that
    // test snapshots the root before / after and flags unexpected new
    // entries. We nest every fixture under a single shared sandbox
    // (`SECURITY_NEUTRAL_SANDBOX`) and use a one-time `Once`-style
    // initializer so the parent appears in the "before" snapshot whether
    // SignedManifestTests runs first or BackupExclusionTests runs first.
    private static let sandboxRoot: URL = {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "RedactionEngineTests-SignedManifestTests-Sandbox", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }()

    // MARK: - Fixture helpers

    /// Build a temp bundle containing the manifest, the detached signature,
    /// and the public key — all under a `Gazetteers/` subdirectory, matching
    /// the production resource layout.
    private static func makeFixtureBundle(
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
    private static let sampleManifestBytes: Data = Data("""
        {
          "filters": [],
          "hashAlgorithm": "MurmurHash3_x64_128",
          "seed": 20260416,
          "version": "1.0.0"
        }

        """.utf8)

    /// Encode an Ed25519 public key in the same SubjectPublicKeyInfo PEM
    /// envelope that the Python `cryptography` library produces. The DER
    /// prefix is fixed for Ed25519; we wrap the 32-byte raw key with it.
    private static func encodePublicKeyPEM(_ key: Curve25519.Signing.PublicKey) -> Data {
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
    private static func encodeSignaturePEM(_ signature: Data) -> Data {
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

    private enum FixtureError: Error {
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

    @Test("Degrade banner surfaces on failure: loadWithDiagnostics flags all gazetteers + sets didDegrade")
    func testDegradeBannerSurfacesOnFailure() throws {
        // Integration with SEC-7: when signature verification fails inside
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
        // The two OS/JSON-provisioned trackers — documentTypeClassifier (CAT-065,
        // s17) and nerNameModel (GAP-DEPTARGET-NER, this session) — are NOT covered
        // by the gazetteer-manifest signature and are deliberately excluded from
        // that loop, so they never appear on the signature-failure list. (Updating
        // this from a bare `allCases.count` also corrects a count that has been off
        // by one since documentTypeClassifier joined the enum in s17.)
        let signatureCovered = GazetteerLoadDiagnostics.Gazetteer.allCases.filter {
            $0 != .documentTypeClassifier && $0 != .nerNameModel
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
        // The two non-signature-covered trackers must NOT be attributed to a
        // signature failure.
        #expect(!diagnostics.failedGazetteers.contains(
            GazetteerLoadDiagnostics.Gazetteer.documentTypeClassifier.rawValue))
        #expect(!diagnostics.failedGazetteers.contains(
            GazetteerLoadDiagnostics.Gazetteer.nerNameModel.rawValue))

        // Manual redaction tools remain available: regex-only detectors
        // still run against the constructed detector. Detector is
        // non-nil; gazetteer-backed paths short-circuit on nil and the
        // SSN state machine / DEA letter check / email regex run as
        // usual (covered in detail by `PIIDetectorInitDegradedTests`).
        _ = detector
    }

    // REL-1 / D11-config-golive-F2 — the regression that the SEC-6 .gitignore
    // footgun hid. Unlike the cases above (which write a freshly re-signed pair
    // into a temp bundle and so always pass), this asserts over the bytes as
    // BUNDLED from the committed tree (Package.swift `.copy("Resources/Gazetteers")`).
    // A missing / re-ignored / stale committed pair fails here instead of
    // degrading silently to the SEC-7 banner on device.
    @Test("Committed gazetteer signature pair verifies the shipped manifest (REL-1 / SEC-6)")
    func committedSignaturePairVerifiesShippedManifest() throws {
        #expect(GazetteerLoader.isManifestSignatureValid(bundle: .module))
    }
}
