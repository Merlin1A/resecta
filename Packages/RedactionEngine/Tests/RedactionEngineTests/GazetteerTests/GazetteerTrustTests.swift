import Testing
import Foundation
import CryptoKit
@testable import RedactionEngine

// The memoized corpus verdict (`GazetteerTrust`: the manifest signature plus
// the signed digests of the trust-gated assets): the shipped bundle is
// verified at most once per process, every other bundle is evaluated live. Reuses `SignedManifestTests`' fixture builders rather
// than adding another temp-bundle helper.
@Suite("GazetteerTrust — memoized corpus verdict")
struct GazetteerTrustTests {

    @Test("Shipped-bundle verdict is computed at most once per process")
    func moduleVerdictMemoized() {
        // `.module` in THIS file names the test target's own resource bundle,
        // so the shipped-bundle path must go through the public wrapper,
        // which resolves the engine's bundle inside the engine module.
        let first = GazetteerTrust.isShippedCorpusTrusted()
        let countAfterFirst = GazetteerTrust.moduleVerificationCountForTesting
        let second = GazetteerTrust.isShippedCorpusTrusted()
        #expect(first == second)
        #expect(GazetteerTrust.moduleVerificationCountForTesting == countAfterFirst,
                "a second lookup must not re-verify the shipped bundle")
        #expect(countAfterFirst == 1,
                "the underlying verification runs exactly once per process")
        #expect(first, "the committed signature pair must verify the shipped manifest and every gated digest must match")
    }

    @Test("Fixture bundles are evaluated live — tampering between calls is observed")
    func fixtureBundlesNotCached() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let manifest = SignedManifestTests.sampleManifestBytes
        let signature = try privateKey.signature(for: manifest)
        let (bundle, root) = try SignedManifestTests.makeFixtureBundle(
            manifestBytes: manifest,
            signaturePEM: SignedManifestTests.encodeSignaturePEM(signature),
            publicKeyPEM: SignedManifestTests.encodePublicKeyPEM(privateKey.publicKey)
        )
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(GazetteerTrust.isCorpusTrusted(bundle: bundle),
                "freshly signed fixture must verify")

        // Rewrite the manifest in place: same bundle URL, different bytes.
        // A verdict cached by bundle URL would return the stale answer here.
        var tampered = manifest
        tampered.append(Data(" ".utf8))
        try tampered.write(
            to: root.appending(path: "Gazetteers", directoryHint: .isDirectory)
                .appending(path: "gazetteer-manifest.json")
        )
        #expect(!GazetteerTrust.isCorpusTrusted(bundle: bundle),
                "the tampered fixture must be re-evaluated live, not served from a cache")
    }

    @Test("Verdict override seam forces both answers within its task tree")
    func overrideSeam() {
        GazetteerTrust.$verdictOverrideForTesting.withValue(false) {
            #expect(!GazetteerTrust.isShippedCorpusTrusted())
        }
        GazetteerTrust.$verdictOverrideForTesting.withValue(true) {
            #expect(GazetteerTrust.isShippedCorpusTrusted())
        }
    }
}
