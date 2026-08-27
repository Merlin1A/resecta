import Foundation

// RF: one memoized manifest-signature verdict for every consumer.
//
// Every signature-gated load must consult the same answer: the explicit
// diagnostics loader (`PIIDetector.loadWithDiagnostics`) and the public
// `PIIDetector.init` default arguments both route through this type, so
// the public initializer cannot construct a corpus the signature check
// would have withheld. The shipped bundle (`Bundle.module`) is verified
// once per process and the verdict cached; any other bundle (a test
// fixture) is evaluated live on every call, so tampering with a fixture
// between calls is observed.
public enum GazetteerTrust {

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
    /// verification runs exactly once even under concurrent first access.
    private static let moduleVerdict: Bool = {
        #if DEBUG
        moduleVerificationCountForTesting += 1
        #endif
        return GazetteerLoader.isManifestSignatureValid(bundle: .module)
    }()

    /// The shipped bundle's verdict. Exists because the public
    /// `PIIDetector.init` default arguments may only reference public API —
    /// `Bundle.module` is internal to the package, so the bundle-taking
    /// overload cannot appear in a default-argument position.
    public static func isShippedManifestSignatureValid() -> Bool {
        isManifestSignatureValid(bundle: .module)
    }

    /// `true` iff `bundle`'s gazetteer manifest carries a valid Ed25519
    /// signature. The production bundle instance's answer is memoized; any
    /// other bundle is verified live.
    public static func isManifestSignatureValid(bundle: Bundle) -> Bool {
        #if DEBUG
        if let forced = verdictOverrideForTesting { return forced }
        #endif
        // Identity comparison: `Bundle.module` returns one cached instance,
        // and reading `bundleURL` off an arbitrary bundle can trap (a bare
        // `Bundle()`, which the degraded-path tests inject, has no URL).
        if bundle === Bundle.module {
            return moduleVerdict
        }
        return GazetteerLoader.isManifestSignatureValid(bundle: bundle)
    }
}
