import RedactionEngine

/// The could-not-verify WARN family: a WARN layer whose check did not fully
/// run on the output — pages it could not read or open, OCR it could not run
/// or map, terms it could not search, positions it could not measure,
/// per-page data it lacked, the Search Re-check's unchecked pages. A WARN
/// that reports what a check saw (a positional graze, a count excess, a
/// structural or metadata note, an attestation mismatch) is a routine note,
/// not this family.
///
/// The engine carries the classification: `LayerResult.couldNotVerify` is
/// set at the site that composes each such WARN and pinned by the engine
/// package's own tests, so the app never matches on the message text. The
/// share-risk confirm keys on this predicate
/// (`DocumentEditorView.shareNeedsIncompleteWarnConfirm`) and lists the
/// reporting checks from it (`DocumentEditorView.couldNotVerifyItemLines`).
enum CouldNotVerifyWarn {
    /// True for a `.warn` layer the engine flagged as could-not-verify. The
    /// status guard restates the engine's WARN-only contract for the flag on
    /// the app side; a flag on any other status is ignored.
    static func matches(_ layer: LayerResult) -> Bool {
        layer.status.isWarn && layer.couldNotVerify
    }
}
