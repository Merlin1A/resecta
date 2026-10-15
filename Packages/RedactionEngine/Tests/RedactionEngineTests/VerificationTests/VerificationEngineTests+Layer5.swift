import Testing
import Foundation
import PDFKit
import CoreGraphics
import CoreText
@testable import RedactionEngine

extension VerificationEngineTests {

    // MARK: - Layer 5: Metadata Verification

    @Test("Layer 5 reports Apple auto-injected metadata as info")
    func layer5InfoOnAutoInjected() async throws {
        let (doc, url) = try await makeCleanPDF()
        defer { try? FileManager.default.removeItem(at: url) }

        let engine = VerificationEngine()
        let result = await engine.runLayer(
            .metadataCheck, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 1, regions: [:], sensitiveTerms: [],
            pipelineMode: .secureRasterization,
            filterDigests: [], perPageModes: [.secureRasterization]
        )
        // CGPDFContext auto-injects /Producer, /CreationDate — expect INFO
        // (post-split: only auto-injected → .info; /Trapped or XMP → .warn).
        #expect(result.status == .info("") || result.status == .pass,
                "Should report auto-injected metadata as info or pass if none present")
    }

    @Test("Layer 5 /Trapped WARN says Metadata present, not auto-injected")
    func trappedWarnCopyNotAutoInjected() async throws {
        // /Trapped is workflow-set, not auto-injected — the mixed-warning
        // message must not claim auto-injection when it names /Trapped.
        let (doc, url) = try TestFixtures.writeTempPDF(
            TestFixtures.withMetadataRaw(infoDictBody: "/Trapped /True"),
            prefix: "trapped_copy_")
        defer { try? FileManager.default.removeItem(at: url) }

        let engine = VerificationEngine()
        let result = await engine.runLayer(
            .metadataCheck, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 1, regions: [:], sensitiveTerms: [],
            pipelineMode: .secureRasterization,
            filterDigests: [], perPageModes: [.secureRasterization]
        )
        #expect(result.status.isWarn, "/Trapped must WARN; got \(result.status)")
        if case .warn(let msg) = result.status {
            #expect(msg == "Metadata present: /Trapped",
                    "/Trapped WARN copy must not say auto-injected; got \(msg)")
        }
    }

    @Test("Layer 5 expected-keys-only INFO copy unchanged when the producer carries the fixed value")
    func expectedKeysOnlyInfoCopyUnchanged() async throws {
        // Producer/CreationDate/ModDate ARE auto-injected — the pure-INFO
        // path keeps the auto-injected wording once the producer literal
        // reads back as the writer's fixed value.
        let (doc, url) = try TestFixtures.writeTempPDF(
            TestFixtures.withMetadataRaw(
                infoDictBody: "/Producer (\(PDFStreamReconstructor.fixedProducerValue))"),
            prefix: "producer_info_")
        defer { try? FileManager.default.removeItem(at: url) }

        let engine = VerificationEngine()
        let result = await engine.runLayer(
            .metadataCheck, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 1, regions: [:], sensitiveTerms: [],
            pipelineMode: .secureRasterization,
            filterDigests: [], perPageModes: [.secureRasterization]
        )
        #expect(result.status == .pass,
                "Expected keys only fold to PASS with a detail; got \(result.status)")
        #expect(result.detailDescription == VerificationEngine.layer5FixedFieldsDetail,
                "the detail names the mechanism; got \(result.detailDescription)")
        #expect(result.shortDescription == "No issues found.")
    }

    @Test("Layer 5 WARNs when the producer field was not rewritten to the fixed value")
    func producerNotRewrittenWarns() async throws {
        // A producer literal that still carries a writer's own string means
        // the post-write rewrite did not happen (it leaves the file untouched
        // on any anomaly and only logs). Layer 5 reports that instead of
        // filing the key under auto-injected metadata.
        let (doc, url) = try TestFixtures.writeTempPDF(
            TestFixtures.withMetadataRaw(infoDictBody: "/Producer (SyntheticWriter)"),
            prefix: "producer_not_rewritten_")
        defer { try? FileManager.default.removeItem(at: url) }

        let engine = VerificationEngine()
        let result = await engine.runLayer(
            .metadataCheck, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 1, regions: [:], sensitiveTerms: [],
            pipelineMode: .secureRasterization,
            filterDigests: [], perPageModes: [.secureRasterization]
        )
        #expect(result.status.isWarn,
                "A producer value other than the fixed one must WARN; got \(result.status)")
        if case .warn(let msg) = result.status {
            #expect(msg == "Producer or timestamp fields were not rewritten to the fixed values",
                    "Attestation WARN copy; got \(msg)")
        }
    }

    @Test("Layer 5 producer WARN never echoes the producer value")
    func producerWarnNeverEchoesValue() async throws {
        let writerString = "SyntheticWriter 99.9 (Build ZZ999) PDFContext"
        let (doc, url) = try TestFixtures.writeTempPDF(
            TestFixtures.withMetadataRaw(infoDictBody: "/Producer (\(writerString))"),
            prefix: "producer_no_echo_")
        defer { try? FileManager.default.removeItem(at: url) }

        let engine = VerificationEngine()
        let result = await engine.runLayer(
            .metadataCheck, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 1, regions: [:], sensitiveTerms: [],
            pipelineMode: .secureRasterization,
            filterDigests: [], perPageModes: [.secureRasterization]
        )
        #expect(result.status.isWarn, "got \(result.status)")
        if case .warn(let msg) = result.status {
            for fragment in ["SyntheticWriter", "99.9", "ZZ999", "PDFContext"] {
                #expect(!msg.contains(fragment),
                        "the WARN must not carry the producer value; got \(msg)")
            }
        }
        #expect(result.detailDescription.contains("SyntheticWriter") == false)
    }

    @Test("Layer 5 tolerates trailing spaces inside the producer literal")
    func producerTrailingSpacesTolerated() async throws {
        // The rewrite pads after the closing paren, so a real export decodes
        // to the bare fixed value; padding inside the literal is still the
        // fixed value and stays INFO.
        let (doc, url) = try TestFixtures.writeTempPDF(
            TestFixtures.withMetadataRaw(
                infoDictBody: "/Producer (\(PDFStreamReconstructor.fixedProducerValue)    )"),
            prefix: "producer_padded_")
        defer { try? FileManager.default.removeItem(at: url) }

        let engine = VerificationEngine()
        let result = await engine.runLayer(
            .metadataCheck, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 1, regions: [:], sensitiveTerms: [],
            pipelineMode: .secureRasterization,
            filterDigests: [], perPageModes: [.secureRasterization]
        )
        #expect(result.status == .pass,
                "Trailing spaces inside the literal must not WARN; got \(result.status)")
        #expect(result.detailDescription == VerificationEngine.layer5FixedFieldsDetail)
    }

    @Test("Layer 5 attests the fixed producer and dates on real reconstructed output")
    func producerAttestedOnReconstructedOutput() async throws {
        // The reconstructor's finalize step rewrites the writer's producer
        // literal and both date literals in place; the metadata check reads
        // all three back as the fixed values and reports the three
        // auto-injected keys as INFO, not WARN.
        let (doc, url) = try await makeCleanPDF()
        defer { try? FileManager.default.removeItem(at: url) }

        let engine = VerificationEngine()
        let result = await engine.runLayer(
            .metadataCheck, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 1, regions: [:], sensitiveTerms: [],
            pipelineMode: .secureRasterization,
            filterDigests: [], perPageModes: [.secureRasterization]
        )
        #expect(result.status == .pass,
                "Real output attests the fixed producer as PASS with a detail; got \(result.status)")
        #expect(result.detailDescription == VerificationEngine.layer5FixedFieldsDetail,
                "the fixed-value case carries the detail; got \(result.detailDescription)")
    }

    @Test("Layer 5 WARNs when a timestamp field was not rewritten to the fixed value")
    func timestampNotRewrittenWarns() async throws {
        // A date literal still carrying the writer's export moment means the
        // post-write rewrite left it untouched (an unexpected length, or a
        // future writer change). Either date alone is enough to WARN; the
        // producer beside it carries the fixed value.
        let fixedProducer = PDFStreamReconstructor.fixedProducerValue
        let fixedDate = PDFStreamReconstructor.fixedDateValue
        let liveDate = "D:20260906212041Z00'00'"
        let bodies = [
            "/Producer (\(fixedProducer)) /CreationDate (\(liveDate)) /ModDate (\(fixedDate))",
            "/Producer (\(fixedProducer)) /CreationDate (\(fixedDate)) /ModDate (\(liveDate))",
        ]
        for body in bodies {
            let (doc, url) = try TestFixtures.writeTempPDF(
                TestFixtures.withMetadataRaw(infoDictBody: body),
                prefix: "timestamp_not_rewritten_")
            defer { try? FileManager.default.removeItem(at: url) }

            let engine = VerificationEngine()
            let result = await engine.runLayer(
                .metadataCheck, outputDocument: SendablePDFDocument(doc),
                sourcePageCount: 1, regions: [:], sensitiveTerms: [],
                pipelineMode: .secureRasterization,
                filterDigests: [], perPageModes: [.secureRasterization]
            )
            #expect(result.status.isWarn,
                    "A date other than the fixed one must WARN; got \(result.status)")
            if case .warn(let msg) = result.status {
                #expect(msg == "Producer or timestamp fields were not rewritten to the fixed values",
                        "Attestation WARN copy; got \(msg)")
            }
        }
    }

    @Test("Layer 5 timestamp WARN never echoes the date value")
    func timestampWarnNeverEchoesValue() async throws {
        let liveDate = "D:20260906212041Z00'00'"
        let (doc, url) = try TestFixtures.writeTempPDF(
            TestFixtures.withMetadataRaw(
                infoDictBody: "/Producer (\(PDFStreamReconstructor.fixedProducerValue)) "
                    + "/CreationDate (\(liveDate)) /ModDate (\(liveDate))"),
            prefix: "timestamp_no_echo_")
        defer { try? FileManager.default.removeItem(at: url) }

        let engine = VerificationEngine()
        let result = await engine.runLayer(
            .metadataCheck, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 1, regions: [:], sensitiveTerms: [],
            pipelineMode: .secureRasterization,
            filterDigests: [], perPageModes: [.secureRasterization]
        )
        #expect(result.status.isWarn, "got \(result.status)")
        if case .warn(let msg) = result.status {
            for fragment in ["2026", "0906", "212041", "D:"] {
                #expect(!msg.contains(fragment),
                        "the WARN must not carry the date; got \(msg)")
            }
        }
        #expect(result.detailDescription.contains("212041") == false)
    }

    @Test("Layer 5 reports all three fixed writer fields as INFO, byte-exact")
    func fixedWriterFieldsInfoByteExact() async throws {
        // Fixture spelled as the writer's rewritten output: the fixed producer
        // and both dates at the fixed value. The three keys ride in the INFO
        // composition in the check's own order; nothing WARNs.
        let fixedProducer = PDFStreamReconstructor.fixedProducerValue
        let fixedDate = PDFStreamReconstructor.fixedDateValue
        let (doc, url) = try TestFixtures.writeTempPDF(
            TestFixtures.withMetadataRaw(
                infoDictBody: "/CreationDate (\(fixedDate)) /Producer (\(fixedProducer)) /ModDate (\(fixedDate))"),
            prefix: "fixed_fields_info_")
        defer { try? FileManager.default.removeItem(at: url) }

        let engine = VerificationEngine()
        let result = await engine.runLayer(
            .metadataCheck, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 1, regions: [:], sensitiveTerms: [],
            pipelineMode: .secureRasterization,
            filterDigests: [], perPageModes: [.secureRasterization]
        )
        #expect(result.status == .pass,
                "All three fixed values fold to PASS with a detail; got \(result.status)")
        #expect(result.detailDescription == VerificationEngine.layer5FixedFieldsDetail,
                "the fixed-value case carries the detail; got \(result.detailDescription)")
        #expect(result.hasDetail)
    }

    // MARK: - Layer 5: XMP-without-/Info and non-string key presence

    @Test("Layer 5 scans XMP even when /Info is absent")
    func xmpScannedWhenInfoAbsent() async throws {
        // Fixture has an XMP /Metadata stream but no /Info dictionary. Pre-fix
        // the nil-/Info guard returned .pass before the XMP scan ran (red).
        let (doc, url) = try TestFixtures.writeTempPDF(
            TestFixtures.withXMPNoInfo(), prefix: "xmp_no_info_")
        defer { try? FileManager.default.removeItem(at: url) }

        let engine = VerificationEngine()
        let result = await engine.runLayer(
            .metadataCheck, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 1, regions: [:], sensitiveTerms: [],
            pipelineMode: .secureRasterization,
            filterDigests: [], perPageModes: [.secureRasterization]
        )
        #expect(result.status.isWarn,
                "XMP present with no /Info must WARN, not silently pass; got \(result.status)")
        if case .warn(let msg) = result.status {
            #expect(msg.contains("XMP"), "WARN message should name XMP; got \(msg)")
        }
    }

    @Test("Layer 5 FAILs on a non-string /Info value")
    func nonStringTitleValueFails() async throws {
        // /Title is an INTEGER (42). Pre-fix the GetString/GetName pair both
        // returned false for an integer value → fell through as "absent" (red).
        let (doc, url) = try TestFixtures.writeTempPDF(
            TestFixtures.withMetadataRaw(infoDictBody: "/Title 42"),
            prefix: "title_int_")
        defer { try? FileManager.default.removeItem(at: url) }

        let engine = VerificationEngine()
        let result = await engine.runLayer(
            .metadataCheck, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 1, regions: [:], sensitiveTerms: [],
            pipelineMode: .secureRasterization,
            filterDigests: [], perPageModes: [.secureRasterization]
        )
        #expect(result.status == .fail("Metadata key /Title present"),
                "Integer /Title value must FAIL on key presence; got \(result.status)")
    }

    @Test("Layer 5 WARNs when the /ID pair was not derived from the file's contents")
    func layer5WarnsOnFileIdentifierNotDerived() async throws {
        // A real output attests (the INFO path stays, pinned by
        // producerAttestedOnReconstructedOutput). Flip one hex character of
        // the first payload and the metadata check must report the pair as
        // not derived — with a constant message that carries no value.
        let (_, url) = try await makeCleanPDF()
        defer { try? FileManager.default.removeItem(at: url) }
        var data = try Data(contentsOf: url)
        let pair = try #require(FileIdentifierOracle.pair(in: data), "the writer's /ID pair must be in the tail")
        let index = pair.first.lowerBound
        data[index] = data[index] == UInt8(ascii: "0") ? UInt8(ascii: "1") : UInt8(ascii: "0")
        let tamperedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("verify_fileid_tampered_\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: tamperedURL) }
        try data.write(to: tamperedURL)
        let doc = try #require(PDFDocument(url: tamperedURL))

        let engine = VerificationEngine()
        let result = await engine.runLayer(
            .metadataCheck, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 1, regions: [:], sensitiveTerms: [],
            pipelineMode: .secureRasterization,
            filterDigests: [], perPageModes: [.secureRasterization]
        )
        #expect(result.status.isWarn, "a pair that is not the content digest must WARN; got \(result.status)")
        if case .warn(let msg) = result.status {
            #expect(msg == "File identifier was not derived from the file contents", "\(msg)")
            #expect(!msg.contains(FileIdentifierOracle.hex(data, pair.first)))
        }
        #expect(result.couldNotVerify == false, "an attestation mismatch is a note, not a could-not-verify")
    }
}
