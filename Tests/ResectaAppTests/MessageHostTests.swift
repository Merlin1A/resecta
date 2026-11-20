import Testing
import SwiftUI
@testable import ResectaApp

// Where brief messages are drawn: the place's arithmetic, and source scans
// over the app that keep every presentation, dialog and announcement on the
// queue's terms. The scans skip comment lines (a line whose first
// characters after its indent are `//`).

@Suite("Message hosts")
@MainActor
struct MessageHostTests {

    @Test("The root place is 8 points above the bottom chrome while editing and 44 above the screen's foot otherwise")
    func rootPlace() {
        #expect(MessagePlacement.rootLift(editing: true, bottomClearance: 62, safeAreaBottom: 34) == 70)
        #expect(MessagePlacement.rootLift(editing: true, bottomClearance: 125, safeAreaBottom: 34) == 133)
        #expect(MessagePlacement.rootLift(editing: false, bottomClearance: 62, safeAreaBottom: 34) == 10)
        #expect(MessagePlacement.rootLift(editing: false, bottomClearance: 0, safeAreaBottom: 50) == 0)
    }

    @Test("A sheet's receipt sits 12 points above its footer")
    func sheetPlace() {
        #expect(MessagePlacement.sheetLift(footerLift: 63) == 75)
        #expect(MessagePlacement.sheetLift(footerLift: 0) == 12)
    }

    @Test("A view leaving the screen ends no message")
    func leavingEndsNothing() throws {
        let lines = try Self.codeLines("Sources/ResectaApp/Views/Messages/MessageHost.swift")
        let leaving = lines.filter { $0.contains(".onDisappear") }
        #expect(leaving.count == 3)
        for line in leaving {
            let allowed = line.contains("unregisterLayer(")
                || line.contains("setLayerSurface(") && line.contains("visible: false")
                || line.contains("setHold(") && line.contains(", false)")
            #expect(allowed, "\(line)")
        }
    }

    // MARK: - Reading the source

    static func repoRoot(file: StaticString = #filePath) -> URL {
        URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()   // Tests/ResectaAppTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // <repo root>
    }

    /// A file's lines with comment lines left out.
    static func codeLines(_ relativePath: String) throws -> [String] {
        let text = try String(contentsOf: repoRoot().appendingPathComponent(relativePath), encoding: .utf8)
        return text.components(separatedBy: "\n").filter { !isComment($0) }
    }

    static func isComment(_ line: String) -> Bool {
        line.drop(while: { $0 == " " || $0 == "\t" }).hasPrefix("//")
    }
}
