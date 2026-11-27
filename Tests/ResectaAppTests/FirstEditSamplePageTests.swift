import CoreGraphics
import CryptoKit
import Foundation
import PDFKit
import Testing
import UIKit
@testable import RedactionEngine
@testable import ResectaApp

// The first edit's gesture on the bundled sample statement's first page,
// through the page's real plan. The boxes are placed as the app places them
// (Search and Scan results, through `RedactionRegion(placing:)`), and each
// box's start is the one the coordinator's reader gives: the page's plan made
// from the stored regions and the page's words. The case table's rows on
// this page were made from another reading of its words, and their joins
// from a model of the plan, so the table's starts are not the oracle here:
// each row's box is held to be where the table puts it, and its gesture to
// move the real start as the row moves the table's.

@Suite("First edit on the sample page")
@MainActor
struct FirstEditSamplePageTests {
    typealias G = FirstEditGestureTests
    typealias Rect64 = FirstEditGestureTests.Rect64

    static let sampleSHA256 = "992ca0543eb1a2eaab8d8dba0a4ad4b8339cf95b804a0347ab1b0987ce18fa20"

    static func samplePDF() throws -> PDFDocument {
        let url = try #require(Bundle(for: AppCoordinator.self).url(forResource: "SampleDocument", withExtension: "pdf"))
        let data = try Data(contentsOf: url)
        #expect(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == Self.sampleSHA256)
        let pdf = try #require(PDFDocument(data: data))
        // The canvas's test geometry is the page's own.
        let page = try #require(pdf.page(at: 0))
        #expect(page.bounds(for: .cropBox) == CGRect(origin: .zero, size: G.pageSize) && page.rotation == 0)
        return pdf
    }

    /// The document with its first page's read held, as the run's entry
    /// hands it.
    static func documentState(_ pdf: PDFDocument) async throws -> DocumentState {
        let documentState = DocumentState()
        documentState.sourceDocument = pdf
        await documentState.fillPageReads(for: [0])
        try #require(documentState.pageReads[0] != nil, "the first page's read is held")
        return documentState
    }

    /// A coordinator on the document, with the app's default settings at
    /// the chosen quality 300.
    static func coordinator(_ documentState: DocumentState) throws -> PDFViewCoordinator {
        let suite = "FirstEditSamplePageTests"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsState(defaults: defaults)
        settings.exportDPI = 300
        let coordinator = PDFViewCoordinator()
        coordinator.documentState = documentState
        coordinator.settingsState = settings
        return coordinator
    }

    /// How a row's boxes are made on the page.
    enum Recipe: Hashable {
        /// Search "Balance", Search "Hartwell", then Scan over every kind.
        case statement
        /// Search "Delia R. Hartwell".
        case name
        /// Search "Personal", then Search "Checking".
        case pair
        /// One box drawn by hand at the row's rectangle.
        case hand
    }

    static func recipe(_ id: String) -> Recipe {
        if id.hasPrefix("J-B-sample-boxes-") { return .statement }
        if id.hasPrefix("J-B-personal-") || id.hasPrefix("J-B-checking-") { return .pair }
        if id == "B-group-move-hand" { return .hand }
        return .name
    }

    static func modes(_ recipe: Recipe) -> [SearchMode] {
        switch recipe {
        case .statement:
            [.text("Balance", options: SearchOptions()), .text("Hartwell", options: SearchOptions()),
             .piiScan(categories: Set(PIICategory.allCases), options: SearchOptions())]
        case .name: [.text("Delia R. Hartwell", options: SearchOptions())]
        case .pair: [.text("Personal", options: SearchOptions()), .text("Checking", options: SearchOptions())]
        case .hand: []
        }
    }

    /// The first page's results of `modes`, each placed as the app places one.
    static func placed(_ pdf: PDFDocument, _ modes: [SearchMode]) async -> [RedactionRegion] {
        var regions: [RedactionRegion] = []
        for mode in modes {
            for await result in DocumentSearcher().search(SendablePDFDocument(pdf), mode: mode, progress: { _, _ in })
            where result.pageIndex == 0 {
                regions.append(RedactionRegion(placing: result))
            }
        }
        return regions
    }

    static func distance(_ a: [Int], _ b: [Int]) -> Int { zip(a, b).map { abs($0 - $1) }.max() ?? .max }

    /// A box's rectangle as the plan reads a share, and as the table and the
    /// rectangles below record one: each low side down and each high side up
    /// to whole sixty-fourths (`PageRect64(share:)`). The canvas's own
    /// sixty-fourths round to the nearest, so the two can differ by one on a
    /// side.
    static func readBack(_ share: CGRect) -> [Int] {
        let w = G.pageSize.width * 64, h = G.pageSize.height * 64
        return [Int((share.minX * w).rounded(.down)), Int((share.minY * h).rounded(.down)),
                Int((share.maxX * w).rounded(.up)), Int((share.maxY * h).rounded(.up))]
    }

    /// How far a side of a box the app places may lie from the table's, in
    /// sixty-fourths, each read as the plan reads a share: the table's
    /// rectangles were read from the page on the Mac, and the simulator's
    /// PDFKit puts a few sides less than a sixty-fourth away.
    static let readings = 1

    /// The boxes of `regions` at the recorded rectangle `r`, within
    /// `readings` on each side.
    static func at(_ r: Rect64, in regions: [RedactionRegion]) -> [RedactionRegion] {
        regions.filter { distance(readBack($0.normalizedRect), r.edges) <= readings }
    }

    /// The boxes of `regions` that share height with `r`, read as the plan
    /// reads them, left to right: what a failure names when no box is at `r`.
    static func onTheLine(_ r: Rect64, _ regions: [RedactionRegion]) -> [[Int]] {
        regions.map { readBack($0.normalizedRect) }.filter { $0[1] < r.maxY && r.minY < $0[3] }
            .sorted { $0.lexicographicallyPrecedes($1) }
    }

    /// How far a side of a moved box may land from where the row moves it,
    /// in sixty-fourths: a side that sits on a half sixty-fourth, carried
    /// through the canvas and back, can round to either side of it.
    static let carried = 1

    /// The row whose box is a found box at the page's top-left corner, over
    /// no text: no search places it, so it runs on the table's start only.
    static let placedByNoSearch = ["B-paint-past-the-page"]

    /// The rows whose box the real plan holds alone, in a plan box of its
    /// own, so it starts by clause 1 from its whole paint, where the table's
    /// model joined it to a wide Address box.
    static let aloneOnThePage = ["J-B-sample-boxes-pobox-nudge-right", "J-B-sample-boxes-account-nudge-right", "J-B-sample-boxes-hartwell-nudge-right",
                                 "J-B-sample-boxes-sablebrook-nudge-right", "J-B-sample-boxes-pobox-right-out-2"]

    @Test("Each gesture row on the sample page, through the page's real plan, moves the real start as the row moves its own")
    func everySampleRowThroughTheRealPlan() async throws {
        let pdf = try Self.samplePDF()
        let documentState = try await Self.documentState(pdf)
        let rows = try G.table().cases.filter { $0.inputs.text == "sample-p1" }
        #expect(rows.count == 22)
        #expect(Set(rows.map(\.id)).isSuperset(of: Self.aloneOnThePage + Self.placedByNoSearch))
        var placed: [Recipe: [RedactionRegion]] = [:]
        for row in rows where !Self.placedByNoSearch.contains(row.id) {
            let box = try #require(row.inputs.box), gesture = try #require(row.inputs.gesture)
            // A second resize runs after the first row's edit of the same box.
            let first = row.id == "B-second-resize" ? rows.first { $0.id == "B-right-out-5" } : nil
            let asPlaced = (first?.inputs.box ?? box).rect
            let recipe = Self.recipe(row.id)
            var regions: [RedactionRegion]
            let id: UUID
            if recipe == .hand {
                let hand = G.hand(G.share(asPlaced))
                regions = [hand]
                id = hand.id
            } else {
                if placed[recipe] == nil { placed[recipe] = await Self.placed(pdf, Self.modes(recipe)) }
                regions = try #require(placed[recipe])
                let near = try #require(regions.min {
                    Self.distance(Self.readBack($0.normalizedRect), asPlaced.edges)
                        < Self.distance(Self.readBack($1.normalizedRect), asPlaced.edges)
                })
                #expect(Self.distance(Self.readBack(near.normalizedRect), asPlaced.edges) <= Self.readings,
                        "\(row.id): the app places the box at \(Self.readBack(near.normalizedRect)), the table at \(asPlaced)")
                #expect(near.textAnchored)
                id = near.id
            }
            var selected: Set<UUID> = [id]
            if row.inputs.group == true {
                let partner = G.hand(G.partner(clearOf: G.share(asPlaced)))
                regions.append(partner)
                selected.insert(partner.id)
            }
            let c = try G().mount(regions, selected: selected, starts: [:], coordinator: try Self.coordinator(documentState))
            c.overlay.startReader = c.coordinator.firstEditStartReader(pageIndex: 0)
            let start = c.coordinator.firstEditStartReader(pageIndex: 0)(id)
            if recipe == .hand {
                #expect(start == nil, "\(row.id): a box drawn by hand has no start")
            } else {
                try #require(start != nil, "\(row.id): the real plan gives the found box a start")
            }
            if Self.aloneOnThePage.contains(row.id) {
                #expect(start?.clause == 1, "\(row.id): the real plan's clause \(String(describing: start?.clause))")
            }
            if let first {
                try G().perform(try #require(first.inputs.gesture), on: id, in: c, group: false, cancel: false)
            }
            let before = try #require(c.stored(id))
            try G().perform(gesture, on: id, in: c, group: row.inputs.group == true, cancel: row.inputs.then == "cancel")
            if row.inputs.then == "undo" { c.undo.undo() }
            let now = try #require(c.stored(id))
            // Where the row's box ends: back where it was, for a gesture that
            // writes nothing or is undone; moved as the row moves the box, for
            // one that does, from the real start on a first edit and from the
            // box as it stands on any other.
            let unmoved = row.expected.written == false || row.inputs.then == "undo"
            let expected: [Int]
            if unmoved {
                expected = G.sixtyFourths(before.normalizedRect)
            } else if before.textAnchored, let real = start, let tableStart = row.expected.start {
                expected = zip(G.sixtyFourths(real.share), zip(row.expected.rect.edges, tableStart.edges)).map {
                    $0 + $1.0 - $1.1
                }
            } else {
                expected = zip(G.sixtyFourths(before.normalizedRect), zip(row.expected.rect.edges, box.rect.edges)).map {
                    $0 + $1.0 - $1.1
                }
            }
            #expect(unmoved ? G.sixtyFourths(now.normalizedRect) == expected
                            : Self.distance(G.sixtyFourths(now.normalizedRect), expected) <= Self.carried,
                    "\(row.id): the stored box is \(G.sixtyFourths(now.normalizedRect)), not \(expected)")
            if let anchored = row.expected.anchored {
                #expect(now.textAnchored == anchored, "\(row.id): anchored \(now.textAnchored)")
            }
            if let written = row.expected.written {
                #expect(c.undo.canUndo == written, "\(row.id): a step recorded \(c.undo.canUndo)")
            }
            withExtendedLifetime(c) {}
        }
    }

    // MARK: - What the real plan joins

    /// The two wide Address boxes, which stand for no single range of the
    /// page's characters.
    static let characterless = [Rect64(minX: 2304, minY: 47035, maxX: 36864, maxY: 48662),
                                Rect64(minX: 3456, minY: 39773, maxX: 36225, maxY: 42251)]

    /// The boxes the real plan joins, with each one's clause: "hartwell"
    /// (Search) inside "d.hartwell@example.net" (Scan), and on each of two
    /// lines "DELIA" beside "HARTWELL", which Search and Scan place at one
    /// rectangle.
    static let joined: [(rect: Rect64, clause: Int)] = [
        (Rect64(minX: 30215, minY: 37628, maxX: 32292, maxY: 38287), 2),
        (Rect64(minX: 29732, minY: 37628, maxX: 36012, maxY: 38287), 3),
        (Rect64(minX: 7008, minY: 25404, maxX: 8558, maxY: 26063), 3),
        (Rect64(minX: 8703, minY: 25404, maxX: 11663, maxY: 26063), 3),
        (Rect64(minX: 7008, minY: 23900, maxX: 8558, maxY: 24559), 3),
        (Rect64(minX: 8703, minY: 23900, maxX: 11663, maxY: 24559), 3),
    ]

    static func stored(_ regions: [RedactionRegion], on coordinator: PDFViewCoordinator) -> RedactionState {
        let state = RedactionState()
        for r in regions { state.addRegion(r, page: 0, undoManager: nil) }
        coordinator.redactionState = state
        return state
    }

    @Test("The real plan holds each box beside a wide Address box alone, as that box holds no characters, and joins the boxes it reads")
    func theRealPlanJoinsOnlyWhatItReads() async throws {
        let pdf = try Self.samplePDF()
        let coordinator = try Self.coordinator(try await Self.documentState(pdf))
        let regions = await Self.placed(pdf, Self.modes(.statement))
        // Every box the recipe places is read from the text layer. How many
        // Scan places is the system's name tagger's, so the count is not held
        // here; the boxes the rows and the joins name are.
        #expect(!regions.isEmpty && regions.allSatisfy(\.textAnchored))
        func at(_ r: Rect64) -> [RedactionRegion] { Self.at(r, in: regions) }
        let none = regions.filter { $0.pageCharacters == nil }.map { Self.readBack($0.normalizedRect) }
        let recorded = Self.characterless.map(\.edges).sorted { $0.lexicographicallyPrecedes($1) }
        #expect(none.count == recorded.count
                && zip(none.sorted { $0.lexicographicallyPrecedes($1) }, recorded).allSatisfy {
                    Self.distance($0, $1) <= Self.readings
                }, "the boxes with no characters: \(none)")
        _ = Self.stored(regions, on: coordinator)
        let plan = try #require(coordinator.planAtRead(pageIndex: 0))
        let reader = coordinator.firstEditStartReader(pageIndex: 0)
        let rows = try G.table().cases.filter { Self.aloneOnThePage.contains($0.id) }
        #expect(rows.count == Self.aloneOnThePage.count)
        for row in rows {
            let rect = try #require(row.inputs.box).rect
            let matching = at(rect)
            try #require(!matching.isEmpty, "\(row.id): a box at \(rect); on its line \(Self.onTheLine(rect, regions))")
            for region in matching {
                #expect(reader(region.id)?.clause == 1, "\(row.id)")
                #expect(plan.boxes.first { $0.regionIDs.contains(region.id) }?.regionIDs == [region.id], "\(row.id): alone")
            }
        }
        for (rect, clause) in Self.joined {
            let matching = at(rect)
            try #require(!matching.isEmpty, "a box at \(rect); on its line \(Self.onTheLine(rect, regions))")
            for region in matching {
                #expect(reader(region.id)?.clause == clause, "\(rect): clause \(String(describing: reader(region.id)?.clause))")
                #expect((plan.boxes.first { $0.regionIDs.contains(region.id) }?.regionIDs.count ?? 0) > 1, "\(rect): joined")
            }
        }
        // Search and Scan place "HARTWELL" twice at one rectangle on each line.
        #expect(at(Self.joined[3].rect).count == 2 && at(Self.joined[5].rect).count == 2)
    }

    // MARK: - A plan of the page as it is

    /// The box `id` moved one point right, as a row's `*-nudge-right` moves it.
    func nudgeRight(_ id: UUID, in c: G.Canvas) throws {
        let gesture = G.Gesture(type: "move", dx: 64, dy: 0, dMinX: nil, dMaxX: nil, dMinY: nil, dMaxY: nil)
        try G().perform(gesture, on: id, in: c, group: false, cancel: false)
    }

    @Test("With the kept plan older than the page, a box whose holder is gone starts from its whole paint, not its own rectangle")
    func aHolderGoneBeforeTheDrawingPass() async throws {
        let pdf = try Self.samplePDF()
        let coordinator = try Self.coordinator(try await Self.documentState(pdf))
        let regions = await Self.placed(pdf, Self.modes(.statement))
        func at(_ r: Rect64) throws -> RedactionRegion {
            try #require(Self.at(r, in: regions).first)
        }
        let held = try at(Self.joined[0].rect), holder = try at(Self.joined[1].rect)
        let c = try G().mount(regions, selected: [held.id], starts: [:], coordinator: coordinator)
        c.overlay.startReader = coordinator.firstEditStartReader(pageIndex: 0)
        let reader = coordinator.firstEditStartReader(pageIndex: 0)
        // The page as drawn: the held box starts from its own rectangle.
        let version = c.state.pageVersion(0)
        c.state.drawnPlans[0] = try #require(coordinator.planAtRead(pageIndex: 0))
            .stamped(pageVersion: version, fromStoredRegions: true)
        #expect(reader(held.id)?.clause == 2)
        // The holder deleted, and no drawing pass since.
        c.state.removeRegion(holder.id, page: 0, undoManager: nil)
        c.overlay.configure(with: c.state.regions[0] ?? [], selectedIDs: [held.id])
        #expect(c.state.pageVersion(0) != version)
        let start = try #require(reader(held.id))
        #expect(start.clause == 1, "the held box, now alone, starts by clause \(start.clause)")
        let paint = try #require(coordinator.planAtRead(pageIndex: 0)?.boxes.first { $0.regionIDs == [held.id] }).paint
        #expect(G.sixtyFourths(start.share) == G.sixtyFourths(paint), "the start is the box's whole paint")
        #expect(G.sixtyFourths(start.share) != G.sixtyFourths(held.normalizedRect))
        try nudgeRight(held.id, in: c)
        let moved = G.sixtyFourths(try #require(c.stored(held.id)).normalizedRect)
        #expect(Self.distance(moved, zip(G.sixtyFourths(start.share), [64, 0, 64, 0]).map(+)) <= Self.carried,
                "moved from the whole paint: \(moved)")
        withExtendedLifetime(c) {}
    }

    @Test("With no kept plan of the page, a first edit after an edit on another page starts from the plan made at the read, with the page's words")
    func aFirstEditThroughThePlanMadeAtTheRead() async throws {
        let pdf = try Self.samplePDF()
        let coordinator = try Self.coordinator(try await Self.documentState(pdf))
        let regions = await Self.placed(pdf, Self.modes(.statement))
        let delia = try #require(Self.at(Self.joined[2].rect, in: regions).first,
                                 "on its line \(Self.onTheLine(Self.joined[2].rect, regions))")
        let c = try G().mount(regions, selected: [delia.id], starts: [:], coordinator: coordinator)
        c.overlay.startReader = coordinator.firstEditStartReader(pageIndex: 0)
        // An edit on the next page; this page has kept no plan.
        c.state.addRegion(G.hand(CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.05)), page: 1, undoManager: c.undo)
        #expect(c.state.drawnPlans[0] == nil)
        let start = try #require(coordinator.firstEditStartReader(pageIndex: 0)(delia.id),
                                 "a box due a start by clause 3 has one: the plan made at the read has the page's words")
        #expect(start.clause == 3)
        c.undo.removeAllActions()
        try nudgeRight(delia.id, in: c)
        let moved = G.sixtyFourths(try #require(c.stored(delia.id)).normalizedRect)
        #expect(Self.distance(moved, zip(G.sixtyFourths(start.share), [64, 0, 64, 0]).map(+)) <= Self.carried,
                "moved from the start: \(moved)")
        withExtendedLifetime(c) {}
    }
}
