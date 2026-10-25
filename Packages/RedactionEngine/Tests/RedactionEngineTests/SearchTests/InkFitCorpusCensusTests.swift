import Testing
import Foundation
import PDFKit
@testable import RedactionEngine

// The ink fit's corpus census (env-gated INKFIT_CENSUS_ROOT, never in the
// batched gate): for every PDF under the root, the pages the fit runs on — a
// page-scale image under text shown in an invisible render mode — so a
// measurement run can name the cells whose search boxes the fit moves. It
// prints one line per document and writes them to INKFIT_CENSUS_OUT when set.
//
// Privacy rule (audit-lint M-1): locate/read/report vocabulary.

@Suite("Ink fit corpus census", .enabled(if: ProcessInfo.processInfo.environment["INKFIT_CENSUS_ROOT"] != nil))
struct InkFitCorpusCensusTests {
    @Test("Pages the ink fit runs on, per document")
    func census() throws {
        let env = ProcessInfo.processInfo.environment
        let root = URL(fileURLWithPath: try #require(env["INKFIT_CENSUS_ROOT"]))
        let paths = (FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension.lowercased() == "pdf" } ?? [])
            .sorted { $0.path < $1.path }
        var lines: [String] = []
        for url in paths {
            guard let document = PDFDocument(url: url) else { lines.append("\(url.lastPathComponent): unopenable"); continue }
            var fitted: [Int] = []
            for index in 0..<document.pageCount {
                guard let page = document.page(at: index), let cgPage = page.pageRef else { continue }
                if DocumentSearcher.carriesHiddenTextOverImage(page, cgPage: cgPage) { fitted.append(index + 1) }
            }
            let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
            lines.append("\(relative): \(document.pageCount) pages, fitted \(fitted.count)\(fitted.isEmpty ? "" : " " + fitted.map(String.init).joined(separator: ","))")
        }
        print(lines.joined(separator: "\n"))
        if let out = env["INKFIT_CENSUS_OUT"] { try lines.joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8) }
    }

    /// The pages the fit runs on, for a document's bytes.
    static func fitted(_ data: Data) -> (pages: Int, fitted: [Int])? {
        guard let document = PDFDocument(data: data) else { return nil }
        var fitted: [Int] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index), let cgPage = page.pageRef else { continue }
            if DocumentSearcher.carriesHiddenTextOverImage(page, cgPage: cgPage) { fitted.append(index + 1) }
        }
        return (document.pageCount, fitted)
    }

    @Test("Pages the ink fit runs on, per runner-generated cell input and its Searchable output",
          .enabled(if: ProcessInfo.processInfo.environment["INKFIT_CENSUS_GENERATED_OUT"] != nil))
    func generatedCensus() async throws {
        typealias Runner = VerificationCorpusRunnerTests
        // The same builders the corpus runner's cells come from.
        var inputs = Runner.factoryInputs() + Runner.compatResidueInputs() + Runner.pb86FactoryInputs().map(\.0)
        if let statement = try? TestFixtures.sampleStatementPDF(), let doc = PDFDocument(data: statement) {
            inputs.append(Runner.CellInput(
                docId: "sample-bank-statement", data: statement, docSHA: Runner.sha256Hex(statement),
                regionSet: Runner.fixedSet("seeded-grid", seeds: Runner.statementGridSeeds(pageCount: doc.pageCount)),
                regionSource: "seeded-grid", expectedVisible: [], notes: "", verifyOnly: false, termsOverride: []))
        }
        var lines: [String] = []
        for input in inputs {
            let name = "\(input.docId)/\(input.regionSet.name)"
            guard let source = Self.fitted(input.data) else { lines.append("\(name): unopenable"); continue }
            var line = "\(name): input \(source.pages) pages, fitted \(source.fitted.count)\(source.fitted.isEmpty ? "" : " " + source.fitted.map(String.init).joined(separator: ","))"
            if input.verifyOnly {
                line += "; searchableRedaction output: not run (verify-only)"
            } else {
                var regions: [Int: [RedactionRegion]] = [:]
                for seed in input.regionSet.seeds where seed.page >= 0 && seed.page < source.pages {
                    if let region = Runner.region(from: seed, polygon: input.regionSet.polygon) { regions[seed.page, default: []].append(region) }
                }
                do {
                    let url = try await TestPipeline.processAndExport(input.data, mode: .searchableRedaction,
                                                                      regions: regions.isEmpty ? nil : regions, dpi: 300)
                    defer { try? FileManager.default.removeItem(at: url) }
                    if let output = Self.fitted(try Data(contentsOf: url)) {
                        line += "; searchableRedaction output \(output.pages) pages, fitted \(output.fitted.count)\(output.fitted.isEmpty ? "" : " " + output.fitted.map(String.init).joined(separator: ","))"
                    } else {
                        line += "; searchableRedaction output unopenable"
                    }
                } catch {
                    line += "; searchableRedaction output not made (\(error))"
                }
            }
            lines.append(line)
        }
        print(lines.joined(separator: "\n"))
        if let out = ProcessInfo.processInfo.environment["INKFIT_CENSUS_GENERATED_OUT"] {
            try lines.joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8)
        }
    }
}
