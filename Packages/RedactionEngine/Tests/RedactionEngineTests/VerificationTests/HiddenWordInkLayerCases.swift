import Testing
import Foundation
import CoreGraphics
import PDFKit
@testable import RedactionEngine

// Frozen cases for the hidden-word check as the verifier runs it, written
// before the check.
//
// V1–V4 export the seeded page (its layer drifted 30 pt along the line) with a
// box over a word's print through the corpus mirror's route
// (`HiddenWordInkFixtures.mirrorRun`), which leaves the word's drifted hidden
// copy in the export, and verify it. Today every one of those reports passes
// the leak or flags only a neighbour; with the check, each reads Checks Failed
// with the check's row failing on page 1. Each case first asserts that the
// leak is in the export, so a case that passes is never a case whose page
// stopped leaking.
//
// The other cases pin what the check must not do: fail a clean export, run in
// Secure, read the source on a page it has nothing to check, pass when it
// cannot read, or put the page's words in the report.

@Suite("Hidden word check: the layer (frozen cases)", .serialized)
struct HiddenWordInkLayerCases {
    typealias F = HiddenWordInkFixtures

    static let seeded = F.seededPage(drift: 30)

    static func layer() throws -> VerificationLayer {
        try #require(HiddenWordInkSeam.layer, "the check is not built")
    }

    static func row(_ report: VerificationReport) throws -> LayerResult {
        let layer = try layer()
        return try #require(report.layers.first { $0.layer == layer }, "the report carries the check's row")
    }

    /// The leak is in the export, and the run reads Checks Failed with the
    /// check's row failing on page 1.
    static func expectLeakFails(_ run: F.Run, leaked word: String, _ comment: Comment) throws {
        try expectLeak(run, leaked: word, comment)
        #expect(run.report.overallStatus.isFail, "\(comment): the run reads Checks Failed, not \(run.report.overallStatus)")
        let row = try row(run.report)
        #expect(row.status.isFail, "\(comment): the check's row fails")
        #expect(row.pageReferences == [0], "\(comment): on page 1")
    }

    /// The precondition: the export holds `word`'s hidden copy.
    static func expectLeak(_ run: F.Run, leaked word: String, _ comment: Comment) throws {
        let hidden = try #require(F.hiddenRect(run.source.page(at: 0)!, word))
        #expect(!F.textInside(run.output, hidden).isEmpty, "precondition: \(comment) leaves \(word)'s hidden copy in the export")
    }

    // MARK: - The leaking exports

    static func p4() async throws -> F.Run {
        try await F.mirrorRun(seeded, paint: F.inkRect(line: 5, phrase: "Marisol", through: "Vance-Oduya"))
    }
    static func p6() async throws -> F.Run { try await F.mirrorRun(seeded, paint: F.inkRect(line: 11, phrase: "Lee")) }
    static func p7() async throws -> F.Run {
        let page = try #require(PDFDocument(data: seeded)?.page(at: 0))
        let strip = try #require(F.hiddenRect(page, "Signed"))
        return try await F.mirrorRun(seeded, paint: F.inkRect(line: 11, phrase: "Signed", through: "Lee"),
                                     searchTerm: "Signed", strip: strip)
    }
    static func p8() async throws -> F.Run { try await F.mirrorRun(seeded, paint: F.inkRect(line: 11, phrase: "Signed")) }
    static func p9() async throws -> F.Run { try await F.mirrorRun(seeded, paint: F.inkRect(line: 0, phrase: "The")) }

    @Test("V1: a hand box over a name whose fragment \"uya\" survives past the box reads Checks Failed", .timeLimit(.minutes(3)))
    func v1() async throws { try Self.expectLeakFails(try await Self.p4(), leaked: "Vance-Oduya", "a hand box on the name") }

    @Test("V2: a hand box over \"Lee\", its whole hidden copy past the box, reads Checks Failed", .timeLimit(.minutes(3)))
    func v2() async throws { try Self.expectLeakFails(try await Self.p6(), leaked: "Lee", "a hand box on Lee") }

    @Test("V3 (the RED): a Search box for \"Signed\" widened by hand over \"Signed by Lee\", Checks Passed today, reads Checks Failed",
          .timeLimit(.minutes(3)))
    func v3() async throws { try Self.expectLeakFails(try await Self.p7(), leaked: "Lee", "the widened Search box") }

    @Test("V4: a hand box on a line's first word, and on a first word narrower than the drift, read Checks Failed",
          .timeLimit(.minutes(3)))
    func v4() async throws {
        let p8 = try await Self.p8(), p9 = try await Self.p9()
        try Self.expectLeak(p9, leaked: "The", "a hand box on The")
        try Self.expectLeakFails(p8, leaked: "Signed", "a hand box on Signed")
        try Self.expectLeakFails(p9, leaked: "The", "a hand box on The")
    }

    // MARK: - Clean, Secure

    @Test("V6: a box over the name on the same page with its layer on the ink is clean: the check's row passes",
          .timeLimit(.minutes(3)))
    func v6() async throws {
        let data = F.seededPage(drift: 0)
        let run = try await F.mirrorRun(data, paint: F.inkRect(line: 5, phrase: "Marisol", through: "Vance-Oduya"))
        let hidden = try #require(F.hiddenRect(run.source.page(at: 0)!, "Marisol"))
        #expect(F.textInside(run.output, hidden).isEmpty, "precondition: the name's hidden copy is gone")
        #expect(run.report.perPageModes == [.searchableRedaction], "precondition: the page kept its text layer")
        #expect(try Self.row(run.report).status == .pass)
        #expect(!run.report.overallStatus.isFail)
    }

    @Test("V7: the check does not apply in Secure: the report keeps its seven rows", .timeLimit(.minutes(3)))
    func v7() async throws {
        let layer = try Self.layer()
        #expect(!layer.appliesTo(.secureRasterization))
        #expect(layer.appliesTo(.searchableRedaction))
        let run = try await F.mirrorRun(Self.seeded, paint: F.inkRect(line: 5, phrase: "Marisol", through: "Vance-Oduya"),
                                        mode: .secureRasterization)
        #expect(!run.report.layers.contains { $0.layer == layer })
        #expect(run.report.layers.count == 7)
    }

    // MARK: - Nothing to check: no source read

    static func runLayer(_ output: PDFDocument, source: PDFDocument?, regions: [Int: [RedactionRegion]],
                         reader: InkCaseReader?) async throws -> LayerResult {
        let result = await HiddenWordInkSeam.runLayer(output: output, source: source, regions: regions,
                                                      mode: .searchableRedaction, reader: reader)
        return try #require(result, "the check is not built")
    }

    @Test("V10: an image-only output page is not applicable, and the source is never read", .timeLimit(.minutes(3)))
    func v10() async throws {
        let run = try await F.mirrorRun(Self.seeded, paint: F.inkRect(line: 5, phrase: "Marisol", through: "Vance-Oduya"),
                                        mode: .secureRasterization)
        let text: String = run.output.page(at: 0)?.string ?? ""
        #expect(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "precondition: the output page carries no text")
        let reader = InkCaseReader()
        let row = try await Self.runLayer(run.output, source: run.source, regions: [0: [run.region]], reader: reader)
        #expect(row.status.isNotApplicable)
        #expect(reader.calls == 0)
    }

    @Test("V11: a plain source page with a box, and a page with no box, are not applicable with no source read",
          .timeLimit(.minutes(3)))
    func v11() async throws {
        let plain = try await F.mirrorRun(F.seededPage(drift: 0, plain: true),
                                          paint: F.inkRect(line: 5, phrase: "Marisol", through: "Vance-Oduya"))
        let plainText: String = plain.output.page(at: 0)?.string ?? ""
        #expect(!plainText.isEmpty, "precondition: the plain page kept its text")
        let r1 = InkCaseReader()
        let plainRow = try await Self.runLayer(plain.output, source: plain.source, regions: [0: [plain.region]], reader: r1)
        #expect(plainRow.status.isNotApplicable, "a plain page's text layer is its own ink")
        #expect(r1.calls == 0, "no recognition pass is spent on a plain page")

        let leak = try await Self.p7()
        let r2 = InkCaseReader()
        let noBoxRow = try await Self.runLayer(leak.output, source: leak.source, regions: [:], reader: r2)
        #expect(noBoxRow.status.isNotApplicable, "nothing can be under a box on a page with no box")
        #expect(r2.calls == 0)
    }

    // MARK: - Could not verify: never a pass

    @Test("V12: with no source, or a locked one, the check could not verify, and reads nothing", .timeLimit(.minutes(3)))
    func v12() async throws {
        let leak = try await Self.p7()
        let locked = try #require(PDFDocument(data: try F.lockedCopy(Self.seeded)))
        #expect(locked.isLocked, "precondition: the copy opens locked")
        let r1 = InkCaseReader()
        let noSource = try await Self.runLayer(leak.output, source: nil, regions: [0: [leak.region]], reader: r1)
        #expect(noSource.status.isWarn && noSource.couldNotVerify, "no source: \(noSource.status)")
        #expect(r1.calls == 0)

        let r2 = InkCaseReader()
        let lockedRow = try await Self.runLayer(leak.output, source: locked, regions: [0: [leak.region]], reader: r2)
        #expect(lockedRow.status.isWarn && lockedRow.couldNotVerify, "a locked source: \(lockedRow.status)")
        #expect(r2.calls == 0)
    }

    @Test("V13: a source read that fails could not verify, and is never a pass", .timeLimit(.minutes(3)))
    func v13() async throws {
        let leak = try await Self.p7()
        let reader = InkCaseReader(fails: true)
        let row = try await Self.runLayer(leak.output, source: leak.source, regions: [0: [leak.region]], reader: reader)
        #expect(row.status.isWarn && row.couldNotVerify, "a failed read: \(row.status)")
        #expect(row.status != .pass)
        #expect(reader.calls >= 1, "the read was attempted")
    }

    // MARK: - No document text in the report

    @Test("V14: the check's row carries none of the page's words, and the check adds none to the report",
          .timeLimit(.minutes(6)))
    func v14() async throws {
        let layer = try Self.layer()
        for run in [try await Self.p4(), try await Self.p6(), try await Self.p7(), try await Self.p8(), try await Self.p9()] {
            let row = try Self.row(run.report)
            let rowText = [row.name, row.shortDescription, row.detailDescription].joined(separator: " ")
            for word in F.distinctiveWords {
                #expect(!rowText.contains(word), "the check's row names a word of the page")
            }
            #expect(row.reviewTermTexts == nil)
            #expect(row.queryLines == nil)

            // The whole report, against the same report without the check's row.
            let without = VerificationReport(
                layers: run.report.layers.filter { $0.layer != layer }, overallStatus: run.report.overallStatus,
                durationSeconds: run.report.durationSeconds, perPageModes: run.report.perPageModes,
                perPageFallbackReasons: run.report.perPageFallbackReasons)
            let full = String(decoding: try run.report.jsonData(), as: UTF8.self)
            let base = String(decoding: try without.jsonData(), as: UTF8.self)
            for word in F.distinctiveWords {
                #expect(full.components(separatedBy: word).count == base.components(separatedBy: word).count,
                        "the check adds an occurrence of a word of the page to the report")
            }
        }
    }

    // MARK: - The page's frame

    @Test("V21: a clean export of a page with /Rotate 90 and a crop box off the origin is clean", .timeLimit(.minutes(3)))
    func v21() async throws {
        let data = F.seededPage(drift: 0, rotate: 90, cropBox: CGRect(x: 18, y: 24, width: 576, height: 744))
        let page = try #require(PDFDocument(data: data)?.page(at: 0))
        // The layer sits on the ink, so the name's hidden box is its printed box, in the region's frame.
        let paint = try #require(F.hiddenRect(page, "Marisol Vance-Oduya"))
        let run = try await F.mirrorRun(data, paint: paint)
        #expect(run.report.perPageModes == [.searchableRedaction], "precondition: the page kept its text layer")
        let text: String = run.output.page(at: 0)?.string ?? ""
        #expect(!text.contains("Marisol"), "precondition: the name is gone")
        #expect(try Self.row(run.report).status == .pass, "the output's words and the source render share one frame")
        #expect(!run.report.overallStatus.isFail)
    }

    @Test("V21b: a hand box over the name on a page with /Rotate 90, an offset crop box and its layer drifted 30 pt, reads Checks Failed",
          .timeLimit(.minutes(3)))
    func v21b() async throws {
        let crop = CGRect(x: 18, y: 24, width: 576, height: 744)
        let data = F.seededPage(drift: 30, rotate: 90, cropBox: crop)
        // The name's print, in the region's frame: its hidden box on the drift-0 twin of the same rotated page.
        let twin = try #require(PDFDocument(data: F.seededPage(drift: 0, rotate: 90, cropBox: crop))?.page(at: 0))
        let paint = try #require(F.hiddenRect(twin, "Marisol Vance-Oduya"))
        let run = try await F.mirrorRun(data, paint: paint)
        let source = try #require(run.source.page(at: 0))
        let marisol = try #require(F.hiddenRect(source, "Marisol"))
        #expect(F.textInside(run.source, marisol).contains("Marisol"),
                "precondition: the helper reads the rotated page's frame")
        try Self.expectLeakFails(run, leaked: "Vance-Oduya", "a hand box on the name of the rotated page")
    }
}
