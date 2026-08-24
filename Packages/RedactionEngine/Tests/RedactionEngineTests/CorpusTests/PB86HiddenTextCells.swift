import Foundation
import CoreGraphics
import PDFKit
import Testing
@testable import RedactionEngine

// H2.2 section E — the PB-86 hidden-text probe cells (1.2 P1.4; C12-01,
// SI-61, registers/31- §B row 2).
//
// Question under measurement (M12-11): when a document carrying hidden
// SOURCE text (white-on-white, `3 Tr`, content-stream opaque box, OCG /OFF)
// goes through the SEARCHABLE product path, does the hidden text re-expose
// in the output's invisible text layer? Cells run searchable-mode only;
// each plant is measured twice where the grid allows — under a burned
// region ("covered": the burn must remove it) and outside every region
// ("uncovered": the pure re-exposure probe). `pb86-plants.json` records
// every (cell, term, class, covered) measurement row for the oracle-side
// analysis (`verify_oracle.py pb86`).
//
// SI-61 stands: this section MEASURES the searchable path's hidden-text
// behavior; no engine change rides it.

extension VerificationCorpusRunnerTests {

    struct PB86PlantRow: Encodable {
        let cell: String
        let doc_id: String
        let term: String
        let hidden_class: String
        let covered: Bool
        let source: String
    }

    struct PB86PlantsJSON: Encodable {
        let schema_version: Int
        let generated_by: String
        let note: String
        let plants: [PB86PlantRow]
    }

    /// Decoded sd sidecar (variants/packet-hidden-plants.json).
    struct SDPlant: Decodable {
        let file: String
        let page: Int
        let hidden_class: String
        let term: String
        let role: String
        let bbox: [Double]
        let burn_region: [Double]?
    }
    struct SDPlantsSidecar: Decodable {
        let plants: [SDPlant]
    }

    static func pb86CellName(_ docId: String, _ set: String) -> String {
        "\(docId)/\(PipelineMode.searchableRedaction.rawValue)/\(set)"
    }

    /// The engine-factory PB-86 grid: 4 hidden classes × covered/uncovered.
    /// Regions are fixed normalized boxes over the factories' known geometry
    /// (RawPDFBuilder anchor/hidden Td positions; ctLineDraw NATO column;
    /// ocgHiddenLayerPDF's 72,720 line).
    static func pb86FactoryInputs() -> [(CellInput, [PB86PlantRow])] {
        let hiddenRegion = [seed("hidden-line", page: 0,
                                 x: 0.08, y: 0.485, w: 0.62, h: 0.045)]
        let anchorRegion = [seed("anchor-line", page: 0,
                                 x: 0.08, y: 0.865, w: 0.62, h: 0.045)]
        let dummyRegion = [seed("dummy-corner", page: 0,
                                x: 0.75, y: 0.05, w: 0.15, h: 0.04)]

        func cell(
            _ id: String, _ data: Data, set: String, seeds: [RegionSeed],
            terms: [String], notes: String
        ) -> CellInput {
            CellInput(
                docId: id, data: data, docSHA: sha256Hex(data),
                regionSet: fixedSet(set, seeds: seeds),
                regionSource: "pb86",
                expectedVisible: [],
                notes: notes,
                verifyOnly: false,
                termsOverride: terms.map {
                    SensitiveTerm(text: $0, requiresTokenBoundary: false)
                })
        }
        func rows(
            _ id: String, set: String, cls: String,
            covered: [String], uncovered: [String]
        ) -> [PB86PlantRow] {
            let cellKey = pb86CellName(id, set)
            return covered.map {
                PB86PlantRow(cell: cellKey, doc_id: id, term: $0,
                             hidden_class: cls, covered: true, source: "factory")
            } + uncovered.map {
                PB86PlantRow(cell: cellKey, doc_id: id, term: $0,
                             hidden_class: cls, covered: false, source: "factory")
            }
        }

        let wow = TestFixtures.whiteOnWhiteTextPDF()
        let box = TestFixtures.opaqueBoxCoveredTextPDF()
        let tr3 = TestFixtures.ctLineDrawCourierPDF()
        let ocg = TestFixtures.ocgHiddenLayerPDF()
        let natoCovered = ["ALPHA", "BRAVO", "CHARLIE", "DELTA", "ECHO"]
        let natoUncovered = ["FOXTROT", "GOLF", "HOTEL", "INDIA", "JULIET"]

        return [
            (cell("pb86-white-on-white", wow, set: "pb86-covered",
                  seeds: hiddenRegion, terms: ["PLANT-ENGWOW-01"],
                  notes: "region over the white-on-white plant; the burn must remove it from the output text layer"),
             rows("pb86-white-on-white", set: "pb86-covered",
                  cls: "white_on_white", covered: ["PLANT-ENGWOW-01"], uncovered: [])),
            (cell("pb86-white-on-white", wow, set: "pb86-uncovered",
                  seeds: anchorRegion, terms: ["WOW VISIBLE ANCHOR LINE"],
                  notes: "region over the visible anchor only; the white-on-white plant is untouched — the pure re-exposure probe"),
             rows("pb86-white-on-white", set: "pb86-uncovered",
                  cls: "white_on_white", covered: [], uncovered: ["PLANT-ENGWOW-01"])),
            (cell("pb86-opaque-box", box, set: "pb86-covered",
                  seeds: hiddenRegion, terms: ["PLANT-ENGBOX-01"],
                  notes: "region over the painted-box-covered plant"),
             rows("pb86-opaque-box", set: "pb86-covered",
                  cls: "opaque_box", covered: ["PLANT-ENGBOX-01"], uncovered: [])),
            (cell("pb86-opaque-box", box, set: "pb86-uncovered",
                  seeds: anchorRegion, terms: ["BOX VISIBLE ANCHOR LINE"],
                  notes: "region over the visible anchor only; the box-covered plant is untouched"),
             rows("pb86-opaque-box", set: "pb86-uncovered",
                  cls: "opaque_box", covered: [], uncovered: ["PLANT-ENGBOX-01"])),
            (cell("pb86-tr3-courier", tr3, set: "pb86-covered-half",
                  seeds: [seed("nato-upper-half", page: 0,
                               x: 0.09, y: 0.7765, w: 0.16, h: 0.1275)],
                  terms: natoCovered,
                  notes: "region over ALPHA..ECHO of the ten 3 Tr NATO words; FOXTROT..JULIET stay uncovered — in-doc covered/uncovered contrast in one cell (also dodges the F12-05 empty-survivor edge)"),
             rows("pb86-tr3-courier", set: "pb86-covered-half",
                  cls: "tr3_invisible", covered: natoCovered, uncovered: natoUncovered)),
            (cell("pb86-ocg-hidden", ocg, set: "pb86-covered",
                  seeds: [seed("ocg-line", page: 0,
                               x: 0.09, y: 0.895, w: 0.35, h: 0.05)],
                  terms: ["HIDDEN SECRET"],
                  notes: "region over the OCG /OFF line; AD-2-1 predicts a per-page secure fallback regardless of regions — per_page_modes is the mechanism record"),
             rows("pb86-ocg-hidden", set: "pb86-covered",
                  cls: "ocg_off", covered: ["HIDDEN SECRET"], uncovered: [])),
            (cell("pb86-ocg-hidden", ocg, set: "pb86-uncovered",
                  seeds: dummyRegion, terms: [],
                  notes: "dummy corner region; the OCG line is untouched by any region"),
             rows("pb86-ocg-hidden", set: "pb86-uncovered",
                  cls: "ocg_off", covered: [], uncovered: ["HIDDEN SECRET"])),
        ]
    }

    /// The sd realism leg: packet-hidden-text.pdf + packet-hidden-ocg.pdf
    /// with regions from the sidecar's covered-plant burn boxes. Skips (with
    /// reasons) when DOCS_ROOT or the built variants are absent.
    static func pb86SDInputs(
        root: String?, skipped: inout [String: String]
    ) -> [(CellInput, [PB86PlantRow])] {
        guard let root else {
            skipped["packet-hidden-text"] = "RESECTA_DOCS_ROOT unset"
            skipped["packet-hidden-ocg"] = "RESECTA_DOCS_ROOT unset"
            return []
        }
        let base = URL(fileURLWithPath: root).appendingPathComponent("variants")
        guard let sidecarData = try? Data(contentsOf:
                base.appendingPathComponent("packet-hidden-plants.json")),
              let sidecar = try? JSONDecoder().decode(
                SDPlantsSidecar.self, from: sidecarData) else {
            skipped["packet-hidden-text"] = "packet-hidden-plants.json unresolvable under DOCS_ROOT/variants"
            skipped["packet-hidden-ocg"] = "packet-hidden-plants.json unresolvable under DOCS_ROOT/variants"
            return []
        }

        var out: [(CellInput, [PB86PlantRow])] = []
        for file in ["packet-hidden-text.pdf", "packet-hidden-ocg.pdf"] {
            let docId = (file as NSString).deletingPathExtension
            guard let data = try? Data(contentsOf: base.appendingPathComponent(file)) else {
                skipped[docId] = "\(file) missing under DOCS_ROOT/variants (build_hidden not run?)"
                continue
            }
            let plants = sidecar.plants.filter { $0.file == file }
            let covered = plants.filter { $0.role == "covered" }
            let seeds: [RegionSeed] = covered.compactMap { p in
                guard let r = p.burn_region, r.count == 4 else { return nil }
                return seed(p.term, page: p.page,
                            x: r[0], y: r[1], w: r[2], h: r[3])
            }
            guard !seeds.isEmpty else {
                skipped[docId] = "sidecar carries no covered burn regions for \(file)"
                continue
            }
            let cellKey = pb86CellName(docId, "pb86-plants")
            let input = CellInput(
                docId: docId, data: data, docSHA: sha256Hex(data),
                regionSet: fixedSet("pb86-plants", seeds: seeds),
                regionSource: "pb86-sidecar",
                expectedVisible: [],
                notes: "regions over the sidecar's covered plants (page-0 margin bands); uncovered plants ride unburned — see pb86-plants.json",
                verifyOnly: false,
                termsOverride: covered.map {
                    SensitiveTerm(text: $0.term, requiresTokenBoundary: false)
                })
            let rows = plants.map {
                PB86PlantRow(cell: cellKey, doc_id: docId, term: $0.term,
                             hidden_class: $0.hidden_class,
                             covered: $0.role == "covered", source: "sd-variant")
            }
            out.append((input, rows))
        }
        return out
    }

    static func writePB86Plants(_ rows: [PB86PlantRow], out: String) throws {
        try writeJSON(
            PB86PlantsJSON(
                schema_version: 1,
                generated_by: "VerificationCorpusRunnerTests section E (PB-86)",
                note: "covered=true: a burned region lies over the plant (the burn must remove it); covered=false: no region touches it (re-exposure probe). Searchable mode only.",
                plants: rows),
            to: "\(out)/pb86-plants.json")
    }
}

// Always-on smoke for the two NEW T2.4 factories (host + sim safe, in-memory):
// the hidden line must be extractor-visible (that is the PB-86 premise) and
// the documents must parse.
@Suite("T2.4 hidden-text factory smoke")
struct PB86FactorySmokeTests {

    @Test("whiteOnWhiteTextPDF parses; hidden text is extractor-visible")
    func whiteOnWhite() throws {
        let doc = try #require(PDFDocument(data: TestFixtures.whiteOnWhiteTextPDF()))
        let text = try #require(doc.page(at: 0)?.string)
        #expect(text.contains("PLANT-ENGWOW-01"))
        #expect(text.contains("WOW VISIBLE ANCHOR LINE"))
    }

    @Test("opaqueBoxCoveredTextPDF parses; covered text is extractor-visible")
    func opaqueBox() throws {
        let doc = try #require(PDFDocument(data: TestFixtures.opaqueBoxCoveredTextPDF()))
        let text = try #require(doc.page(at: 0)?.string)
        #expect(text.contains("PLANT-ENGBOX-01"))
        #expect(text.contains("BOX VISIBLE ANCHOR LINE"))
    }
}
