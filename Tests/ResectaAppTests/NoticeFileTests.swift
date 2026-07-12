import Testing
import Foundation

// CAT-082 (D-10) — Apache License 2.0 Section 4(d) NOTICE.
//
// ARCHITECTURE.md Section 1.3 asserts a NOTICE file "carries the propagated
// entries" for the gazetteer / Bloom / classifier artifacts bundled in the iOS
// app, but no NOTICE existed in the tree at the pin — an unmet attribution
// obligation and a false spec claim. D-10: the NOTICE skeleton lands now with
// the two confirmed pipeline rows (OpenStreetMap ODbL, OpenAddresses CC0);
// The maintainer adds the MIT / courtesy rows at the V1.0 tag.
//
// These guards pin the file's existence and its two confirmed attributions so
// the spec claim stays true and a future edit cannot silently drop them. The
// NOTICE lives at the repo root (the Apache convention; it is a distribution /
// source-tree file, not a bundled resource), so it is read via #filePath.
@Suite("Apache NOTICE attribution (CAT-082)")
struct NoticeFileTests {

    private func noticeContents(file: StaticString = #filePath) throws -> String {
        let repoRoot = URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()   // Tests/ResectaAppTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // <repo root>
        let notice = repoRoot.appendingPathComponent("NOTICE")
        return try String(contentsOf: notice, encoding: .utf8)
    }

    @Test("NOTICE exists at the repo root")
    func testNoticeFileExists() throws {
        let contents = try noticeContents()
        #expect(!contents.isEmpty, "NOTICE exists but is empty")
    }

    @Test("NOTICE carries the confirmed pipeline attributions (OSM + OpenAddresses)")
    func testNoticeContainsPipelineAttributions() throws {
        let contents = try noticeContents()
        #expect(
            contents.contains("OpenStreetMap"),
            "NOTICE missing the OpenStreetMap (ODbL 1.0) attribution row")
        #expect(
            contents.contains("OpenAddresses"),
            "NOTICE missing the OpenAddresses (CC0 1.0) attribution row")
    }

    // MARK: - Manifest-driven license classification (launch-fix-v2 · S3 · CND-07)
    //
    // The name Bloom artifacts bundled in the app are built by
    // resecta-datapipeline from the upstream data sources named in
    // gazetteer-manifest.json. Reading that manifest as the source of truth, a
    // newly-added gazetteer source cannot ship without being license-classified
    // and — when its license requires attribution (MIT) — carried by a NOTICE
    // row. The manifest lives in the engine package's bundled Resources; it is
    // read via the same #filePath repo-root anchor as the NOTICE itself.

    private struct GazetteerManifest: Decodable {
        struct Filter: Decodable { let sources: [String] }
        let filters: [Filter]
    }

    /// The de-duplicated set of upstream data-source tokens named by every Bloom
    /// filter in the bundled gazetteer manifest.
    private func manifestSourceTokens(file: StaticString = #filePath) throws -> Set<String> {
        let repoRoot = URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()   // Tests/ResectaAppTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // <repo root>
        let url = repoRoot.appendingPathComponent(
            "Packages/RedactionEngine/Sources/RedactionEngine/Resources/Gazetteers/gazetteer-manifest.json")
        let data = try Data(contentsOf: url)
        let manifest = try JSONDecoder().decode(GazetteerManifest.self, from: data)
        return Set(manifest.filters.flatMap(\.sources))
    }

    // License classes relevant to the NOTICE obligation. Public-domain (US §105
    // government works) and CC0 are no-attribution-required; MIT requires the
    // copyright + permission notice to propagate into this distribution.
    private enum SourceLicense { case publicDomain, cc0, mit }

    @Test("Every gazetteer-manifest source is license-classified; MIT inbound is attributed")
    func testManifestSourcesClassifiedAndAttributed() throws {
        let contents = try noticeContents()
        let tokens = try manifestSourceTokens()

        #expect(!tokens.isEmpty, "gazetteer-manifest.json named no sources — manifest unreadable or empty")

        // Explicit token -> license table, verified against
        // resecta-datapipeline/SOURCES.md (2026-06-23). NOTE: popnames is CC0,
        // not the "public-domain" label the S3 brief approximated — CC0 is
        // likewise a no-attribution-required class, so the NOTICE needs no
        // popnames row. Only the MIT rows (paranames) drive a required substring.
        let sourceLicenses: [String: SourceLicense] = [
            "census_spanish": .publicDomain,
            "census_spanish_full": .publicDomain,
            "census_surnames": .publicDomain,
            "ssa_given_names": .publicDomain,
            "popnames": .cc0,
            "popnames_common_surnames": .cc0,
            "popnames_common_forenames": .cc0,
            "paranames": .mit,
            "paranames_full": .mit,
        ]
        // MIT-mapped source token -> the substring its NOTICE attribution carries.
        let mitNoticeSubstring: [String: String] = [
            "paranames": "bltlab/paranames",
            "paranames_full": "bltlab/paranames",
        ]

        for token in tokens.sorted() {
            guard let license = sourceLicenses[token] else {
                // Fail-loud net: a new gazetteer source must be classified (and,
                // if attribution-bearing, given a NOTICE row) before it ships.
                Issue.record("Unclassified gazetteer-manifest source '\(token)' — add it to the license table and, if attribution-bearing, to NOTICE")
                continue
            }
            if license == .mit, let required = mitNoticeSubstring[token] {
                #expect(
                    contents.contains(required),
                    "NOTICE missing the MIT attribution for manifest source '\(token)' (expected substring '\(required)')")
            }
        }

        // Faker is an unconditional (non-manifest) MIT input: it generates the
        // synthetic evaluation corpus used to measure the detector — it does not
        // contribute to the name Bloom filters. Pin its copyright holder and the
        // es_ES contributor co-attribution. The contributor is matched
        // diacritic-folded so the guard accepts either the ASCII or accented
        // spelling of "Álvaro Mondéjar Rubio".
        #expect(
            contents.contains("Daniele Faraglia"),
            "NOTICE missing the Faker MIT copyright holder (Daniele Faraglia)")
        let folded = contents.folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US_POSIX"))
        #expect(
            folded.contains("Mondejar"),
            "NOTICE dropped the es_ES Faker contributor co-attribution (Álvaro Mondéjar Rubio)")
    }

    @Test("MIT inbound NOTICE rows are authored and discharged (RED until Jesse fills the TODO block)")
    func testMITInboundAttributionDischarged() throws {
        let contents = try noticeContents()

        // The MIT license body must propagate, not just the copyright line: a
        // compliant MIT notice reproduces the permission grant verbatim.
        #expect(
            contents.contains("Permission is hereby granted, free of charge"),
            "NOTICE lacks the MIT permission notice — the Faker / paranames rows are not yet authored (Jesse-owned, DEC-6)")

        // The TODO(Jesse) checklist must be fully discharged: no unchecked row
        // may remain once the MIT rows are authored and the artifacts confirmed.
        let header = "TODO(Jesse)"
        if let range = contents.range(of: header) {
            let todoBlock = contents[range.lowerBound...]
            #expect(
                !todoBlock.contains("[ ]"),
                "NOTICE still has unchecked TODO(Jesse) attribution rows — Jesse authors the MIT row text and checks the boxes before submission")
        } else {
            Issue.record("NOTICE TODO(Jesse) header not found — the MIT-inbound checklist block is missing")
        }
    }
}
