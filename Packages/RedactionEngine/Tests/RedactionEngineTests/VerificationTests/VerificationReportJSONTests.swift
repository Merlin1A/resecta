import Testing
import Foundation
@testable import RedactionEngine

// H2.1 — pins the VerificationReport evidence wire format (schema_version 1).
// The golden below is byte-exact: `.sortedKeys` + `.prettyPrinted` make the
// encoding canonical, so any drift in the mirror structs (a renamed key, a
// reordered field, a changed case name) shows up as a line-level diff here
// before it silently forks the evidence corpus.

@Suite("VerificationReport JSON serializer (H2.1)")
struct VerificationReportJSONTests {

    private func json(_ report: VerificationReport) throws -> [String: Any] {
        let data = try report.jsonData()
        let obj = try JSONSerialization.jsonObject(with: data)
        return try #require(obj as? [String: Any])
    }

    // MARK: - Golden

    @Test("3-layer synthetic report matches the byte-exact golden")
    func goldenThreeLayerReport() throws {
        let report = VerificationReport(
            layers: [
                LayerResult(
                    name: "Text Extraction",
                    symbolName: "doc.text.magnifyingglass",
                    status: .pass,
                    shortDescription: "Clean text layer",
                    detailDescription: "No sensitive text found in the text layer.",
                    pageReferences: nil,
                    durationSeconds: 0.25
                ),
                LayerResult(
                    name: "Term Sweep",
                    symbolName: "exclamationmark.magnifyingglass",
                    status: .attention("1 applied term remains readable outside its region"),
                    shortDescription: "1 term needs review",
                    detailDescription: "An applied term remains readable outside every redacted region.",
                    pageReferences: [2, 5],
                    durationSeconds: 0.5,
                    reviewTermTexts: ["ACME-1234"]
                ),
                LayerResult(
                    name: "OCR Check",
                    symbolName: "eye.trianglebadge.exclamationmark",
                    status: .fail("residual text detected"),
                    shortDescription: "Residual text detected",
                    detailDescription: "Residual sensitive text detected in the output.",
                    pageReferences: [0],
                    durationSeconds: 0.125
                ),
            ],
            overallStatus: .fail("residual text detected"),
            durationSeconds: 0.875,
            perPageModes: [.searchableRedaction, .secureRasterization],
            perPageFallbackReasons: [nil, .noExtractableText],
            userOverrodeFailure: true
        )

        let golden = """
        {
          "duration_s" : 0.875,
          "layers" : [
            {
              "detail" : "No sensitive text found in the text layer.",
              "duration_s" : 0.25,
              "index" : 0,
              "name" : "Text Extraction",
              "short" : "Clean text layer",
              "status" : {
                "case" : "pass"
              },
              "symbol" : "doc.text.magnifyingglass"
            },
            {
              "detail" : "An applied term remains readable outside every redacted region.",
              "duration_s" : 0.5,
              "index" : 1,
              "name" : "Term Sweep",
              "pages" : [
                2,
                5
              ],
              "review_terms" : [
                "ACME-1234"
              ],
              "short" : "1 term needs review",
              "status" : {
                "case" : "attention",
                "message" : "1 applied term remains readable outside its region"
              },
              "symbol" : "exclamationmark.magnifyingglass"
            },
            {
              "detail" : "Residual sensitive text detected in the output.",
              "duration_s" : 0.125,
              "index" : 2,
              "name" : "OCR Check",
              "pages" : [
                0
              ],
              "short" : "Residual text detected",
              "status" : {
                "case" : "fail",
                "message" : "residual text detected"
              },
              "symbol" : "eye.trianglebadge.exclamationmark"
            }
          ],
          "overall" : {
            "case" : "fail",
            "message" : "residual text detected"
          },
          "per_page_fallback_reasons" : [
            null,
            "noExtractableText"
          ],
          "per_page_modes" : [
            "searchableRedaction",
            "secureRasterization"
          ],
          "schema_version" : 1,
          "skip_reason" : "autoVerifyOff",
          "user_acknowledged_skipped_share" : false,
          "user_overrode_failure" : true
        }
        """

        let actual = try #require(String(data: report.jsonData(), encoding: .utf8))
        if actual != golden {
            print("[H2.1 golden mismatch] actual output:\n\(actual)")
        }
        #expect(actual == golden)
    }

    // MARK: - Determinism

    @Test("encoding is byte-deterministic across invocations")
    func deterministicEncoding() throws {
        let report = VerificationReport(
            layers: [
                LayerResult(name: "L", symbolName: "s", status: .warn("w"),
                            shortDescription: "sh", detailDescription: "d",
                            pageReferences: [1], durationSeconds: 0.5),
            ],
            overallStatus: .warn("w"), durationSeconds: 0.5
        )
        #expect(try report.jsonData() == report.jsonData())
    }

    // MARK: - Status cases round-trip by name

    @Test("every VerificationStatus case round-trips by name", arguments: [
        (VerificationStatus.pass, "pass", nil),
        (.warn("wm"), "warn", "wm"),
        (.info("im"), "info", "im"),
        (.attention("am"), "attention", "am"),
        (.fail("fm"), "fail", "fm"),
        (.skipped, "skipped", nil),
    ] as [(VerificationStatus, String, String?)])
    func statusCaseRoundTrips(status: VerificationStatus, caseName: String, message: String?) throws {
        let report = VerificationReport(
            layers: [
                LayerResult(name: "L", symbolName: "s", status: status,
                            shortDescription: "sh", detailDescription: "d",
                            pageReferences: nil, durationSeconds: 0.5),
            ],
            overallStatus: status, durationSeconds: 0.5
        )
        let obj = try json(report)

        let overall = try #require(obj["overall"] as? [String: Any])
        #expect(overall["case"] as? String == caseName)
        #expect(overall["message"] as? String == message)

        let layers = try #require(obj["layers"] as? [[String: Any]])
        let layerStatus = try #require(layers[0]["status"] as? [String: Any])
        #expect(layerStatus["case"] as? String == caseName)
        #expect(layerStatus["message"] as? String == message)
    }

    // MARK: - Skip reasons

    @Test("skipped(reason:) shapes", arguments: [
        (VerificationReport.SkipReason.autoVerifyOff, "autoVerifyOff"),
        (.cancelled, "cancelled"),
        (.error, "error"),
    ] as [(VerificationReport.SkipReason, String)])
    func skipReasonShape(reason: VerificationReport.SkipReason, name: String) throws {
        let obj = try json(VerificationReport.skipped(reason: reason))
        #expect(obj["skip_reason"] as? String == name)
        let overall = try #require(obj["overall"] as? [String: Any])
        #expect(overall["case"] as? String == "skipped")
        #expect((obj["layers"] as? [Any])?.isEmpty == true)
    }

    @Test("the .skipped sentinel carries the default autoVerifyOff reason")
    func skippedSentinelDefaultReason() throws {
        let obj = try json(VerificationReport.skipped)
        #expect(obj["skip_reason"] as? String == "autoVerifyOff")
    }

    // MARK: - Fallback reasons

    @Test("all 7 FallbackReason cases encode by name; nil entries stay null")
    func fallbackReasonNames() throws {
        let reasons: [TextLayerDetector.FallbackReason?] = [
            .noExtractableText, .cjkEncodingFailure, .rtlText, .verticalText,
            .zeroSizeBounds, .unresolvedEncoding, .extractionFailed, nil,
        ]
        let report = VerificationReport(
            layers: [], overallStatus: .pass, durationSeconds: 0.5,
            perPageModes: Array(repeating: .searchableRedaction, count: reasons.count),
            perPageFallbackReasons: reasons
        )
        let obj = try json(report)
        let encoded = try #require(obj["per_page_fallback_reasons"] as? [Any])
        #expect(encoded.count == 8)
        let names = encoded.map { $0 as? String }
        #expect(names == [
            "noExtractableText", "cjkEncodingFailure", "rtlText", "verticalText",
            "zeroSizeBounds", "unresolvedEncoding", "extractionFailed", nil,
        ])
    }

    @Test("per-page modes encode as their raw values")
    func pipelineModeRawValues() throws {
        let report = VerificationReport(
            layers: [], overallStatus: .pass, durationSeconds: 0.5,
            perPageModes: [.secureRasterization, .searchableRedaction]
        )
        let obj = try json(report)
        #expect(obj["per_page_modes"] as? [String] == ["secureRasterization", "searchableRedaction"])
    }
}
