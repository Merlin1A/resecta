import Testing
import Foundation
@testable import RedactionEngine

// DRAW-1 / plan §0.3 — RedactionRegion polygon Codable invariants.
//
// The schema change adds `public let vertices: [CGPoint]?` to the
// top-level struct (NOT to the `Source` enum). For a top-level struct
// optional field, synthesized struct Codable already decodes a missing
// key as `nil` — the RR-42 custom Codable on `Source` only exists
// because enum-with-optional-associated-value synthesis throws
// `DecodingError.keyNotFound`. The struct's synthesized Codable stays
// (see plan §0.3 and `escalation.md §1.2`).
//
// `testMissingVerticesKeyDecodesAsNil` is the canonical §0.3 guard:
// if a future session "simplifies" the struct to a custom init(from:),
// or adds a non-optional `vertices` field, the test fails immediately.
// Do NOT remove this test.

@Suite("RedactionRegion polygon Codable (DRAW-1)")
struct RedactionRegionPolygonTests {

    @Test("Codable round-trip preserves a 5-vertex polygon")
    func testCodableRoundTripWithVertices() throws {
        let pentagon: [CGPoint] = [
            CGPoint(x: 0.50, y: 0.95),
            CGPoint(x: 0.05, y: 0.65),
            CGPoint(x: 0.20, y: 0.10),
            CGPoint(x: 0.80, y: 0.10),
            CGPoint(x: 0.95, y: 0.65),
        ]
        let region = RedactionRegion(
            id: UUID(),
            normalizedRect: CGRect(x: 0.05, y: 0.10, width: 0.90, height: 0.85),
            source: .manual,
            vertices: pentagon
        )

        let data = try JSONEncoder().encode(region)
        let decoded = try JSONDecoder().decode(RedactionRegion.self, from: data)

        #expect(decoded.id == region.id)
        #expect(decoded.normalizedRect == region.normalizedRect)
        #expect(decoded.vertices != nil, "vertices must round-trip non-nil")
        #expect(decoded.vertices?.count == pentagon.count)
        // CGPoint Codable on Foundation writes [x, y] arrays — comparing
        // by component avoids relying on a specific wire format.
        if let got = decoded.vertices {
            for (i, expected) in pentagon.enumerated() {
                #expect(got[i].x == expected.x,
                        "x mismatch at vertex \(i)")
                #expect(got[i].y == expected.y,
                        "y mismatch at vertex \(i)")
            }
        }
    }

    @Test("Hand-crafted JSON without vertices key decodes with vertices = nil — §0.3 guard")
    func testMissingVerticesKeyDecodesAsNil() throws {
        // Load-bearing per plan §0.3 / escalation.md §1.2. Synthesized
        // struct Codable handles missing optional keys natively — this
        // test pins that behaviour so a future "explicit Codable"
        // refactor cannot regress it without surfacing a test failure.
        //
        // Hand-craft a payload: only `id`, `normalizedRect`, `source`.
        // Build it via dict + JSONSerialization so the CGRect wire
        // format tracks Foundation's shipping shape (currently
        // `[[x, y], [w, h]]`).
        let baseline = RedactionRegion(
            id: UUID(),
            normalizedRect: CGRect(x: 0.10, y: 0.20, width: 0.30, height: 0.40),
            source: .manual
        )
        let encoded = try JSONEncoder().encode(baseline)
        guard var dict = try JSONSerialization.jsonObject(with: encoded)
                as? [String: Any] else {
            Issue.record("baseline did not decode to a dict")
            return
        }
        // Sanity: the encoded payload of a vertices-less region must NOT
        // contain a vertices key (encode skips nil optionals).
        let str = String(data: encoded, encoding: .utf8) ?? ""
        #expect(!str.contains("\"vertices\""),
                "vertices key must not be encoded when nil; encoded=\(str)")
        // And the dict route must agree.
        #expect(dict["vertices"] == nil,
                "fresh-encoded baseline must lack vertices key")

        // Re-serialize from the stripped dict so we explicitly test the
        // "key is absent" case (not just "key is null").
        let stripped = try JSONSerialization.data(withJSONObject: dict)
        let decoded = try JSONDecoder().decode(RedactionRegion.self, from: stripped)

        #expect(decoded.id == baseline.id)
        #expect(decoded.normalizedRect == baseline.normalizedRect)
        #expect(decoded.vertices == nil,
                "synthesized struct Codable must decode absent optional key as nil")
    }

    @Test("Triangle round-trip — minimum polygon size")
    func testTriangleRoundTrip() throws {
        let triangle: [CGPoint] = [
            CGPoint(x: 0.5, y: 0.9),
            CGPoint(x: 0.1, y: 0.1),
            CGPoint(x: 0.9, y: 0.1),
        ]
        let region = RedactionRegion(
            id: UUID(),
            normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8),
            source: .manual,
            vertices: triangle
        )
        let data = try JSONEncoder().encode(region)
        let decoded = try JSONDecoder().decode(RedactionRegion.self, from: data)
        #expect(decoded.vertices?.count == 3)
    }

    @Test("Rectangle region (vertices = nil) co-exists with polygon region")
    func testRectangleAndPolygonRoundTrip() throws {
        let rect = RedactionRegion(
            id: UUID(),
            normalizedRect: CGRect(x: 0, y: 0, width: 0.5, height: 0.5),
            source: .manual
        )
        let poly = RedactionRegion(
            id: UUID(),
            normalizedRect: CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5),
            source: .manual,
            vertices: [
                CGPoint(x: 0.6, y: 0.9),
                CGPoint(x: 0.5, y: 0.5),
                CGPoint(x: 0.9, y: 0.5),
            ]
        )
        let data = try JSONEncoder().encode([rect, poly])
        let decoded = try JSONDecoder().decode([RedactionRegion].self, from: data)
        #expect(decoded.count == 2)
        #expect(decoded[0].vertices == nil)
        #expect(decoded[1].vertices?.count == 3)
    }
}
