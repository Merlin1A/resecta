import Foundation
import CoreGraphics
import PDFKit
import Testing
import CryptoKit
@testable import RedactionEngine

// H4.2 — Family-4 robustness runner v0 (1.2 instrumentation plan §6 / 10- §4).
//
// Drives the malformed/boundary fixture set — the existing RawPDFBuilder
// factories, the new T4.1/T4.4 factories, and the sd `robustness/` files
// (T4.1/T4.2/T4.4, resolved via RESECTA_DOCS_ROOT + robustness-fixtures.json)
// — through the product pipeline in the app's order:
//
//   import validation (ImportService.validatePDFOffMainActor MIRROR: open →
//   isLocked → page count 0 → 500-page cap → per-page dimensions → the
//   engine's active-content walk) → Scan (DocumentSearcher.performSearch(.piiScan),
//   the H1.2 natural-run shape) → redact (H2.2 processDocument mirror) →
//   verify (H2.2 runVerification mirror).
//
// Outcome row per fixture: {fixture, expected, got, error_class,
// phase_reached, crash: none, temp_residue} — the correctness oracle is
// "no crash + classified error + no partial output left behind" (10- §4).
// The suite never crashes on a divergence: every mismatch is DATA (the
// emitter records it; divergences become F12/C12 rows at analysis).
//
// MEASUREMENT HARNESS: env-gated (RESECTA_ROBUST_OUT / RESECTA_DOCS_ROOT,
// with the TEST_RUNNER_-prefixed forms xcodebuild forwards), .serialized,
// never in the batched gate. MirroringRisk: the import mirror restates
// app-side guards; drift there shows up as expected-vs-got divergence, so
// the mirror is self-auditing against the taxonomy it claims.

@Suite("H4.2 Family-4 robustness runner (standing emitter)", .serialized)
struct RobustnessRunnerTests {

    // MARK: - Env gate (H1.2 pattern)

    static func robustOut() -> String? {
        let env = ProcessInfo.processInfo.environment
        if let p = env["RESECTA_ROBUST_OUT"], !p.isEmpty { return p }
        if let p = env["TEST_RUNNER_RESECTA_ROBUST_OUT"], !p.isEmpty { return p }
        return nil
    }
    static func docsRoot() -> String? {
        let env = ProcessInfo.processInfo.environment
        if let p = env["RESECTA_DOCS_ROOT"], !p.isEmpty { return p }
        if let p = env["TEST_RUNNER_RESECTA_DOCS_ROOT"], !p.isEmpty { return p }
        return nil
    }

    // MARK: - Import-validation mirror (ImportService.validatePDFOffMainActor)

    enum ImportMirrorResult {
        case open(PDFDocument, textLayerStatus: [Int: TextLayerStatus], hasHiddenOCG: Bool)
        case reject(errorClass: String)
    }

    /// Data-level gates in the app's exact order. The app's earlier 50 MB
    /// byte-size cap lives in the caller and never fires on this set.
    static func importMirror(_ data: Data) -> ImportMirrorResult {
        guard let doc = PDFDocument(data: data) else {
            return .reject(errorClass: "corrupt")
        }
        guard !doc.isLocked else {
            return .reject(errorClass: "passwordProtected")
        }
        guard doc.pageCount > 0 else {
            return .reject(errorClass: "corrupt")
        }
        guard doc.pageCount <= 500 else {
            return .reject(errorClass: "tooLarge")
        }
        for i in 0..<doc.pageCount {
            var pageError: String? = nil
            autoreleasepool {
                guard let page = doc.page(at: i) else {
                    pageError = "corrupt"
                    return
                }
                let box = page.bounds(for: .cropBox)
                guard box.width > 0, box.height > 0,
                      box.width <= 5000, box.height <= 5000 else {
                    pageError = "invalidPageDimensions"
                    return
                }
            }
            if let pageError { return .reject(errorClass: pageError) }
        }
        var hasHiddenOCG = false
        if let provider = CGDataProvider(data: data as CFData),
           let cgDoc = CGPDFDocument(provider) {
            // The app's guard and this mirror call the same engine walk, so
            // this stage cannot drift; the class is the refusal's own case.
            if ActiveContentScan.firstLocation(in: cgDoc) != nil {
                return .reject(errorClass: "activeContent")
            }
            hasHiddenOCG = TextLayerExtractor.documentHasHiddenOCG(cgDoc)
        }
        var status: [Int: TextLayerStatus] = [:]
        for i in 0..<doc.pageCount {
            autoreleasepool {
                guard let page = doc.page(at: i) else { return }
                status[i] = TextLayerDetector.detectTextLayer(page)
            }
        }
        return .open(doc, textLayerStatus: status, hasHiddenOCG: hasHiddenOCG)
    }

    // MARK: - Fixture table

    struct Expected {
        let importOutcome: String          // "open" | "reject"
        let importError: String?           // taxonomy class when reject
        let redact: String                 // "open" | "reject" | "skip" | "skip_v0"
        let redactError: String?           // expected class when redact == "reject"
    }

    struct Fixture {
        let id: String
        let source: String                 // "factory" | "sd"
        let data: Data?
        let path: String?                  // sd-root-relative when source == "sd"
        let expected: Expected
        let notes: String
    }

    /// Engine-factory rows (expected outcomes authored here; sd rows carry
    /// theirs in robustness-fixtures.json).
    static func factoryFixtures() -> [Fixture] {
        func exp(_ imp: String, _ impErr: String?, _ red: String, _ redErr: String? = nil) -> Expected {
            Expected(importOutcome: imp, importError: impErr, redact: red, redactError: redErr)
        }
        return [
            Fixture(id: "zero-byte", source: "factory", data: Data(), path: nil,
                    expected: exp("reject", "corrupt", "skip"),
                    notes: "0-byte input"),
            Fixture(id: "garbage-bytes", source: "factory",
                    data: Data(String(repeating: "this is not a pdf. ", count: 64).utf8), path: nil,
                    expected: exp("reject", "corrupt", "skip"),
                    notes: "non-PDF bytes"),
            Fixture(id: "truncated-xref", source: "factory",
                    data: TestFixtures.blankPage().prefix(TestFixtures.blankPage().count * 3 / 5), path: nil,
                    expected: exp("reject", "corrupt", "skip"),
                    notes: "blankPage cut at 60% (xref + trailer gone)"),
            Fixture(id: "zero-pages", source: "factory",
                    data: TestFixtures.zeroPagePDF(), path: nil,
                    expected: exp("reject", "corrupt", "skip"),
                    notes: "valid structure, empty page tree"),
            Fixture(id: "javascript-catalog", source: "factory",
                    data: TestFixtures.withJavaScript(), path: nil,
                    expected: exp("reject", "activeContent", "skip"),
                    notes: "active-content early rejection (catalog /JavaScript; its own class since the walk widened)"),
            Fixture(id: "javascript-names-tree", source: "factory",
                    data: TestFixtures.withNamesJavaScript(), path: nil,
                    expected: exp("reject", "activeContent", "skip"),
                    notes: "active-content early rejection (/Names → /JavaScript, the ISO-canonical carrier)"),
            Fixture(id: "javascript-open-action", source: "factory",
                    data: TestFixtures.withOpenActionJavaScript(), path: nil,
                    expected: exp("reject", "activeContent", "skip"),
                    notes: "active-content early rejection (/OpenAction JavaScript action)"),
            Fixture(id: "javascript-page-aa", source: "factory",
                    data: TestFixtures.withPageAdditionalActionJavaScript(), path: nil,
                    expected: exp("reject", "activeContent", "skip"),
                    notes: "active-content early rejection (page /AA JavaScript trigger)"),
            Fixture(id: "javascript-annotation-a", source: "factory",
                    data: TestFixtures.withAnnotationActionJavaScript(), path: nil,
                    expected: exp("reject", "activeContent", "skip"),
                    notes: "active-content early rejection (annotation /A JavaScript action)"),
            Fixture(id: "open-action-destination", source: "factory",
                    data: TestFixtures.withOpenActionDestination(), path: nil,
                    expected: exp("open", nil, "open"),
                    notes: "clean /OpenAction destination array (the widened walk must not refuse it)"),
            Fixture(id: "page-without-resources", source: "factory",
                    data: TestFixtures.pageWithoutResources(), path: nil,
                    expected: exp("open", nil, "open"),
                    notes: "no page-level /Resources (Layer-8 WARN class)"),
            Fixture(id: "malformed-stream-keyword-eol", source: "factory",
                    data: TestFixtures.malformedStreamKeywordEOL(term: "ROBUST-EOL-01"), path: nil,
                    expected: exp("open", nil, "open"),
                    notes: "stream-keyword EOL malformation"),
            Fixture(id: "downstream-phantom-range", source: "factory",
                    data: TestFixtures.downstreamPhantomRange(term: "ROBUST-PHANTOM-01"), path: nil,
                    expected: exp("open", nil, "open"),
                    notes: "phantom-range text layer"),
            Fixture(id: "incremental-update", source: "factory",
                    data: TestFixtures.incrementalUpdate(), path: nil,
                    expected: exp("open", nil, "open"),
                    notes: "appended /Prev revision (IM-23 shape)"),
            Fixture(id: "user-unit-2", source: "factory",
                    data: TestFixtures.userUnitPDF(), path: nil,
                    expected: exp("open", nil, "reject", "unsupportedPageGeometry"),
                    notes: "import has no /UserUnit gate (opens); the rasterize pre-flight's geometry half "
                         + "rejects it as unsupportedPageGeometry (formerly reported under insufficientMemory)"),
            Fixture(id: "acroform-v", source: "factory",
                    data: TestFixtures.acroFormPDF(), path: nil,
                    expected: exp("open", nil, "open"),
                    notes: "real AcroForm, /V values, no /AP — page.string /V visibility is measured"),
        ]
    }

    struct SDRow: Decodable {
        struct Exp: Decodable {
            let `import`: String
            let import_error: String?
            let redact: String
            let redact_error: String?
        }
        let id: String
        let path: String
        let gt: String?
        let expected: Exp
        let notes: String
        let sha256: String
    }
    struct SDManifest: Decodable { let fixtures: [SDRow] }

    static func sdFixtures(root: String) throws -> [Fixture] {
        try decodeSidecar(root: root,
                          relativePath: "robustness/robustness-fixtures.json",
                          source: "sd")
    }

    /// T4.3 mutated set (P1.7) — 100 deterministically damaged copies of the packet,
    /// built in resecta-datapipeline and mirrored into robustness/fuzz/ by packet/fuzz.py.
    ///
    /// A SECOND sidecar rather than rows appended to robustness-fixtures.json: that manifest
    /// is regenerated wholesale by packet/robustness.py, which would drop rows it does not
    /// own. The row shape is identical, so the decoder is shared. Absence is tolerated so a
    /// docs root without the T4.3 set still runs the rest of the table.
    static func fuzzFixtures(root: String) throws -> [Fixture] {
        let relative = "robustness/robustness-fuzz.json"
        let url = URL(fileURLWithPath: root).appendingPathComponent(relative)
        guard FileManager.default.fileExists(atPath: url.path) else {
            print("[H4.2] \(relative) absent; T4.3 rows skipped.")
            return []
        }
        return try decodeSidecar(root: root, relativePath: relative, source: "fuzz")
    }

    static func decodeSidecar(root: String,
                              relativePath: String,
                              source: String) throws -> [Fixture] {
        let url = URL(fileURLWithPath: root).appendingPathComponent(relativePath)
        let manifest = try JSONDecoder().decode(SDManifest.self, from: try Data(contentsOf: url))
        return manifest.fixtures.map { row in
            Fixture(id: row.id, source: source, data: nil, path: row.path,
                    expected: Expected(importOutcome: row.expected.`import`,
                                       importError: row.expected.import_error,
                                       redact: row.expected.redact,
                                       redactError: row.expected.redact_error),
                    notes: row.notes)
        }
    }

    // MARK: - Outcome rows

    struct OutcomeRow: Encodable {
        let fixture: String
        let source: String
        let sha256: String
        let bytes: Int
        let expected_import: String
        let expected_import_error: String?
        let got_import: String
        let got_import_error: String?
        let import_match: Bool
        let page_count: Int?
        let scan_ran: Bool
        let scan_hits: Int?
        let scan_seconds: Double?
        let acroform_v_in_page_text: Bool?
        let expected_redact: String
        let got_redact: String?
        let got_redact_error: String?
        let redact_match: Bool
        let verify_ran: Bool
        let verify_overall: String?
        let phase_reached: String
        let crash: Bool                    // always false when the row exists
        let temp_residue: Int
        let notes: String
    }

    static func classify(_ error: Error) -> String {
        guard let pe = error as? PipelineError else {
            return String(describing: type(of: error))
        }
        switch pe {
        case .importError(let e): return "importError.\(caseLabel(e))"
        case .redactionError(let e): return caseLabel(e)
        case .verificationError(let e): return "verificationError.\(caseLabel(e))"
        default: return caseLabel(pe)
        }
    }
    static func caseLabel<T>(_ value: T) -> String {
        let d = String(describing: value)
        return d.firstIndex(of: "(").map { String(d[..<$0]) } ?? d
    }

    static func tempCensus() -> Set<String> {
        let tmp = FileManager.default.temporaryDirectory
        let items = (try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? []
        return Set(items)
    }

    // MARK: - The run

    @Test("Family-4 robustness outcome table over factories + sd fixtures + T4.3 mutated set")
    func robustnessOutcomeTable() async throws {
        guard let out = Self.robustOut() else {
            print("[H4.2] RESECTA_ROBUST_OUT not set; robustness runner skipped.")
            return
        }
        let root = Self.docsRoot()
        var fixtures = Self.factoryFixtures()
        if let root {
            fixtures += try Self.sdFixtures(root: root)
            fixtures += try Self.fuzzFixtures(root: root)
        } else {
            print("[H4.2] RESECTA_DOCS_ROOT not set; sd rows skipped.")
        }
        let balanced = PresetThresholdBundle.loadFromEngineBundle().presets[.balanced]

        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("f4-robust-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        var rows: [OutcomeRow] = []
        for fixture in fixtures {
            let data: Data
            if let d = fixture.data {
                data = d
            } else if let root, let rel = fixture.path {
                data = try Data(contentsOf: URL(fileURLWithPath: root).appendingPathComponent(rel))
            } else {
                continue
            }
            let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let censusBefore = Self.tempCensus()

            var phase = "import"
            var gotImport = "reject"
            var gotImportError: String? = nil
            var pageCount: Int? = nil
            var scanRan = false
            var scanHits: Int? = nil
            var scanSeconds: Double? = nil
            var acroProbe: Bool? = nil
            var gotRedact: String? = nil
            var gotRedactError: String? = nil
            var verifyRan = false
            var verifyOverall: String? = nil

            switch Self.importMirror(data) {
            case .reject(let errorClass):
                gotImportError = errorClass
            case .open(let doc, let status, let hasHiddenOCG):
                gotImport = "open"
                pageCount = doc.pageCount

                // Scan leg (the H1.2 natural-run shape).
                phase = "scan"
                let scan = try await DocumentHarnessTests.naturalRun(
                    data: data, status: status, balanced: balanced)
                scanRan = true
                scanHits = scan.hits.count
                scanSeconds = scan.seconds
                if fixture.id == "acroform-v" {
                    let text = (0..<doc.pageCount)
                        .compactMap { doc.page(at: $0)?.string }.joined()
                    acroProbe = text.contains("987-65-4329")
                }

                // Redact + verify leg.
                if fixture.expected.redact == "open" || fixture.expected.redact == "reject" {
                    phase = "redact"
                    let anyRich = status.values.contains(.rich)
                    let mode: PipelineMode = anyRich ? .searchableRedaction : .secureRasterization
                    let regions = [0: [RedactionRegion(
                        id: UUID(),
                        normalizedRect: CGRect(x: 0.1, y: 0.45, width: 0.8, height: 0.1),
                        source: .manual)]]
                    let pages = VerificationCorpusRunnerTests.buildPages(
                        doc: doc, effectiveMode: mode, regionsByPage: regions,
                        textLayerStatus: status, hasHiddenOCG: hasHiddenOCG)
                    let outputURL = scratch.appendingPathComponent("\(fixture.id)-redacted.pdf")
                    do {
                        let outcome = try await VerificationCorpusRunnerTests.runRedaction(
                            pages: pages, outputURL: outputURL)
                        gotRedact = "open"
                        phase = "verify"
                        let report = try await VerificationCorpusRunnerTests.runVerificationSweep(
                            outputURL: outputURL,
                            sourcePageCount: doc.pageCount,
                            regions: regions,
                            sensitiveTerms: [],
                            effectiveMode: mode,
                            filterDigests: outcome.filterDigests,
                            perPageModes: outcome.perPageModes,
                            perPageFallbackReasons: outcome.perPageFallbackReasons)
                        verifyRan = true
                        verifyOverall = Self.caseLabel(report.overallStatus)
                        phase = "complete"
                    } catch { // LegalPhrases:safe (Swift keyword)
                        gotRedact = "reject"
                        gotRedactError = Self.classify(error)
                    }
                    try? FileManager.default.removeItem(at: outputURL)
                } else {
                    phase = "scan-only(v0)"
                }
            }

            let censusAfter = Self.tempCensus()
            let residue = censusAfter.subtracting(censusBefore)
                .filter { !$0.hasPrefix("f4-robust-") }

            let importMatch = gotImport == fixture.expected.importOutcome
                && (gotImport == "open" || gotImportError == fixture.expected.importError)
            let redactMatch: Bool
            switch fixture.expected.redact {
            case "open": redactMatch = gotRedact == "open"
            case "reject": redactMatch = gotRedact == "reject"
                && (fixture.expected.redactError == nil || gotRedactError == fixture.expected.redactError)
            default: redactMatch = true    // skip / skip_v0: no redact expectation
            }

            rows.append(OutcomeRow(
                fixture: fixture.id, source: fixture.source, sha256: sha, bytes: data.count,
                expected_import: fixture.expected.importOutcome,
                expected_import_error: fixture.expected.importError,
                got_import: gotImport, got_import_error: gotImportError,
                import_match: importMatch,
                page_count: pageCount,
                scan_ran: scanRan, scan_hits: scanHits, scan_seconds: scanSeconds.map { (($0 * 1000).rounded() / 1000) },
                acroform_v_in_page_text: acroProbe,
                expected_redact: fixture.expected.redact,
                got_redact: gotRedact, got_redact_error: gotRedactError,
                redact_match: redactMatch,
                verify_ran: verifyRan, verify_overall: verifyOverall,
                phase_reached: phase, crash: false,
                temp_residue: residue.count,
                notes: fixture.notes))
            print("[H4.2] \(fixture.id): import=\(gotImport)(\(gotImportError ?? "-")) "
                + "redact=\(gotRedact ?? "-")(\(gotRedactError ?? "-")) phase=\(phase) "
                + "match=\(importMatch && redactMatch) residue=\(residue.count)")
        }

        struct Envelope: Encodable {
            let schema_version: Int
            let generated_by: String
            let platform: String
            let os_build: String
            let fixture_count: Int
            let all_import_match: Bool
            let all_redact_match: Bool
            let crashes: Int
            let rows: [OutcomeRow]
        }
        let envelope = Envelope(
            schema_version: 1,
            generated_by: "RobustnessRunnerTests (H4.2 v0)",
            platform: platformLabel(),
            os_build: osBuildLabel(),
            fixture_count: rows.count,
            all_import_match: rows.allSatisfy(\.import_match),
            all_redact_match: rows.allSatisfy(\.redact_match),
            crashes: 0,
            rows: rows)
        try Self.writeJSON(envelope, to: out + "/robustness-outcomes.json")
        print("[H4.2] \(rows.count) fixtures; import_match=\(envelope.all_import_match) "
            + "redact_match=\(envelope.all_redact_match); wrote robustness-outcomes.json")
    }

    static func writeJSON<T: Encodable>(_ value: T, to path: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}

func platformLabel() -> String {
    #if targetEnvironment(simulator)
    return "sim"
    #elseif os(iOS)
    return "device"
    #else
    return "host"
    #endif
}

func osBuildLabel() -> String {
    let v = ProcessInfo.processInfo.operatingSystemVersion
    return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
}

// MARK: - Family-4 factory smoke (always-on; PB86FactorySmokeTests precedent)

@Suite("Family-4 fixture factory smoke (T4.1/T4.4)")
struct Family4FactorySmokeTests {

    @Test("userUnitPDF opens, carries /UserUnit, and fails the rasterize pre-flight")
    func userUnitFactory() throws {
        let data = TestFixtures.userUnitPDF()
        let doc = try #require(PDFDocument(data: data))
        #expect(doc.pageCount == 1)
        let page = try #require(doc.page(at: 0))
        var userUnit: CGPDFReal = 0
        let dict = try #require(page.pageRef?.dictionary)
        #expect(CGPDFDictionaryGetNumber(dict, "UserUnit", &userUnit))
        #expect(userUnit == 2.0)
        #expect(page.string?.contains("USERUNIT PROBE LINE") == true,
                "text layer must survive so the scan leg has work")
        #expect(validatePage(page) == false,
                "the H-16 /UserUnit guard must reject this page")
        #expect(validatePageGeometry(page) == false,
                "the refusal is the geometry half's, not the memory half's")
    }

    @Test("acroFormPDF opens with its fields and /V values readable from the form tree")
    func acroFormFactory() throws {
        let data = TestFixtures.acroFormPDF()
        let doc = try #require(PDFDocument(data: data))
        #expect(doc.pageCount == 1)
        let page = try #require(doc.page(at: 0))
        let widgets = page.annotations.filter { $0.type == "Widget" }
        #expect(widgets.count == 2, "both merged field+widget annots must surface")
        let values = Set(widgets.compactMap { $0.widgetStringValue })
        #expect(values.contains("987-65-4329"), "field /V must be readable via PDFKit")
        #expect(page.string?.contains("ACROFORM VISIBLE ANCHOR LINE") == true)
    }

    @Test("zeroPagePDF opens structurally with an empty page tree")
    func zeroPageFactory() {
        let data = TestFixtures.zeroPagePDF()
        // PDFKit may return a document with 0 pages or fail the open outright;
        // both routes land in the import mirror's `corrupt` classification.
        if let doc = PDFDocument(data: data) {
            #expect(doc.pageCount == 0)
        }
    }
}

@Suite("T2.3 fixture factory smoke (IM-14/IM-23)")
struct T23FactorySmokeTests {

    @Test("annotatedAPContentsPDF: all four annots surface; terms live outside the page text")
    func annotatedFactory() throws {
        let data = TestFixtures.annotatedAPContentsPDF()
        let doc = try #require(PDFDocument(data: data))
        #expect(doc.pageCount == 1)
        let page = try #require(doc.page(at: 0))
        let types = Set(page.annotations.map(\.type))
        for want in ["FreeText", "Stamp", "Square", "Popup"] {
            #expect(types.contains(want), "missing \(want) in \(types)")
        }
        let raw = String(decoding: data, as: UTF8.self)
        let text = page.string ?? ""
        #expect(text.contains("ANNOTATED FIXTURE ANCHOR LINE"))
        for term in [TestFixtures.annotFreeTextTerm,
                     TestFixtures.annotStampTerm,
                     TestFixtures.annotPopupTerm] {
            #expect(raw.contains(term), "term must be in the file bytes: \(term)")
            // Pinned PDFKit stance: page.string covers page CONTENT text only —
            // annotation /AP and /Contents text stays out. Drift = re-adjudicate.
            #expect(!text.contains(term), "page.string surfaced annotation term \(term)")
        }
    }

    @Test("incrementalUpdateRealPrev: current view is revision 2, prior bytes remain")
    func realPrevFactory() throws {
        let data = TestFixtures.incrementalUpdateRealPrev()
        let doc = try #require(PDFDocument(data: data))
        #expect(doc.pageCount == 1)
        let text = try #require(doc.page(at: 0)).string ?? ""
        #expect(text.contains("withdrawn in revision 2"),
                "the /Prev-linked revision 2 must be the current view")
        #expect(!text.contains("987-65-4377"), "revision 1 text must be replaced")
        let raw = String(decoding: data, as: UTF8.self)
        #expect(raw.contains("PRIOR-REV SSN 987-65-4377"),
                "revision 1 bytes must remain in the file")
        #expect(raw.components(separatedBy: "%%EOF").count - 1 == 2,
                "exactly two revisions")
        #expect(raw.contains("/Prev "), "trailer must carry a real /Prev link")
    }
}
