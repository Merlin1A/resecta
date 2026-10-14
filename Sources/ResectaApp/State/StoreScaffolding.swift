import Foundation

// Persistence scaffolding the file-backed stores share: the lenient row
// wrapper their envelopes decode through, and the one-shot move of a
// pre-file UserDefaults envelope into the protected file.

/// Never-throwing element wrapper for a lenient envelope decode. The
/// wrapper's `init` always succeeds, so an unkeyed container advances past
/// a failing element instead of aborting the whole array — one bad row
/// cannot empty a user's list — and the failed element is kept as a raw
/// JSON tree for re-emission, so a re-save cannot erase it.
nonisolated struct FailableRow<Value: Decodable>: Decodable {
    let value: Value?
    let raw: RetainedJSONValue?

    init(from decoder: Decoder) {
        if let decoded = try? Value(from: decoder) {
            self.value = decoded
            self.raw = nil
        } else {
            self.value = nil
            self.raw = try? RetainedJSONValue(from: decoder)
        }
    }
}

extension FileJSONBlob {
    /// One-shot move of a pre-file `UserDefaults` envelope under `key` into
    /// this protected file. The key is removed only after the file is
    /// confirmed on disk, so a failed write retries next launch. Envelope
    /// shape and schema version are unchanged on both sides; a later launch
    /// sees no key and does nothing.
    nonisolated func migrateLegacyDefaultsIfNeeded(from defaults: UserDefaults, key: String) {
        guard defaults.data(forKey: key) != nil else { return }
        let legacy = UserDefaultsJSONBlob<T>(
            key: key,
            schemaVersion: schemaVersion,
            defaults: defaults,
            fallback: fallback
        )
        save(legacy.load())
        if FileManager.default.fileExists(atPath: fileURL.path) {
            defaults.removeObject(forKey: key)
        }
    }
}
