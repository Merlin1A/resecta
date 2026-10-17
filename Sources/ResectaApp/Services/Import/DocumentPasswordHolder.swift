import Foundation

/// The one place the app keeps a document's password while the document is
/// open: the UTF-8 bytes, in memory only. The sheet's text binding is
/// emptied once the bytes are copied here; a reader receives a transient
/// `String` built on demand inside `withPassword`, never this object's
/// storage. Not serializable, not printable: nothing encodes or describes
/// it. `wipe()` zeroes the storage before releasing it — the `String` copies
/// SwiftUI and the readers make are outside the app's control, which is why
/// no copy claims they are erased. Lock-protected so the search copy, built
/// off the main actor from the document's bytes, can unlock its copy with
/// the same password.
nonisolated final class DocumentPasswordHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: [UInt8] = []

    /// True when no password is held.
    var isEmpty: Bool {
        lock.withLock { bytes.isEmpty }
    }

    /// Copy the password's UTF-8 bytes, replacing (and zeroing) any held
    /// value first.
    func set(_ password: String) {
        lock.withLock {
            zero()
            bytes = Array(password.utf8)
        }
    }

    /// Run `body` with a transient `String` built from the held bytes; nil
    /// when nothing is held.
    func withPassword<T>(_ body: (String) throws -> T) rethrows -> T? {
        try lock.withLock {
            guard !bytes.isEmpty else { return nil }
            return try body(String(decoding: bytes, as: UTF8.self))
        }
    }

    /// Zero the storage, then release it.
    func wipe() {
        lock.withLock { zero() }
    }

    private func zero() {
        _ = bytes.withUnsafeMutableBytes { raw in
            raw.initializeMemory(as: UInt8.self, repeating: 0)
        }
        bytes.removeAll(keepingCapacity: false)
    }
}
