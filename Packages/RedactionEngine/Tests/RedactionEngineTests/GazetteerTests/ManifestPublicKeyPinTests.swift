import CryptoKit
import Foundation
import Testing
@testable import RedactionEngine

// The bundled manifest public key is pinned by fingerprint: a rotation is a
// deliberate commit that moves this constant beside the new key, so a swapped
// key + re-signed manifest cannot pass review silently. The same fingerprint is
// published in the DataPipeline's KEY-MANAGEMENT.md, and the pem's git blob is
// pinned in Scripts/verify-shipped-asset-hashes.sh.
@Suite("Manifest public key pin")
struct ManifestPublicKeyPinTests {
    /// SHA-256 over the DER body of `Gazetteers/manifest_public_key.pem`
    /// (`openssl pkey -pubin -in … -outform DER | openssl dgst -sha256`).
    static let pinnedFingerprint = "2f94b2aecc157d818bbdee34e04d20cbecc4b83e86f8ecbea932fdee07e90bd2"

    @Test("The bundled manifest public key is the pinned key")
    func bundledKeyMatchesPin() throws {
        let url = try #require(Bundle.module.url(
            forResource: "manifest_public_key", withExtension: "pem", subdirectory: "Gazetteers"))
        let pem = try String(contentsOf: url, encoding: .utf8)
        let body = pem.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
        let der = try #require(Data(base64Encoded: body))
        let digest = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
        #expect(digest == Self.pinnedFingerprint)
    }
}
