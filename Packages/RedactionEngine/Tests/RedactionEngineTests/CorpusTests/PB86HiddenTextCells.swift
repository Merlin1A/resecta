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

    /// The engine-factory hidden-text probe grid: the four original hidden classes ×
    /// covered/uncovered, the three optional-content forms × covered/uncovered,
    /// the crop-box page (uncovered only: the hidden line is off the page), and
    /// the three faint-ink pages × covered/uncovered.
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
        let bso = TestFixtures.ocgBaseStateOffPDF()
        let inh = TestFixtures.ocgInheritedResourcesPDF()
        let xob = TestFixtures.ocgFormXObjectPDF()
        let crop = TestFixtures.offCropBoxTextPDF()
        let nearWhite = TestFixtures.nearWhiteTextPDF()
        let lowAlpha = TestFixtures.lowAlphaTextPDF()
        let translucentBox = TestFixtures.translucentBoxCoveredTextPDF()
        // The crop-box page is 600 pt tall: its anchor line at y 400 sits at
        // 0.667 of the visible page; the hidden line is outside the box, so
        // no region can cover it.
        let cropAnchorRegion = [seed("anchor-line", page: 0,
                                     x: 0.08, y: 0.65, w: 0.62, h: 0.06)]
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
            // The three forms optional content takes beside a page's own
            // /Properties entry, and a page whose text sits outside its crop
            // box: each hidden line is extractor-visible; the searchable
            // path must keep it out of the output text layer.
            (cell("pb86-ocg-base-state-off", bso, set: "pb86-covered",
                  seeds: hiddenRegion, terms: ["PLANT-ENGBSO-01"],
                  notes: "region over the line a /BaseState /OFF default configuration hides"),
             rows("pb86-ocg-base-state-off", set: "pb86-covered",
                  cls: "ocg_base_state_off", covered: ["PLANT-ENGBSO-01"], uncovered: [])),
            (cell("pb86-ocg-base-state-off", bso, set: "pb86-uncovered",
                  seeds: anchorRegion, terms: ["BSO VISIBLE ANCHOR LINE"],
                  notes: "region over the visible anchor only; the base-state-hidden line is untouched"),
             rows("pb86-ocg-base-state-off", set: "pb86-uncovered",
                  cls: "ocg_base_state_off", covered: [], uncovered: ["PLANT-ENGBSO-01"])),
            (cell("pb86-ocg-inherited-resources", inh, set: "pb86-covered",
                  seeds: hiddenRegion, terms: ["PLANT-ENGINH-01"],
                  notes: "region over the hidden line of a page that inherits the resources naming the group"),
             rows("pb86-ocg-inherited-resources", set: "pb86-covered",
                  cls: "ocg_inherited_resources", covered: ["PLANT-ENGINH-01"], uncovered: [])),
            (cell("pb86-ocg-inherited-resources", inh, set: "pb86-uncovered",
                  seeds: anchorRegion, terms: ["INH VISIBLE ANCHOR LINE"],
                  notes: "region over the visible anchor only; the inherited-resources line is untouched"),
             rows("pb86-ocg-inherited-resources", set: "pb86-uncovered",
                  cls: "ocg_inherited_resources", covered: [], uncovered: ["PLANT-ENGINH-01"])),
            (cell("pb86-ocg-form-xobject", xob, set: "pb86-covered",
                  seeds: hiddenRegion, terms: ["PLANT-ENGXOB-01"],
                  notes: "region over the hidden line a form XObject carrying /OC draws"),
             rows("pb86-ocg-form-xobject", set: "pb86-covered",
                  cls: "ocg_form_xobject", covered: ["PLANT-ENGXOB-01"], uncovered: [])),
            (cell("pb86-ocg-form-xobject", xob, set: "pb86-uncovered",
                  seeds: anchorRegion, terms: ["XOB VISIBLE ANCHOR LINE"],
                  notes: "region over the visible anchor only; the form XObject's line is untouched"),
             rows("pb86-ocg-form-xobject", set: "pb86-uncovered",
                  cls: "ocg_form_xobject", covered: [], uncovered: ["PLANT-ENGXOB-01"])),
            (cell("pb86-off-crop", crop, set: "pb86-uncovered",
                  seeds: cropAnchorRegion, terms: ["CROP VISIBLE ANCHOR LINE"],
                  notes: "region over the visible anchor; the line outside the crop box cannot be covered by any region — the pure re-exposure probe"),
             rows("pb86-off-crop", set: "pb86-uncovered",
                  cls: "off_crop", covered: [], uncovered: ["PLANT-ENGCROP-01"])),
            // Faint ink: near-white, nearly transparent and nearly covered
            // text — the ink test's tolerance band reads each as no ink.
            (cell("pb86-near-white", nearWhite, set: "pb86-covered",
                  seeds: hiddenRegion, terms: ["PLANT-ENGNW-01"],
                  notes: "region over the near-white (0.985 grey) line"),
             rows("pb86-near-white", set: "pb86-covered",
                  cls: "near_white", covered: ["PLANT-ENGNW-01"], uncovered: [])),
            (cell("pb86-near-white", nearWhite, set: "pb86-uncovered",
                  seeds: anchorRegion, terms: ["NW VISIBLE ANCHOR LINE"],
                  notes: "region over the visible anchor only; the near-white line is untouched"),
             rows("pb86-near-white", set: "pb86-uncovered",
                  cls: "near_white", covered: [], uncovered: ["PLANT-ENGNW-01"])),
            (cell("pb86-low-alpha", lowAlpha, set: "pb86-covered",
                  seeds: hiddenRegion, terms: ["PLANT-ENGLA-01"],
                  notes: "region over the line drawn at fill alpha 0.02"),
             rows("pb86-low-alpha", set: "pb86-covered",
                  cls: "low_alpha", covered: ["PLANT-ENGLA-01"], uncovered: [])),
            (cell("pb86-low-alpha", lowAlpha, set: "pb86-uncovered",
                  seeds: anchorRegion, terms: ["LA VISIBLE ANCHOR LINE"],
                  notes: "region over the visible anchor only; the low-alpha line is untouched"),
             rows("pb86-low-alpha", set: "pb86-uncovered",
                  cls: "low_alpha", covered: [], uncovered: ["PLANT-ENGLA-01"])),
            (cell("pb86-translucent-box", translucentBox, set: "pb86-covered",
                  seeds: hiddenRegion, terms: ["PLANT-ENGTB-01"],
                  notes: "region over the line under a box painted at fill alpha 0.97"),
             rows("pb86-translucent-box", set: "pb86-covered",
                  cls: "translucent_box", covered: ["PLANT-ENGTB-01"], uncovered: [])),
            (cell("pb86-translucent-box", translucentBox, set: "pb86-uncovered",
                  seeds: anchorRegion, terms: ["TB VISIBLE ANCHOR LINE"],
                  notes: "region over the visible anchor only; the box-covered line is untouched"),
             rows("pb86-translucent-box", set: "pb86-uncovered",
                  cls: "translucent_box", covered: [], uncovered: ["PLANT-ENGTB-01"])),
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
