import Testing
import SwiftUI
import UIKit
@testable import ResectaApp

// The brief message's view: its measured height against its drawn height
// (the sizing step chooses by the measure), the marks' symbols and colours,
// the action's tappable frame, and a source scan that keeps its words whole.

@Suite("Receipt view")
@MainActor
struct ReceiptViewTests {

    /// A queue on a held clock, so a posted message stays up.
    private func item(_ id: MessageID, action: Bool) -> (ToastItem, ToastQueueManager) {
        let mgr = ToastQueueManager()
        mgr.voiceOverRunning = { false }
        mgr.switchControlRunning = { false }
        mgr.postAnnouncement = { _ in }
        if action { mgr.post(id, action: {}) } else { mgr.post(id) }
        return (mgr.activeToasts[0], mgr)
    }

    private func drawnHeight(_ item: ToastItem, _ mgr: ToastQueueManager, size: DynamicTypeSize, width: CGFloat) -> CGFloat {
        let view = ReceiptView(item: item, toastManager: mgr).environment(\.dynamicTypeSize, size)
        return UIHostingController(rootView: view).sizeThatFits(in: CGSize(width: width, height: 4_000)).height
    }

    @Test("A receipt's measured height is within 4 points of its drawn height")
    func measuredMatchesDrawn() {
        let cases: [(MessageID, Bool)] = [
            (.deletedBoxes(count: 2), true),
            (.outputReclaimed, false),
            (.searchResultsTruncated, false),
        ]
        for (id, action) in cases {
            let (item, mgr) = item(id, action: action)
            for size in [DynamicTypeSize.accessibility3, .accessibility5] {
                let measured = ReceiptView.height(of: item, size: size, width: 402)
                let drawn = drawnHeight(item, mgr, size: size, width: 402)
                #expect(abs(measured - drawn) <= 4, "\(item.message) at \(size): measured \(measured), drawn \(drawn)")
            }
        }
    }

    @Test("\"Deleted 2 regions.\" with Undo steps down one size in the editor's canvas at the largest size")
    func deletedTwoStepsDownOneSize() {
        // Drawn at 402 wide: 197.3 at the third accessibility size, 217.3 at
        // the fourth, 242.0 at the fifth. The canvas at the largest size is
        // 590 (limit 236), so the fifth is over it and the fourth fits.
        let (item, _) = item(.deletedBoxes(count: 2), action: true)
        let limit = MessageSizing.limit(space: 590)
        let size = MessageSizing.drawSize(person: .accessibility5, limit: limit) {
            ReceiptView.height(of: item, size: $0, width: 402)
        }
        #expect(size == .accessibility4)
    }

    @Test("Each tone has its mark and colour")
    func toneMarks() {
        #expect(ReceiptView.symbol(for: .done) == "checkmark")
        #expect(ReceiptView.symbol(for: .note) == "info.circle.fill")
        #expect(ReceiptView.symbol(for: .caution) == "exclamationmark.triangle.fill")
        #expect(ReceiptView.symbol(for: .stop) == "exclamationmark.octagon.fill")
        #expect(ReceiptView.symbolPointSize(for: .done) == 15)
        for tone in [MessageTone.note, .caution, .stop] { #expect(ReceiptView.symbolPointSize(for: tone) == 18) }
        #expect(ReceiptView.markColor(for: .done) == ResectaTokens.Ink.words)
        #expect(ReceiptView.markColor(for: .note) == ResectaTokens.Ink.noteMark)
        #expect(ReceiptView.markColor(for: .caution) == ResectaTokens.Ink.cautionMark)
        #expect(ReceiptView.markColor(for: .stop) == ResectaTokens.Ink.stopMark)
    }

    @Test("The Undo's tappable frame is at least the touch floor in layout")
    func actionFrameFloor() {
        let floor = ResectaTokens.TouchTarget.minimum
        #expect(ReceiptView.actionFrameHeight(receiptHeight: 44) == floor)
        #expect(ReceiptView.actionFrameHeight(receiptHeight: 65) == 65)
        #expect(ReceiptView.actionFrameHeight(receiptHeight: floor) == floor)
    }

    @Test("A receipt is never cut at any text size")
    func neverCut() throws {
        let source = try Self.loadRepoFile("Sources/ResectaApp/Views/Messages/ReceiptView.swift")
        #expect(!source.contains(".lineLimit("))
    }

    @Test("A brief message's mark takes the message surface's own colour")
    func marksTakeTheSurfacesColour() throws {
        let source = try Self.loadRepoFile("Sources/ResectaApp/Views/Messages/ReceiptView.swift")
        for name in ["Ink.cautionMark", "Ink.stopMark", "Ink.noteMark"] { #expect(source.contains(name), "\(name)") }
        for name in ["SemanticColor.warnText", "SemanticColor.failText", "SemanticColor.attentionText"] {
            #expect(!source.contains(name), "\(name)")
        }
    }

    private static func loadRepoFile(_ relativePath: String, file: StaticString = #filePath) throws -> String {
        let root = URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()   // Tests/ResectaAppTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // <repo root>
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
