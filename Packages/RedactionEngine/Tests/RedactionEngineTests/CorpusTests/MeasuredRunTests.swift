import CoreGraphics
import CoreText
import Foundation
import PDFKit
import Testing
@testable import RedactionEngine
import RedactionCore

// The measured run's entry (`MeasuredRun`): its fixed cases, which hand it the
// switch's policy so both policies are read on any build, and the run itself,
// which reads its pages from the environment and is skipped without them.

@Suite("The measured run's entry", .serialized)
struct MeasuredRunTests {

    /// A Letter page holding a ragged six-line paragraph, Times 11 pt, with
    /// `value` in its second line and words after it on that line and below.
    static func paragraphPage(value: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("measured_\(UUID().uuidString).pdf")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        let font = CTFontCreateWithName("Times New Roman" as CFString, 11, nil)
        let lines = [
            "The statement below was prepared for the holder named in the second line of this notice and for",
            "the office that keeps it: \(value) opened the account on the date shown and signed every",
            "page of the agreement in the presence of the branch officer, who kept a copy for the records",
            "of the office and sent another to the address on file before the end of the following month,",
            "as the terms of the account require for every holder who opens an account of this kind with",
            "the office, and as the notice on the back of this page explains in more detail for the reader.",
        ]
        for (i, text) in lines.enumerated() {
            let line = CTLineCreateWithAttributedString(NSAttributedString(
                string: text, attributes: [kCTFontAttributeName as NSAttributedString.Key: font]))
            context.textPosition = CGPoint(x: 72, y: 700 - CGFloat(i) * 13)
            CTLineDraw(line, context)
        }
        context.endPDFPage()
        context.closePDF()
        return url
    }

    static let values = ["Quentin Ashby", "Marlowe Prestwick"]

    static func pages() throws -> [MeasuredRun.Page] {
        try values.enumerated().map { index, value in
            MeasuredRun.Page(source: try paragraphPage(value: value), index: index, kind: "roster", value: value)
        }
    }

    static func scratch() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("measured_run_\(UUID().uuidString)")
    }

    @Test("Under the switch's policy the on arm widens the value's box and the off arm does not")
    func switchPolicyWidensOnlyTheOnArm() async throws {
        let pages = try Self.pages()
        let directory = Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let rows = try await MeasuredRun.run(pages: pages, source: .switchPolicy,
                                             selection: .valueCharacters, dpi: 150, directory: directory)
        #expect(rows.map(\.arm) == [.off, .on, .off, .on])
        #expect(rows.map(\.page.index) == [0, 0, 1, 1])
        for row in rows {
            #expect(row.placed == 1, "page \(row.page.index) \(row.arm): \(row.placed) regions placed")
            #expect(row.regionKinds == [.placedFromTextAnchored], "page \(row.page.index): \(row.regionKinds)")
            #expect(row.exportOK, "page \(row.page.index) \(row.arm): \(row.error)")
            #expect(row.exportSHA256?.count == 64)
            #expect(row.notRead == nil)
            let plan = try #require(row.plan)
            #expect(plan.boxes.count == 1)
            switch row.arm {
            case .off: #expect(plan.boxes.allSatisfy { $0.treatment == .notAsked }, "off: \(plan.boxes.map(\.treatment))")
            case .on: #expect(row.widened == 1, "on: \(plan.boxes.map(\.treatment))")
            }
        }
        #expect(MeasuredRun.unreadable(rows: rows, expected: 4).isEmpty)
    }

    @Test("Under the plan as placed the two arms give one plan, and the run is unreadable")
    func asPlacedArmsAreEqualAndUnreadable() async throws {
        for page in try Self.pages() {
            let document = try #require(PDFDocument(url: page.source))
            let first = try #require(document.page(at: 0))
            let regions = await MeasuredRun.placedRegions(value: page.value, in: document)
            #expect(regions.count == 1)
            let words = try #require(try await MeasuredRun.words(of: page.source))
            let off = try MeasuredRun.plan(page: first, words: words, regions: regions, arm: .off, source: .asPlaced).get()
            let on = try MeasuredRun.plan(page: first, words: words, regions: regions, arm: .on, source: .asPlaced).get()
            #expect(off == on)
            #expect(on.boxes.allSatisfy { $0.treatment == .notAsked })
        }
        let directory = Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let rows = try await MeasuredRun.run(pages: Array(try Self.pages().prefix(1)), source: .asPlaced, dpi: 96, directory: directory)
        #expect(MeasuredRun.unreadable(rows: rows, expected: 2) == ["no widened box in the on arm"])
    }

    @Test("With the product's selection a Search box is read from its line, and the switch widens it")
    func productSelectionWidens() async throws {
        let page = try #require(try Self.pages().first)
        let document = try #require(PDFDocument(url: page.source))
        let first = try #require(document.page(at: 0))
        let regions = await MeasuredRun.placedRegions(value: page.value, in: document)
        let words = try #require(try await MeasuredRun.words(of: page.source))
        let selected = MeasuredRun.selected(.product, regions: regions, value: page.value, text: first.string ?? "")
        #expect(selected == nil)
        let text = try #require(first.string)
        #expect(regions.map(\.pageCharacters) == [Range((text as NSString).range(of: page.value))])
        let plan = try MeasuredRun.plan(page: first, words: words, regions: regions, selected: selected, arm: .on,
                                        source: .switchPolicy).get()
        #expect(plan.boxes.map(\.treatment) == [.widened])
    }

    @Test("The entry reads the run capture's plan source unless a case hands it another")
    func entryReadsTheCapturesSource() {
        #expect(MeasuredRun.defaultSource == RunRecord.planSource)
    }

    @Test("A short, long or empty run is unreadable")
    func countsAreAsserted() async throws {
        let directory = Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let rows = try await MeasuredRun.run(pages: Array(try Self.pages().prefix(1)), source: .switchPolicy,
                                             selection: .valueCharacters, dpi: 96, directory: directory)
        #expect(rows.count == 2)
        #expect(MeasuredRun.unreadable(rows: rows, expected: 2).isEmpty)
        #expect(MeasuredRun.unreadable(rows: rows, expected: 3) == ["rows 2 of 3"])
        #expect(MeasuredRun.unreadable(rows: rows, expected: 1) == ["rows 2 of 1"])
        #expect(MeasuredRun.unreadable(rows: Array(rows.suffix(1)), expected: 1) == ["arms differ in rows"])
        #expect(MeasuredRun.unreadable(rows: [], expected: 0) == ["rows 0 of 0", "no widened box in the on arm"])
    }

    @Test("A page whose content reaches a picture is not read and gets no plan")
    func pictureIsNotRead() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("measured_picture_\(UUID().uuidString).pdf")
        try TestFixtures.sparseHeaderScannedPagePDF(header: "Holder", body: "QUENTIN").write(to: url)
        let page = MeasuredRun.Page(source: url, index: 0, kind: "roster", value: "Holder")
        let first = try #require(PDFDocument(url: url)?.page(at: 0))
        #expect(MeasuredRun.planFacts(of: first) == nil)
        let directory = Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let rows = try await MeasuredRun.run(pages: [page], source: .switchPolicy, dpi: 96, directory: directory)
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.notRead == .facts && $0.plan == nil && !$0.exportOK })
        let typed = try #require(PDFDocument(url: try Self.paragraphPage(value: "Quentin Ashby"))?.page(at: 0))
        #expect(MeasuredRun.planFacts(of: typed) == PageTextFacts(showsInvisibleText: false, carriesPageScaleImage: false))
    }

    @Test("Two runs of one page give the same boxes")
    func plansRepeat() async throws {
        let page = try #require(try Self.pages().last)
        let document = try #require(PDFDocument(url: page.source))
        let first = try #require(document.page(at: 0))
        var seen: [[[String: Any]]] = []
        for _ in 0..<2 {
            let regions = await MeasuredRun.placedRegions(value: page.value, in: document)
            let words = try #require(try await MeasuredRun.words(of: page.source))
            let text = try #require(first.string)
            let selected = MeasuredRun.selected(.valueCharacters, regions: regions, value: page.value, text: text)
            #expect(selected?.count == 1)
            let plan = try MeasuredRun.plan(page: first, words: words, regions: regions, selected: selected, arm: .on,
                                            source: .switchPolicy).get()
            #expect(plan.boxes.map(\.treatment) == [.widened])
            seen.append(plan.boxes.map(MeasuredRun.Row.boxJSON))
        }
        let encoded = try seen.map { try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }
        #expect(encoded[0] == encoded[1])
    }

    // MARK: - The run

    static let environment = ProcessInfo.processInfo.environment

    /// MEASURED_RUN_PAGES: one JSON object a line, {"src", "index", "kind",
    /// "value"}. MEASURED_RUN_OUT: a directory that does not exist yet; the
    /// rows go to `measured.jsonl` in it and the exports beside them.
    /// MEASURED_RUN_EXPECT: the rows expected (two a page). Optional:
    /// MEASURED_RUN_FROM and MEASURED_RUN_TO (a line range), MEASURED_RUN_DPI
    /// (300), MEASURED_RUN_LAUNCH (a tag written on every row),
    /// MEASURED_RUN_ENGINE (the commit, written on every row).
    @Test("The measured run: one row per page per arm (needs MEASURED_RUN_PAGES)",
          .enabled(if: environment["MEASURED_RUN_PAGES"] != nil))
    func measuredRun() async throws {
        let env = Self.environment
        let list = try #require(env["MEASURED_RUN_PAGES"])
        let out = URL(fileURLWithPath: try #require(env["MEASURED_RUN_OUT"]))
        let expected = try #require(env["MEASURED_RUN_EXPECT"].flatMap(Int.init))
        try #require(!FileManager.default.fileExists(atPath: out.path), "the output directory exists already")
        let lines = try String(contentsOfFile: list, encoding: .utf8).split(whereSeparator: \.isNewline)
        let from = env["MEASURED_RUN_FROM"].flatMap(Int.init) ?? 0
        let to = env["MEASURED_RUN_TO"].flatMap(Int.init) ?? lines.count
        try #require(from >= 0 && from < to && to <= lines.count, "range \(from)..<\(to) of \(lines.count)")
        let pages: [MeasuredRun.Page] = try lines[from..<to].map { line in
            let object = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            return MeasuredRun.Page(source: URL(fileURLWithPath: try #require(object["src"] as? String)),
                                    index: try #require(object["index"] as? Int),
                                    kind: try #require(object["kind"] as? String),
                                    value: try #require(object["value"] as? String))
        }
        let launch = env["MEASURED_RUN_LAUNCH"] ?? ""
        let facts = ["engine_sha": env["MEASURED_RUN_ENGINE"] ?? "",
                     "host_os": ProcessInfo.processInfo.operatingSystemVersionString,
                     "plan_source": MeasuredRun.defaultSource.rawValue]
        let rows = try await MeasuredRun.run(pages: pages, dpi: env["MEASURED_RUN_DPI"].flatMap(Int.init) ?? 300,
                                             directory: out.appendingPathComponent("exports"))
        var text = ""
        for (offset, row) in rows.enumerated() {
            let object = row.json(row: from + offset / 2, launch: launch, facts: facts)
            text += String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self) + "\n"
        }
        let jsonl = out.appendingPathComponent("measured.jsonl")
        #expect(FileManager.default.createFile(atPath: jsonl.path, contents: Data(text.utf8)))
        let unreadable = MeasuredRun.unreadable(rows: rows, expected: expected)
        print("MEASURED rows=\(rows.count) expected=\(expected) widened_on=\(rows.filter { $0.arm == .on }.map(\.widened).reduce(0, +)) "
              + "not_read=\(rows.filter { $0.notRead != nil }.count) unreadable=\(unreadable.isEmpty ? "none" : unreadable.joined(separator: "; "))")
        #expect(unreadable.isEmpty, "\(unreadable)")
    }
}
