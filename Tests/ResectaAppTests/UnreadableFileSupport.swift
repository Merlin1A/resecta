import Testing
import Foundation
@testable import ResectaApp

/// Makes a stored list file unreadable for a test: every permission taken
/// away, then owner read and write given back. A host on which the read
/// still succeeds fails the case rather than passing it.
@MainActor
enum UnreadableFile {
    static func take(_ url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        try #require((try? Data(contentsOf: url)) == nil, "the read must fail on this host")
    }

    static func restore(_ url: URL) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Takes write permission from a folder; the precondition is that a
    /// new file really cannot be made in it.
    static func lockFolder(_ folder: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        let probe = folder.appendingPathComponent("probe-\(UUID().uuidString)")
        try #require((try? Data("x".utf8).write(to: probe)) == nil, "the folder must refuse a write on this host")
    }

    static func unlockFolder(_ folder: URL) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
    }
}
