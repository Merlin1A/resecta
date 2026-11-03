import Foundation

// The detector diagnostics a PII Scan kickoff surfaces. The shared detector's
// load-time check runs once per process and trusts the name scheme list, so
// on iOS 27 a scheme that is listed while its tagger tags nothing, or a
// tagger that goes silent later in the process, would give a Scan with no
// names and no degraded banner. On iOS 27 each kickoff therefore tags a fixed
// literal name; before iOS 27 the load-time diagnostics stand unchanged.
extension DocumentSearcher {

    /// The diagnostics the app reads at each PII Scan kickoff to raise the
    /// degraded-detection toast and banner: the shared detector's load-time
    /// diagnostics (`sharedLoadDiagnostics`), plus, on iOS 27, the name model
    /// when the live canary (`PIIDetector.nameCanaryTags()`) tags no name.
    /// Runs off the main actor: the canary is a tag pass.
    @concurrent
    public static func scanKickoffDiagnostics() async -> GazetteerLoadDiagnostics {
        let loaded = sharedLoadDiagnostics
        guard #available(iOS 27, *) else { return loaded }
        if PIIDetector.nameCanaryTags() { return loaded }
        return loaded.appending(
            .nerNameModel,
            reason: "NLTagger .nameType tagged no name in the fixed canary at Scan kickoff (NER name detection silent)"
        )
    }
}
