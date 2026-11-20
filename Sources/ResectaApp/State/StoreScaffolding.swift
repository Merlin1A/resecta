import Foundation
import UIKit

// Persistence scaffolding the file-backed stores share: the lenient row
// wrapper their envelopes decode through, and the one-shot move of a
// pre-file UserDefaults envelope into the protected file.

/// What one change to a saved list came to. A screen shows its success
/// only for `saved` and its refusal words only for `refused`.
nonisolated enum ListChange: Equatable {
    /// The change was made and stored.
    case saved
    /// The change was not made, for this reason.
    case refused(ListRefusal)
    /// The change was made in memory and its write did not report success.
    /// No store returns it yet: no write reports its outcome.
    case notSaved
    /// The list's file is there and could not be read, so the store takes
    /// no change until a read succeeds; nothing changed.
    case held
}

/// Why a change to a saved list was refused.
nonisolated enum ListRefusal: Equatable {
    /// An empty, over-long or invalid entry.
    case invalid
    /// The list is at its cap.
    case full
    /// A name, label or term that is already there.
    case duplicate
    /// No entry with that id.
    case missing
}

/// The notices on which a held store reads its file again: the app coming
/// to the front, and protected files becoming available.
enum StoreReadAgain {
    static let notices: [Notification.Name] = [
        UIApplication.didBecomeActiveNotification,
        UIApplication.protectedDataDidBecomeAvailableNotification,
    ]
}

/// Notice observers that are removed when their holder goes. The handler
/// runs on the main actor: at once when the notice is posted on the main
/// thread, otherwise on its next turn.
nonisolated final class NoticeObservers: @unchecked Sendable {
    // Written once in `init`, read once in `deinit`.
    private let tokens: [NSObjectProtocol]

    init(_ names: [Notification.Name], _ handler: @escaping @MainActor @Sendable () -> Void) {
        tokens = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { _ in
                if Thread.isMainThread {
                    MainActor.assumeIsolated { handler() }
                } else {
                    Task { @MainActor in handler() }
                }
            }
        }
    }

    deinit {
        for token in tokens { NotificationCenter.default.removeObserver(token) }
    }
}

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
        // A file that is there and cannot be read is left as it is; the old
        // key stays for the next start.
        if case .notReadable = read() { return }
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
