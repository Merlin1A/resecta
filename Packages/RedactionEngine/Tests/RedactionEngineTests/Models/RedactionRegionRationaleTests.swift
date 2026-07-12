import Testing
import Foundation
@testable import RedactionEngine

// WU-71 / [P10] path (a) — Codable round-trip + the load-bearing
// missing-key decode invariant per RR-42. The optional `rationale`
// associated value on `RedactionRegion.Source.detectedPII` /
// `.searchMatch` MUST decode as `nil` when the encoded JSON omits the
// key — the synthesized Codable shape would throw
// `DecodingError.keyNotFound(.rationale, ...)` instead, which is why
// the source file uses a custom `init(from:)` with `decodeIfPresent`.
//
// Test rename: was `backCompatDecode()`. Renamed per audit-3 because
// `RedactionRegion` was never previously Codable — there are no shipped
// fixtures to be back-compatible with. The new name reflects the
// actual assertion: a hand-crafted JSON without the rationale key
// decodes successfully with `rationale == nil`.

@Suite("RedactionRegion rationale Codable (WU-71)")
struct RedactionRegionRationaleTests {

    @Test("Hand-crafted JSON without rationale key decodes with rationale = nil")
    func missingRationaleKeyDecodesAsNil() throws {
        // Load-bearing per RR-42. Synthesized Codable would throw
        // `DecodingError.keyNotFound(.rationale, ...)` for this payload.
        // The custom `init(from:)` uses `decodeIfPresent` so a missing
        // key surfaces as `nil`. Test pin per DEFINITION_OF_DONE
        // engine-WU section.
        //
        // Encode a "rationale-less" region via Codable so the test
        // tracks Apple's CGRect wire format rather than hand-coding it.
        let baseline = RedactionRegion(
            id: UUID(),
            normalizedRect: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4),
            source: .searchMatch(term: "alpha", rationale: nil)
        )
        let encoded = try JSONEncoder().encode(baseline)

        // Sanity check — confirm the encoded blob does NOT carry a
        // `rationale` key at all (encodeIfPresent skips nil).
        let str = String(data: encoded, encoding: .utf8) ?? ""
        #expect(!str.contains("\"rationale\""), "rationale key must NOT be encoded when nil; encoded=\(str)")

        let decoded = try JSONDecoder().decode(RedactionRegion.self, from: encoded)

        switch decoded.source {
        case .searchMatch(let term, let rationale):
            #expect(term == "alpha")
            #expect(rationale == nil, "missing rationale key must decode to nil")
        default:
            Issue.record("decoded.source was not .searchMatch")
        }
    }

    @Test("Hand-crafted JSON for detectedPII without rationale key decodes with nil")
    func missingRationaleKeyDecodesAsNilForDetectedPII() throws {
        let baseline = RedactionRegion(
            id: UUID(),
            normalizedRect: CGRect(x: 0.0, y: 0.0, width: 0.5, height: 0.5),
            source: .detectedPII(kind: .ssn, rationale: nil)
        )
        let encoded = try JSONEncoder().encode(baseline)

        let str = String(data: encoded, encoding: .utf8) ?? ""
        #expect(!str.contains("\"rationale\""), "rationale key must NOT be encoded when nil; encoded=\(str)")

        let decoded = try JSONDecoder().decode(RedactionRegion.self, from: encoded)

        switch decoded.source {
        case .detectedPII(let kind, let rationale):
            #expect(kind == .ssn)
            #expect(rationale == nil)
        default:
            Issue.record("decoded.source was not .detectedPII")
        }
    }

    @Test("Decoder swaps in nil for rationale on a strictly-stripped payload")
    func decoderUsesDecodeIfPresent() throws {
        // Hand-craft a payload with NO `rationale` key. Build the JSON
        // structurally so the CGRect wire format matches the Foundation
        // shipping shape (currently `[[x, y], [w, h]]` per the CGRect
        // Codable extension). If a future Foundation update changes the
        // wire shape, this test pulls from the live encoded baseline so
        // the assertion stays robust.
        let baseline = RedactionRegion(
            id: UUID(),
            normalizedRect: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4),
            source: .searchMatch(term: "alpha", rationale: nil)
        )
        let encoded = try JSONEncoder().encode(baseline)
        guard var dict = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
            Issue.record("baseline did not decode to a dict")
            return
        }
        // Build a fresh "source" dict that excludes any `rationale` key —
        // verifies the load-bearing claim that decodeIfPresent works on a
        // dictionary that genuinely lacks the key (not just one where the
        // value is `null`).
        dict["source"] = ["type": "searchMatch", "term": "alpha"]
        let stripped = try JSONSerialization.data(withJSONObject: dict)

        let decoded = try JSONDecoder().decode(RedactionRegion.self, from: stripped)
        switch decoded.source {
        case .searchMatch(let term, let rationale):
            #expect(term == "alpha")
            #expect(rationale == nil, "decodeIfPresent must surface nil for absent key")
        default:
            Issue.record("decoded.source was not .searchMatch")
        }
    }

    @Test("New RedactionRegion round-trips rationale through Codable")
    func roundTripWithRationale() throws {
        let rationale = MatchRationale(
            ruleID: "ssn.state-machine",
            signals: [.regexPattern(name: "ssn.sep")],
            preThresholdScore: 0.72,
            finalScore: 0.85,
            appliedThreshold: 0.6
        )
        let region = RedactionRegion(
            id: UUID(),
            normalizedRect: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4),
            source: .searchMatch(term: "123-45-6789", rationale: rationale)
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(region)
        let decoded = try JSONDecoder().decode(RedactionRegion.self, from: data)

        #expect(decoded.id == region.id)
        #expect(decoded.normalizedRect == region.normalizedRect)
        switch decoded.source {
        case .searchMatch(let term, let decodedRationale):
            #expect(term == "123-45-6789")
            #expect(decodedRationale == rationale, "rationale must round-trip equal")
        default:
            Issue.record("decoded.source was not .searchMatch")
        }
    }

    @Test("Manual + detectedFace cases round-trip without rationale fields")
    func manualAndFaceRoundTrip() throws {
        let manual = RedactionRegion(
            id: UUID(),
            normalizedRect: .zero,
            source: .manual
        )
        let face = RedactionRegion(
            id: UUID(),
            normalizedRect: .zero,
            source: .detectedFace
        )
        let data = try JSONEncoder().encode([manual, face])
        let decoded = try JSONDecoder().decode([RedactionRegion].self, from: data)
        #expect(decoded.count == 2)
        #expect(decoded[0].source == .manual)
        #expect(decoded[1].source == .detectedFace)
    }
}
