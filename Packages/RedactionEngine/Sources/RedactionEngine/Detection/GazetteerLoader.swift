import CryptoKit
import Foundation
import OSLog

// SEC-6 — Signed gazetteer manifest verification.
//
// Verifies that the bundled `gazetteer_manifest.json` is a byte-for-byte
// match for what the DataPipeline signed at build time. The signature
// is detached (`gazetteer_manifest.sig`); the public key is bundled
// alongside (`manifest_public_key.pem`) — both produced by the paired
// DataPipeline `make sign-manifest` step (Ed25519, deterministic).
//
// Failure modes (all collapse to `PipelineError.detectionError(.detectionCorpusInvalid)`):
//   - Missing manifest, signature, or public-key resource.
//   - Public key PEM is not a valid Curve25519 (Ed25519) key.
//   - Signature PEM is malformed or not 64 raw bytes.
//   - Signature does not verify against the bundled public key and
//     manifest bytes.
//
// Signing scheme: Ed25519, rotation per major release,
//   degrade-with-banner on failure via the load-diagnostics surface.
//
// Cryptography:
//   - Algorithm: Curve25519.Signing (Ed25519). First CryptoKit use in the
//     iOS app (pre-approved I7 — escalation.md §1.1).
//   - Privacy manifest: CryptoKit signature verification is a compute-only
//     primitive; it is not on Apple's NSPrivacyAccessedAPITypes required-
//     reason list. No new privacy-manifest entry required.

public enum GazetteerLoader {

    /// Errors returned when the on-disk crypto material is malformed. Internal
    /// because all callers convert into `PipelineError.detectionError(.detectionCorpusInvalid)`
    /// — the surface the SEC-7 banner / toast machinery already consumes.
    enum VerificationError: Error {
        case resourceMissing(name: String)
        case publicKeyMalformed
        case signatureMalformed
        case signatureMismatch
    }

    /// Verify the bundled gazetteer manifest's Ed25519 signature against
    /// the engine module bundle (`Bundle.module`).
    ///
    /// On success: returns normally. On any failure (missing resource,
    /// malformed key, malformed signature, or invalid signature) throws
    /// `PipelineError.detectionError(.detectionCorpusInvalid)`. The throw
    /// type is the PipelineError surface the rest of the pipeline already
    /// routes through; the underlying `VerificationError` is captured in
    /// the OS log for offline diagnosis (mechanism-only — no document
    /// content, no key bytes — per ARCH §12.2).
    public static func verifySignedManifest() throws {
        try verifySignedManifest(bundle: .module)
    }

    /// Testing / composition overload. Internal so a temp bundle with
    /// hand-built fixtures can be injected from `SignedManifestTests` without
    /// exposing a `Bundle.module` default-argument surface on the public
    /// API (default argument values cannot reference an internal
    /// `Bundle.module` property from a public function).
    static func verifySignedManifest(bundle: Bundle) throws {
        do {
            try performVerification(bundle: bundle)
        } catch let error as VerificationError { // LegalPhrases:safe — Swift catch clause, not English
            // Log the mechanism (which resource failed, which check failed)
            // at warning level so a release operator can diagnose without
            // shipping the manifest contents or the signature bytes.
            logger.warning(
                "gazetteer-manifest signature verification failed: \(String(describing: error), privacy: .public)"
            )
            throw PipelineError.detectionError(.detectionCorpusInvalid)
        }
    }

    /// Boolean wrapper around `verifySignedManifest`. Returns `true` iff
    /// verification succeeds. Used inside `PIIDetector.loadWithDiagnostics`
    /// to short-circuit gazetteer loading when the manifest is unsigned or
    /// tampered — the diagnostic surfaces via the existing SEC-7 banner /
    /// toast path rather than throwing all the way out of the loader.
    static func isManifestSignatureValid(bundle: Bundle) -> Bool {
        do {
            try performVerification(bundle: bundle)
            return true
        } catch { // LegalPhrases:safe — Swift catch clause, not English
            logger.warning(
                "gazetteer-manifest signature verification failed: \(String(describing: error), privacy: .public)"
            )
            return false
        }
    }

    // MARK: - Internals

    /// Read manifest, signature, and public-key resources from `bundle` and
    /// verify the Ed25519 signature against the manifest bytes.
    private static func performVerification(bundle: Bundle) throws {
        let manifestURL = try resourceURL(
            in: bundle,
            forResource: "gazetteer-manifest",
            withExtension: "json",
            subdirectory: "Gazetteers"
        )
        let signatureURL = try resourceURL(
            in: bundle,
            forResource: "gazetteer_manifest",
            withExtension: "sig",
            subdirectory: "Gazetteers"
        )
        let publicKeyURL = try resourceURL(
            in: bundle,
            forResource: "manifest_public_key",
            withExtension: "pem",
            subdirectory: "Gazetteers"
        )

        let manifestBytes: Data
        let signaturePEM: Data
        let publicKeyPEM: Data
        do {
            manifestBytes = try Data(contentsOf: manifestURL)
            signaturePEM = try Data(contentsOf: signatureURL)
            publicKeyPEM = try Data(contentsOf: publicKeyURL)
        } catch { // LegalPhrases:safe — Swift catch clause, not English
            // A resource was unreadable after being located — treat as a
            // missing-resource failure for the verification surface.
            throw VerificationError.resourceMissing(name: "manifest/signature/public-key")
        }

        let publicKey = try parsePublicKey(publicKeyPEM)
        let rawSignature = try parseSignaturePEM(signaturePEM)

        guard publicKey.isValidSignature(rawSignature, for: manifestBytes) else {
            throw VerificationError.signatureMismatch
        }
    }

    /// Resolve a resource URL or throw a mechanism-described missing-resource
    /// error. Centralised so each missing file produces a self-describing
    /// log line.
    private static func resourceURL(
        in bundle: Bundle,
        forResource name: String,
        withExtension ext: String,
        subdirectory: String
    ) throws -> URL {
        guard let url = bundle.url(
            forResource: name,
            withExtension: ext,
            subdirectory: subdirectory
        ) else {
            throw VerificationError.resourceMissing(name: "\(subdirectory)/\(name).\(ext)")
        }
        return url
    }

    /// Strip the PEM envelope from a SubjectPublicKeyInfo-wrapped Ed25519
    /// public key and return the underlying `Curve25519.Signing.PublicKey`.
    ///
    /// The Python side (`cryptography.hazmat.primitives.serialization`) emits
    /// the public key as DER inside the standard PEM `BEGIN PUBLIC KEY` /
    /// `END PUBLIC KEY` envelope. The DER prefix for Ed25519 SPKI is the
    /// fixed 12-byte sequence:
    ///     30 2A 30 05 06 03 2B 65 70 03 21 00
    /// followed by the 32-byte raw public key. We pin that prefix here so
    /// a swap to a different algorithm (RSA, P-256) trips the malformed-key
    /// path rather than silently mis-parsing.
    private static func parsePublicKey(_ pem: Data) throws -> Curve25519.Signing.PublicKey {
        guard let derBytes = pemBody(
            pem,
            header: "-----BEGIN PUBLIC KEY-----",
            footer: "-----END PUBLIC KEY-----"
        ) else {
            throw VerificationError.publicKeyMalformed
        }

        // Ed25519 SubjectPublicKeyInfo prefix:
        //   SEQUENCE (42 bytes)
        //     SEQUENCE
        //       OID 1.3.101.112 (id-Ed25519)
        //     BIT STRING (33 bytes) — leading 0x00, then 32-byte key
        let ed25519SPKIPrefix: [UInt8] = [
            0x30, 0x2A, 0x30, 0x05, 0x06, 0x03, 0x2B, 0x65, 0x70, 0x03, 0x21, 0x00,
        ]
        let ed25519RawKeyLength = 32
        let expectedTotalLength = ed25519SPKIPrefix.count + ed25519RawKeyLength

        guard derBytes.count == expectedTotalLength else {
            throw VerificationError.publicKeyMalformed
        }
        guard derBytes.prefix(ed25519SPKIPrefix.count).elementsEqual(ed25519SPKIPrefix) else {
            throw VerificationError.publicKeyMalformed
        }

        let rawKey = derBytes.suffix(ed25519RawKeyLength)
        do {
            return try Curve25519.Signing.PublicKey(rawRepresentation: rawKey)
        } catch { // LegalPhrases:safe — Swift catch clause, not English
            throw VerificationError.publicKeyMalformed
        }
    }

    /// Strip the PEM envelope from the detached signature file and return
    /// the raw 64-byte Ed25519 signature.
    ///
    /// The Python side wraps base64 in
    /// `-----BEGIN ED25519 SIGNATURE-----` / `-----END ED25519 SIGNATURE-----`
    /// markers (see `manifest_signing.py:SIGNATURE_PEM_HEADER`). Anything
    /// else is malformed.
    private static func parseSignaturePEM(_ pem: Data) throws -> Data {
        guard let body = pemBody(
            pem,
            header: "-----BEGIN ED25519 SIGNATURE-----",
            footer: "-----END ED25519 SIGNATURE-----"
        ) else {
            throw VerificationError.signatureMalformed
        }
        let ed25519SignatureLength = 64
        guard body.count == ed25519SignatureLength else {
            throw VerificationError.signatureMalformed
        }
        return body
    }

    /// Extract the base64-decoded body between `header` and `footer` from a
    /// PEM document. Returns nil if either marker is missing or the body is
    /// not valid base64.
    private static func pemBody(_ pem: Data, header: String, footer: String) -> Data? {
        guard let text = String(data: pem, encoding: .utf8) else { return nil }
        guard let headerRange = text.range(of: header),
              let footerRange = text.range(of: footer),
              headerRange.upperBound <= footerRange.lowerBound
        else {
            return nil
        }
        let body = text[headerRange.upperBound..<footerRange.lowerBound]
        let stripped = body.filter { !$0.isWhitespace }
        return Data(base64Encoded: stripped)
    }

    private static let logger = Logger(
        subsystem: "app.resecta.engine",
        category: "GazetteerLoader"
    )
}
