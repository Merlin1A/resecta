import Testing
import Foundation

// Apache License 2.0 Section 4(d) NOTICE.
//
// A NOTICE file carries the propagated attribution entries for the
// gazetteer / Bloom / classifier artifacts bundled in the iOS app. The
// NOTICE skeleton lands now with the two confirmed pipeline rows
// (OpenStreetMap ODbL, OpenAddresses CC0); the MIT / courtesy rows land at
// the version tag.
//
// These guards pin the file's existence and its two confirmed attributions so
// the spec claim stays true and a future edit cannot silently drop them. The
// NOTICE lives at the repo root (the Apache convention; it is a distribution /
// source-tree file, not a bundled resource), so it is read via #filePath.
@Suite("Apache NOTICE attribution")
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

    // MARK: - Manifest-driven license classification
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
    // copyright + permission notice to propagate into this distribution; CC BY
    // 4.0 requires the attribution, the license name and a note of the changes.
    private enum SourceLicense { case publicDomain, cc0, mit, ccBy4 }

    @Test("Every gazetteer-manifest source is license-classified; MIT inbound is attributed")
    func testManifestSourcesClassifiedAndAttributed() throws {
        let contents = try noticeContents()
        let tokens = try manifestSourceTokens()

        #expect(!tokens.isEmpty, "gazetteer-manifest.json named no sources — manifest unreadable or empty")

        // Explicit token -> license table, verified against
        // resecta-datapipeline/SOURCES.md (2026-10-15). NOTE: popnames is CC0,
        // not "public-domain" as earlier approximated — CC0 is
        // likewise a no-attribution-required class, so the NOTICE needs no
        // popnames row. The ParaNames rows (CC BY 4.0: the data's license, the
        // code is MIT) drive the required substrings.
        let sourceLicenses: [String: SourceLicense] = [
            "census_spanish": .publicDomain,
            "census_spanish_full": .publicDomain,
            "census_surnames": .publicDomain,
            "ssa_given_names": .publicDomain,
            "popnames": .cc0,
            "popnames_common_surnames": .cc0,
            "popnames_common_forenames": .cc0,
            "paranames": .ccBy4,
            "paranames_full": .ccBy4,
        ]
        // Attribution-bearing source token -> the substrings its NOTICE row
        // carries: the upstream name and, for CC BY 4.0, the license name.
        let attributionSubstrings: [String: [String]] = [
            "paranames": ["bltlab/paranames", "Creative Commons Attribution 4.0"],
            "paranames_full": ["bltlab/paranames", "Creative Commons Attribution 4.0"],
        ]

        for token in tokens.sorted() {
            guard let license = sourceLicenses[token] else {
                // Fail-loud net: a new gazetteer source must be classified (and,
                // if attribution-bearing, given a NOTICE row) before it ships.
                Issue.record("Unclassified gazetteer-manifest source '\(token)' — add it to the license table and, if attribution-bearing, to NOTICE")
                continue
            }
            if license == .mit || license == .ccBy4, let required = attributionSubstrings[token] {
                for substring in required {
                    #expect(
                        contents.contains(substring),
                        "NOTICE missing the attribution for manifest source '\(token)' (expected substring '\(substring)')")
                }
            }
        }
        // The ParaNames row names the data's license, not the code's: the old
        // MIT row label must not survive.
        #expect(
            !contents.contains("bltlab/paranames (MIT)"),
            "NOTICE still labels ParaNames MIT — its data is CC BY 4.0")

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

        // The bundled sample document embeds subsets of the Inter typeface
        // (SIL Open Font License 1.1): the copyright holder and the license
        // name are pinned beside the data rows.
        #expect(
            contents.contains("The Inter Project Authors"),
            "NOTICE missing the Inter typeface copyright holder (The Inter Project Authors)")
        #expect(
            contents.contains("SIL Open Font License"),
            "NOTICE missing the Inter typeface license name (SIL Open Font License)")
    }

    @Test("MIT inbound NOTICE rows are authored and discharged")
    func testMITInboundAttributionDischarged() throws {
        let contents = try noticeContents()

        // The MIT license body must propagate, not just the copyright line: a
        // compliant MIT notice reproduces the permission grant verbatim.
        #expect(
            contents.contains("Permission is hereby granted, free of charge"),
            "NOTICE lacks the MIT permission notice — the Faker / paranames rows are not yet authored")

        // Every attribution checklist row must be discharged: no unchecked
        // `[ ]` marker may remain anywhere in NOTICE once the MIT rows are
        // authored and the artifacts confirmed.
        #expect(!contents.contains("[ ]"), "NOTICE still has an unchecked attribution row — the MIT row text and checkboxes must be completed before submission")
    }
}
