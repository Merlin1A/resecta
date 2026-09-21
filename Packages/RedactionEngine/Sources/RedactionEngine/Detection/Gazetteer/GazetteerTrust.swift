import Foundation

// RF: one memoized corpus verdict for every consumer.
//
// The verdict is the manifest's Ed25519 signature AND the per-asset digests
// it carries for the trust-gated files (`AssetIntegrity`). Every gated load
// must consult the same answer: the explicit diagnostics loader
// (`PIIDetector.loadWithDiagnostics`) and the public `PIIDetector.init`
// default arguments both route through this type, so the public initializer
// cannot construct a corpus the check would have withheld. The shipped bundle
// (`Bundle.module`) is verified once per process and the verdict cached; any
// other bundle (a test fixture) is evaluated live on every call, so tampering
// with a fixture between calls is observed.
public enum GazetteerTrust {

    /// The full answer for a bundle. `Bool` consumers read `isTrusted`; the
    /// diagnostics loader reads the report to name what failed.
    public enum CorpusVerdict: Equatable, Sendable {
        /// Signature valid, every trust-gated asset matches its entry. The
        /// report may still carry UNGATED failures to surface.
        case trusted(AssetIntegrity.Report)
        /// The manifest's signature did not verify; the digests were not read.
        case signatureInvalid
        /// Signature valid, but the manifest or a trust-gated asset failed.
        case assetsCompromised(AssetIntegrity.Report)

        public var isTrusted: Bool {
            if case .trusted = self { return true }
            return false
        }

        /// The integrity report when the digests were read at all.
        public var report: AssetIntegrity.Report? {
            switch self {
            case .trusted(let report), .assetsCompromised(let report): return report
            case .signatureInvalid: return nil
            }
        }

        /// Mechanism-only reason for a false verdict (asset names, never
        /// document content); nil when trusted.
        public var failureReason: String? {
            switch self {
            case .trusted: return nil
            case .signatureInvalid:
                return "gazetteer-manifest signature verification failed (PipelineError.detectionError(.detectionCorpusInvalid))"
            case .assetsCompromised(let report):
                let names = report.gated.map(\.description).joined(separator: "; ")
                return "signed-manifest asset verification failed: \(names) (PipelineError.detectionError(.detectionCorpusInvalid))"
            }
        }
    }

    #if DEBUG
    /// Test seam — while bound (via `$verdictOverrideForTesting.withValue`),
    /// every verdict request in the current task tree returns this value
    /// without touching the verifier. Task-local, so a bound override never
    /// leaks into concurrently running tests.
    @TaskLocal static var verdictOverrideForTesting: Bool?

    /// Test observability — how many times the shipped bundle's verdict
    /// has been computed this process (0 before first use, then 1).
    nonisolated(unsafe) static var moduleVerificationCountForTesting = 0
    #endif

    /// The shipped bundle's verdict, computed at most once per process.
    /// `static let` initialization is serialized by the runtime, so the
    /// signature check and the asset pass run exactly once even under
    /// concurrent first access.
    private static let moduleVerdict: CorpusVerdict = {
        #if DEBUG
        moduleVerificationCountForTesting += 1
        #endif
        return computeVerdict(bundle: .module)
    }()

    private static func computeVerdict(bundle: Bundle) -> CorpusVerdict {
        guard GazetteerLoader.isManifestSignatureValid(bundle: bundle) else {
            return .signatureInvalid
        }
        let report = AssetIntegrity.verify(bundle: bundle)
        return report.corpusIntact ? .trusted(report) : .assetsCompromised(report)
    }

    /// The shipped bundle's verdict. Exists because the public
    /// `PIIDetector.init` default arguments may only reference public API —
    /// `Bundle.module` is internal to the package, so the bundle-taking
    /// overload cannot appear in a default-argument position.
    public static func isShippedCorpusTrusted() -> Bool {
        isCorpusTrusted(bundle: .module)
    }

    /// The shipped bundle's full verdict (memoized).
    public static func shippedCorpusVerdict() -> CorpusVerdict {
        corpusVerdict(bundle: .module)
    }

    /// `true` iff `bundle`'s manifest carries a valid Ed25519 signature AND
    /// every trust-gated asset matches the digest the manifest records. The
    /// production bundle instance's answer is memoized; any other bundle is
    /// verified live.
    public static func isCorpusTrusted(bundle: Bundle) -> Bool {
        corpusVerdict(bundle: bundle).isTrusted
    }

    /// The full verdict for `bundle` (see `isCorpusTrusted(bundle:)`).
    public static func corpusVerdict(bundle: Bundle) -> CorpusVerdict {
        #if DEBUG
        if let forced = verdictOverrideForTesting {
            return forced ? .trusted(.empty) : .signatureInvalid
        }
        #endif
        // Identity comparison: `Bundle.module` returns one cached instance,
        // and reading `bundleURL` off an arbitrary bundle can trap (a bare
        // `Bundle()`, which the degraded-path tests inject, has no URL).
        if bundle === Bundle.module {
            return moduleVerdict
        }
        return computeVerdict(bundle: bundle)
    }
}
