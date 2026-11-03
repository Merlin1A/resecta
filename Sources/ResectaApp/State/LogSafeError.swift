import Foundation

// The public half of a persistence error's log line. A `DecodingError`
// or `EncodingError` description can quote stored content (a coding
// path built from user-typed keys, an offending value), so the full
// description goes to the log as `.private` and only this summary is
// marked `.public`.

// nonisolated: called from the nonisolated blob methods on detached
// hydrate paths (mirrors FileJSONBlob / UserDefaultsJSONBlob).
nonisolated enum LogSafeError {
    /// The error's type, its case for a Codable error, and its domain and
    /// code, for example `Swift.DecodingError.typeMismatch (NSCocoaErrorDomain 4864)`.
    /// None of these parts carries the error's associated values, coding
    /// path, user info or description.
    static func publicSummary(_ error: Error) -> String {
        var name = String(reflecting: type(of: error))
        if let caseName = codableCaseName(error) {
            name += ".\(caseName)"
        }
        let nsError = error as NSError
        return "\(name) (\(nsError.domain) \(nsError.code))"
    }

    private static func codableCaseName(_ error: Error) -> String? {
        if let decoding = error as? DecodingError {
            switch decoding {
            case .typeMismatch: return "typeMismatch"
            case .valueNotFound: return "valueNotFound"
            case .keyNotFound: return "keyNotFound"
            case .dataCorrupted: return "dataCorrupted"
            @unknown default: return nil
            }
        }
        if let encoding = error as? EncodingError {
            switch encoding {
            case .invalidValue: return "invalidValue"
            @unknown default: return nil
            }
        }
        return nil
    }
}
