import Testing
import Foundation
@testable import RedactionEngine

// Pkg G.2 — TRUST-savedregex-codable-decoder-bypass.
// Pins the codable invariant locks on `SavedRegex`:
//   1. Decoder MUST lock `isBuiltIn = false` regardless of the encoded
//      payload — built-ins are merged in-process from `allBuiltIns`,
//      never deserialized, so a persisted (or out-of-band-edited) blob
//      that claims built-in status must downgrade to user-saved.
//   2. Decoder MUST mirror the memberwise init's clamps on `label`
//      (`labelLengthCap`) and `pattern` (`patternLengthCap`) so the
//      schema floor holds across both construction paths.
@Suite("SavedRegex codable invariant locks (Pkg G.2)")
struct SavedRegexCodableTests {

    private static let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    private static func makeTamperedJSON(
        id: UUID = UUID(),
        label: String = "tampered",
        pattern: String = #"\d+"#,
        isBuiltIn: Bool = true
    ) throws -> Data {
        // ISO-8601 string Foundation's default-strategy decoder won't
        // accept; use the numeric timeIntervalSinceReferenceDate the
        // default encoder emits.
        let blob: [String: Any] = [
            "id": id.uuidString,
            "label": label,
            "pattern": pattern,
            "createdAt": fixedDate.timeIntervalSinceReferenceDate,
            "isBuiltIn": isBuiltIn
        ]
        return try JSONSerialization.data(withJSONObject: blob, options: [])
    }

    @Test("Tampered blob with isBuiltIn=true decodes as user-saved (false)")
    func testTamperedBlobIsBuiltInForcedFalse() throws {
        let data = try Self.makeTamperedJSON(isBuiltIn: true)
        let decoded = try JSONDecoder().decode(SavedRegex.self, from: data)
        #expect(decoded.isBuiltIn == false,
                "Decoder must lock isBuiltIn=false per Jesse Q6 / Pkg G.2")
    }

    @Test("Tampered blob with isBuiltIn=false decodes as user-saved (false)")
    func testHonestBlobIsBuiltInStaysFalse() throws {
        let data = try Self.makeTamperedJSON(isBuiltIn: false)
        let decoded = try JSONDecoder().decode(SavedRegex.self, from: data)
        #expect(decoded.isBuiltIn == false)
    }

    @Test("Decoder clamps label to labelLengthCap")
    func testDecoderClampsLabel() throws {
        let oversizeLabel = String(repeating: "L", count: SavedRegex.labelLengthCap + 50)
        let data = try Self.makeTamperedJSON(label: oversizeLabel, isBuiltIn: false)
        let decoded = try JSONDecoder().decode(SavedRegex.self, from: data)
        #expect(decoded.label.count == SavedRegex.labelLengthCap,
                "Decoder must mirror memberwise init's labelLengthCap clamp")
    }

    @Test("Decoder clamps pattern to patternLengthCap")
    func testDecoderClampsPattern() throws {
        let oversizePattern = String(repeating: "p", count: SavedRegex.patternLengthCap + 100)
        let data = try Self.makeTamperedJSON(pattern: oversizePattern, isBuiltIn: false)
        let decoded = try JSONDecoder().decode(SavedRegex.self, from: data)
        #expect(decoded.pattern.count == SavedRegex.patternLengthCap,
                "Decoder must mirror memberwise init's patternLengthCap clamp")
    }

    @Test("Decoder clamps both label and pattern when both oversize")
    func testDecoderClampsLabelAndPattern() throws {
        let oversizeLabel = String(repeating: "X", count: SavedRegex.labelLengthCap + 64)
        let oversizePattern = String(repeating: "y", count: SavedRegex.patternLengthCap + 64)
        let data = try Self.makeTamperedJSON(
            label: oversizeLabel,
            pattern: oversizePattern,
            isBuiltIn: false
        )
        let decoded = try JSONDecoder().decode(SavedRegex.self, from: data)
        #expect(decoded.label.count == SavedRegex.labelLengthCap)
        #expect(decoded.pattern.count == SavedRegex.patternLengthCap)
    }

    @Test("User-saved round-trip preserves all fields under the clamps")
    func testRoundTripPreservesFields() throws {
        let original = SavedRegex(
            id: UUID(),
            label: "Birth date",
            pattern: #"\b\d{1,2}/\d{1,2}/\d{4}\b"#,
            createdAt: Self.fixedDate,
            isBuiltIn: false
        )
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SavedRegex.self, from: encoded)
        #expect(decoded.id == original.id)
        #expect(decoded.label == original.label)
        #expect(decoded.pattern == original.pattern)
        #expect(decoded.createdAt == original.createdAt)
        #expect(decoded.isBuiltIn == false)
    }

    @Test("In-process built-in memberwise init still flags isBuiltIn=true")
    func testInProcessBuiltInInvariantUnchanged() {
        // Sanity check — the decoder-only lock must not interfere with
        // in-process built-in construction.
        for regex in SavedRegex.allBuiltIns {
            #expect(regex.isBuiltIn == true)
        }
    }

    @Test("Round-trip of a built-in via JSON downgrades to user-saved")
    func testBuiltInRoundTripsAsUserSaved() throws {
        // Defensive: even if a built-in is encoded and decoded (which
        // never happens in production), the decoder downgrades it.
        let builtIn = SavedRegex.builtInCaseNumber
        let encoded = try JSONEncoder().encode(builtIn)
        let decoded = try JSONDecoder().decode(SavedRegex.self, from: encoded)
        #expect(decoded.isBuiltIn == false)
        // Other fields still round-trip cleanly.
        #expect(decoded.id == builtIn.id)
        #expect(decoded.label == builtIn.label)
        #expect(decoded.pattern == builtIn.pattern)
    }
}
