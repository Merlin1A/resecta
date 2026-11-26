import CoreGraphics
import CryptoKit
import Foundation
import PDFKit
@testable import RedactionEngine
import RedactionCore

// The measured run's entry: for one-page documents and the value typed on
// each, the value is searched as the app searches it, its regions are made by
// the one maker the app uses, the page's plan is made under the plan source
// with the switch off and on, and each arm is exported through the tests'
// production page loop. One row per page per arm. The entry writes rows and
// decides nothing; the judge reads them outside the repository.

enum MeasuredRun {

    /// The two arms: the switch that widens boxes off, and on.
    enum Arm: String, CaseIterable, Sendable {
        case off
        case on
    }

    /// One page of a run: a one-page document and the value typed on it.
    struct Page: Sendable, Equatable {
        /// The document's file.
        let source: URL
        /// The page's place in its set (the roster number, or a control's).
        let index: Int
        /// "roster", "nc1" or "nc2": the set the page belongs to.
        let kind: String
        /// The value typed into Search, exactly.
        let value: String
    }

    /// Why a page was given no plan.
    enum NotRead: String, Sendable, Equatable {
        /// The document could not be opened, or has no first page.
        case unopened
        /// The page's sides cannot be read as whole sixty-fourths.
        case sides
        /// The page shows invisible text or carries a picture, so the
        /// plan's page facts would be a guess.
        case facts
    }

    /// What the plan of one arm reads.
    struct ArmPlan: Sendable, Equatable {
        /// The regions Search placed, before admission.
        let placed: [RedactionRegion]
        /// The plan, or why there is none.
        let plan: Result<PaintPlan, NotReadError>
    }

    struct NotReadError: Error, Equatable, Sendable {
        let reason: NotRead
    }

    /// The source the entry reads unless a case hands it another: the one
    /// constant the run capture reads.
    static let defaultSource: PlanSource = RunRecord.planSource

    /// Where an anchored region's selected characters come from.
    enum Selection: String, Sendable {
        /// What the product hands the plan: the characters each region's
        /// match selected, carried with the region (`RunRecord.planRegions`).
        case product
        /// Handed in by a case: the value's own characters in the page's
        /// string, one occurrence for each region, in reading order.
        case valueCharacters
    }

    /// The selected characters a case hands in for each region, or nil for
    /// the product's own.
    static func selected(_ selection: Selection, regions: [RedactionRegion], value: String, text: String) -> [UUID: Set<Int>]? {
        guard selection == .valueCharacters else { return nil }
        guard !value.isEmpty else { return [:] }
        let string = text as NSString
        var ranges: [Range<Int>] = []
        var from = 0
        while from < string.length {
            let hit = string.range(of: value, options: [], range: NSRange(location: from, length: string.length - from))
            guard hit.location != NSNotFound else { break }
            ranges.append(hit.location..<(hit.location + hit.length))
            from = hit.location + max(hit.length, 1)
        }
        guard ranges.count == regions.count else { return [:] }
        let ordered = regions.sorted { a, b in
            a.normalizedRect.maxY != b.normalizedRect.maxY ? a.normalizedRect.maxY > b.normalizedRect.maxY
                : a.normalizedRect.minX < b.normalizedRect.minX
        }
        return Dictionary(uniqueKeysWithValues: zip(ordered, ranges).map { region, range in
            (region.id, WordSelection.characters([range], in: text).offsets)
        })
    }

    // MARK: - The page's facts

    /// The plan's facts for a page the entry reads: neither invisible text
    /// nor a page-scale picture. A page whose content shows invisible text
    /// or reaches a picture is not read (nil): its facts are not made here.
    static func planFacts(of page: PDFPage) -> PageTextFacts? {
        let facts = PageContentFacts.read(page.pageRef)
        guard !facts.showsInvisibleText, !facts.reachesImage, !facts.drawsInlineImage else { return nil }
        return PageTextFacts(showsInvisibleText: false, carriesPageScaleImage: false)
    }

    // MARK: - Search, regions, plan

    /// The value searched as the app's Search sheet searches a typed value
    /// (its default options), and each result on the first page made into a
    /// region by the one maker the app uses.
    static func placedRegions(value: String, in document: PDFDocument) async -> [RedactionRegion] {
        var regions: [RedactionRegion] = []
        let stream = DocumentSearcher().search(SendablePDFDocument(document), mode: .text(value, options: SearchOptions()),
                                               progress: { _, _ in })
        for await result in stream where result.pageIndex == 0 {
            regions.append(RedactionRegion(placing: result))
        }
        return regions
    }

    /// The page's sides as whole sixty-fourths, in the frame the page is
    /// rasterised in: a page turned a quarter has its sides swapped.
    static func sides(of page: PDFPage) -> (width: Int, height: Int)? {
        let crop = page.bounds(for: .cropBox).size
        let turned = ((page.rotation % 360) + 360) % 180 != 0
        guard let width = PixelPlan.sixtyFourths(ofSide: Double(turned ? crop.height : crop.width)),
              let height = PixelPlan.sixtyFourths(ofSide: Double(turned ? crop.width : crop.height)) else { return nil }
        return (width, height)
    }

    /// The first page's words from the engine's one reader, read on a page
    /// opened here so it can be handed to the reader.
    static func words(of url: URL) async throws -> PageWords? {
        guard let page = PDFDocument(url: url)?.page(at: 0) else { return nil }
        return try await PageWordReader.words(on: page)
    }

    /// The plan of one arm: the admitted regions made into the plan's
    /// regions by the run's own maker over the page's string, the page's
    /// words, and the facts above. A case may hand in the selected
    /// characters in place of the product's.
    static func plan(page: PDFPage, words: PageWords, regions: [RedactionRegion], selected: [UUID: Set<Int>]? = nil,
                     arm: Arm, source: PlanSource) -> Result<PaintPlan, NotReadError> {
        guard let sides = sides(of: page) else { return .failure(NotReadError(reason: .sides)) }
        guard let facts = planFacts(of: page) else { return .failure(NotReadError(reason: .facts)) }
        let admitted = regions.filter { RedactionRegion.isAdmitted(normalizedRect: $0.normalizedRect) }
        var planRegions = RunRecord.planRegions(admitted.map(RunRecord.DrawnRegion.init(region:)), text: page.string ?? "")
        if let selected {
            planRegions = planRegions.map { var region = $0; region.selected = selected[region.id] ?? []; return region }
        }
        let choice = RunRecord.planChoice(source: source, switchOn: arm == .on)
        return .success(PaintPlan.make(regions: planRegions, words: words, text: page.string ?? "", facts: facts,
                                       widthSixtyFourths: sides.width, heightSixtyFourths: sides.height,
                                       policy: .release, source: choice.source, switchOn: choice.switchOn).plan)
    }

    // MARK: - Export

    /// One arm's export through the tests' production page loop, Secure, at
    /// `dpi`, the regions as the product paints them today.
    static func export(document: PDFDocument, regions: [RedactionRegion], dpi: Int, to url: URL) async throws {
        guard let page = document.page(at: 0) else { throw NotReadError(reason: .unopened) }
        let data = PDFPageData(
            page: page, pageIndex: 0, regions: regions, fillColor: .black, targetDPI: dpi,
            pipelineMode: .secureRasterization, rotation: page.rotation, hasHiddenOCG: false,
            cropBoxBounds: page.bounds(for: .cropBox), cgPage: page.pageRef, hasText: false)
        _ = try await ProductionPageLoop.runRedaction(pages: [data], outputURL: url, dpiCap: dpi)
    }

    // MARK: - Rows

    /// One row: a page in one arm.
    struct Row: Sendable, Equatable {
        let page: Page
        let arm: Arm
        let placed: Int
        let selection: Selection
        let regionKinds: [RegionKind]
        let plan: PaintPlan?
        let notRead: NotRead?
        let exportPath: String
        let exportOK: Bool
        let exportSHA256: String?
        let error: String
        let seconds: Double

        /// Boxes the switch widened.
        var widened: Int { plan?.boxes.filter { $0.treatment == .widened }.count ?? 0 }

        /// The row as one JSON object, keys sorted: what the bench's hasher
        /// and cell writer read (`row`, `kind`, `index`, `arm`, `launch`,
        /// `export`, `export_ok`, `error`, `seconds`), and the plan's boxes in
        /// sixty-fourths.
        func json(row: Int, launch: String, facts: [String: String]) -> [String: Any] {
            var out: [String: Any] = facts
            out.merge(["order": "measured", "src": page.source.path, "row": row, "kind": page.kind, "index": page.index,
                       "value_chars": page.value.count, "arm": arm.rawValue, "launch": launch, "export": exportPath,
                       "export_ok": exportOK, "error": error, "seconds": seconds, "placed": placed,
                       "region_kinds": regionKinds.map(\.rawValue), "widened": widened,
                       "selection": selection.rawValue]) { _, new in new }
            if let sha = exportSHA256 { out["export_file_sha256"] = sha }
            if let notRead { out["not_read"] = notRead.rawValue }
            if let plan {
                out["plan"] = ["width64": plan.widthSixtyFourths, "height64": plan.heightSixtyFourths,
                               "boxes": plan.boxes.map(Self.boxJSON)] as [String: Any]
            }
            return out
        }

        static func boxJSON(_ box: PaintedBox) -> [String: Any] {
            func r(_ rect: PageRect64) -> [Int] { [rect.minX, rect.minY, rect.maxX, rect.maxY] }
            return ["regions": box.regionIDs.count, "inner": r(box.inner), "paint": r(box.paint), "tight": r(box.tight),
                    "treatment": treatmentName(box.treatment), "exposure": box.exposure.rawValue]
        }

        static func treatmentName(_ treatment: SwitchTreatment) -> String {
            switch treatment {
            case .notAsked: "not asked"
            case .widened: "widened"
            case .alreadyAsWide: "already as wide"
            case .couldNotWiden(let reason): "could not widen: \(reason.rawValue)"
            case .fellBack: "fell back"
            }
        }
    }

    /// Runs `pages` in order, both arms each, exporting into `directory`.
    static func run(pages: [Page], source: PlanSource = defaultSource, selection: Selection = .product,
                    dpi: Int = 300, directory: URL) async throws -> [Row] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let clock = ContinuousClock()
        var rows: [Row] = []
        for page in pages {
            let document = PDFDocument(url: page.source)
            var regions: [RedactionRegion] = []
            if let document { regions = await placedRegions(value: page.value, in: document) }
            let words = document == nil ? nil : try await Self.words(of: page.source)
            let selected = Self.selected(selection, regions: regions, value: page.value,
                                         text: document?.page(at: 0)?.string ?? "")
            for arm in Arm.allCases {
                let url = directory.appendingPathComponent("\(page.kind)-\(String(format: "%04d", page.index))-\(arm.rawValue).pdf")
                let start = clock.now
                var plan: PaintPlan?
                var notRead: NotRead?
                var ok = false
                var message = ""
                if let document, let first = document.page(at: 0), let words {
                    switch Self.plan(page: first, words: words, regions: regions, selected: selected, arm: arm, source: source) {
                    case .success(let made): plan = made
                    case .failure(let refused): notRead = refused.reason
                    }
                    if notRead == nil {
                        do {
                            try await export(document: document, regions: regions, dpi: dpi, to: url)
                            ok = true
                        } catch { message = "\(error)" } // LegalPhrases:safe (Swift keyword)
                    }
                } else {
                    notRead = .unopened
                }
                let elapsed = clock.now - start
                rows.append(Row(page: page, arm: arm, placed: regions.count, selection: selection, regionKinds: regions.map { RegionKind(of: $0) },
                                plan: plan, notRead: notRead, exportPath: url.path, exportOK: ok,
                                exportSHA256: ok ? fileSHA256(url) : nil, error: message,
                                seconds: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18))
            }
        }
        return rows
    }

    static func fileSHA256(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - The run's own reading

    /// What makes a run unreadable, or none. A short or empty run, or one
    /// with more rows than expected, is unreadable. A run whose "on" arm
    /// widened no box on any page that was read is unreadable: a build whose
    /// plan source is "as placed" reads so, and so would a run whose regions
    /// all read as drawn by hand. A box widened in the "off" arm is a fault.
    static func unreadable(rows: [Row], expected: Int) -> [String] {
        var reasons: [String] = []
        if rows.isEmpty || rows.count != expected { reasons.append("rows \(rows.count) of \(expected)") }
        let byArm = Dictionary(grouping: rows, by: \.arm)
        if (byArm[.off]?.count ?? 0) != (byArm[.on]?.count ?? 0) { reasons.append("arms differ in rows") }
        if (byArm[.on] ?? []).allSatisfy({ $0.widened == 0 }) { reasons.append("no widened box in the on arm") }
        if (byArm[.off] ?? []).contains(where: { $0.widened > 0 }) { reasons.append("a widened box in the off arm") }
        return reasons
    }
}
