import Testing
import Foundation
import CryptoKit
@testable import ResectaApp

// The share copy's name. Every export was named `redacted.pdf`, so saving
// several documents into one folder asked to replace the last one, with
// Replace first. The name is now a short code made from the redacted
// file's own bytes: distinct per document, the same for the same file,
// and still free of the export time and of the source document's name.

@Suite("The share copy's name")
struct ShareCopyFileNameTests {

    private func write(_ bytes: Data, named name: String) throws -> (url: URL, root: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("share_name_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent(name)
        try bytes.write(to: url)
        return (url, root)
    }

    @Test("Two different redacted files get different names")
    func differentFilesDifferentNames() throws {
        let a = try write(Data("first document".utf8), named: "redacted_\(UUID().uuidString).pdf")
        let b = try write(Data("second document".utf8), named: "redacted_\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: a.root); try? FileManager.default.removeItem(at: b.root) }
        #expect(try DocumentEditorView.shareCopyFileName(forOutput: a.url)
                != DocumentEditorView.shareCopyFileName(forOutput: b.url))
    }

    @Test("The name is redacted- and the first eight hex of the file's SHA-256, and nothing else")
    func nameIsTheFileDigest() throws {
        let bytes = Data("the redacted output".utf8)
        let f = try write(bytes, named: "redacted_\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: f.root) }
        let hex = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let name = try DocumentEditorView.shareCopyFileName(forOutput: f.url)
        #expect(name == "redacted-\(hex.prefix(8)).pdf")
        #expect(name.range(of: #"^redacted-[0-9a-f]{8}\.pdf$"#, options: .regularExpression) != nil)
    }

    @Test("The same bytes give the same name, whatever the file is called and whenever it is asked")
    func nameCarriesNoSourceTextAndNoTime() throws {
        let bytes = Data("one redacted output".utf8)
        let plain = try write(bytes, named: "redacted_\(UUID().uuidString).pdf")
        let named = try write(bytes, named: "Vance-Oduya Intake.pdf")
        defer { try? FileManager.default.removeItem(at: plain.root); try? FileManager.default.removeItem(at: named.root) }

        let first = try DocumentEditorView.shareCopyFileName(forOutput: plain.url)
        let fromASourceName = try DocumentEditorView.shareCopyFileName(forOutput: named.url)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 0)],
                                              ofItemAtPath: plain.url.path)
        let later = try DocumentEditorView.shareCopyFileName(forOutput: plain.url)

        #expect(fromASourceName == first, "the name reads the bytes only, never the file's own name")
        #expect(later == first, "the name reads no time: not the clock, not the file's dates")
        for word in ["Vance", "Oduya", "Intake"] {
            #expect(!fromASourceName.contains(word))
        }
    }
}
