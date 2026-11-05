import Testing
import Foundation
import CoreGraphics
import Synchronization
@testable import RedactionEngine

// The import-time walk of an action's /Next chain reads each action once,
// as the form-field walk already does. A chain that lists the same next
// action more than once must be read promptly and give the same answer as
// an unshared chain.

@Suite("Active-content walk: a shared /Next chain is read once per action", .tags(.security))
struct ActiveContentChainSharingTests {

    /// Waits this long for the walk, far longer than it needs.
    private static let patience: TimeInterval = 20

    /// Runs the walk on its own thread so a walk that does not finish fails
    /// the test instead of stalling the suite. Nil when it did not finish.
    private func scanWithin(_ seconds: TimeInterval, _ data: Data) -> ActiveContentLocation?? {
        let outcome = Outcome()
        let finished = DispatchSemaphore(value: 0)
        let thread = Thread {
            let found: ActiveContentLocation?
            if let provider = CGDataProvider(data: data as CFData),
               let document = CGPDFDocument(provider) {
                found = ActiveContentScan.firstLocation(in: document)
            } else {
                found = nil
            }
            outcome.value.withLock { $0 = .some(found) }
            finished.signal()
        }
        thread.start()
        guard finished.wait(timeout: .now() + seconds) == .success else { return nil }
        return outcome.value.withLock { $0 }
    }

    /// The walk's answer, written once by the walking thread.
    private final class Outcome: Sendable {
        let value = Mutex<ActiveContentLocation??>(nil)
    }

    @Test("A /Next chain that lists one action many times at every level is read promptly, and is clean")
    func sharedChainOfInactiveActionsFinishes() throws {
        let data = TestFixtures.withSharedNextChain(width: 24, levels: 7, leafIsJavaScript: false)
        let result = scanWithin(Self.patience, data)
        let finished = try #require(result, "the walk did not finish within \(Int(Self.patience)) s")
        #expect(finished == nil, "a chain of GoTo actions carries no active content")
    }

    @Test("The same shared chain ending in JavaScript is still reported at the open action")
    func sharedChainEndingInJavaScriptIsReported() throws {
        let data = TestFixtures.withSharedNextChain(width: 24, levels: 7, leafIsJavaScript: true)
        let result = scanWithin(Self.patience, data)
        let finished = try #require(result, "the walk did not finish within \(Int(Self.patience)) s")
        #expect(finished == .openAction)
    }
}

extension TestFixtures {

    /// The catalog's /OpenAction is a GoTo whose /Next lists the level-1
    /// action `width` times; each level lists the next level's action
    /// `width` times; the last level has no /Next. Every action but
    /// (optionally) the last is a GoTo. Objects 6… are the levels, with the
    /// last level within the walk's depth bound.
    static func withSharedNextChain(width: Int, levels: Int, leafIsJavaScript: Bool) -> Data {
        func refs(_ id: Int) -> String { Array(repeating: "\(id) 0 R", count: width).joined(separator: " ") }
        var objects: [PDFObject] = []
        for level in 1...levels {
            let id = 5 + level
            if level == levels {
                objects.append(PDFObject(id: id, content: leafIsJavaScript
                    ? "<< /Type /Action /S /JavaScript /JS (app.alert\\('probe'\\)) >>"
                    : "<< /Type /Action /S /GoTo /D [3 0 R /Fit] >>"))
            } else {
                objects.append(PDFObject(
                    id: id, content: "<< /Type /Action /S /GoTo /D [3 0 R /Fit] /Next [\(refs(id + 1))] >>"))
            }
        }
        return activeContentProbe(
            catalogExtras: "/OpenAction << /Type /Action /S /GoTo /D [3 0 R /Fit] /Next [\(refs(6))] >>",
            extraObjects: objects)
    }
}
