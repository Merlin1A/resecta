import Foundation

// The public half of a persistence error's log line. A `DecodingError`
// or `EncodingError` description can quote stored content (a coding
// path built from user-typed keys, an offending value), so the full
// description goes to the log as `.private` and only this summary is
// marked `.public`.

// nonisolated: called from the nonisolated blob methods on detached
// hydrate paths (mirrors FileJSONBlob / UserDefaultsJSONBlob).
nonisolated enum LogSafeError {
    static func publicSummary(_ error: Error) -> String {
        String(describing: error)
    }
}
