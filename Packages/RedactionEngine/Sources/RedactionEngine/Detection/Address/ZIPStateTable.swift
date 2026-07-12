import Foundation

// Plan §4 — SCF (Sectional Center Facility) prefix → state mapping, used by
// AddressSpatialAssembler to reject ZIP/state inconsistencies ("X Main St,
// TX 02134"). Source: USPS SCF public-domain assignments. Coverage aims to
// answer "does state X own a ZIP starting with 3-digit prefix Y?" — regions
// not in the switch return nil (no cross-check, rather than a false reject).
//
// L6 / C12 — primary source is now `zip_scf_states.json` via
// `ZIPStateTableLoader`. The hardcoded switch below remains as the
// graceful-degradation fallback when the JSON is missing or fails to decode
// (same pattern as `DocumentTypeClassifier.loadData(from:)`).
//
// W-Q (§D12 = L3 full) — `state(forZIP:userOverrides:)` accepts a
// per-profile user-overrides map (5-digit ZIP → 2-letter state). User
// entries are checked first under P1 semantics; the shipped+SCF lookup
// continues through the cached singleton loader. Callers that don't have
// a per-profile context (e.g. the prefix-only `AddressSpatialAssembler`
// caller at line 103) keep their existing surface — the default empty
// dictionary preserves prior behavior verbatim.

enum ZIPStateTable {

    private static let loader: ZIPStateTableLoader? = try? ZIPStateTableLoader()

    /// Map a 3-digit ZIP prefix string to a 2-letter state code.
    /// Returns nil for unknown prefixes — callers treat nil as "no cross-check".
    static func state(forZIPPrefix prefix: String) -> String? {
        if let loader, let hit = loader.state(forZIPPrefix: prefix) {
            return hit
        }
        guard let n = Int(prefix), prefix.count == 3 else { return nil }
        return state(forPrefixCode: n)
    }

    /// Overload for a full 5-digit ZIP — resolves in three tiers under P1
    /// semantics: per-profile `userOverrides` → shipped 5-digit overrides
    /// → 3-digit SCF prefix. The default empty `userOverrides` preserves
    /// shipped+SCF behavior for callers without a profile context.
    static func state(forZIP zip: String, userOverrides: [String: String] = [:]) -> String? {
        let trimmed = zip.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = trimmed.prefix { $0.isWholeNumber }
        if !userOverrides.isEmpty, digits.count >= 5,
           let hit = userOverrides[String(digits.prefix(5))] {
            return hit
        }
        if let loader, let hit = loader.state(forZIP: zip) {
            return hit
        }
        guard digits.count >= 3 else { return nil }
        return state(forZIPPrefix: String(digits.prefix(3)))
    }

    // swiftlint:disable cyclomatic_complexity function_body_length
    private static func state(forPrefixCode n: Int) -> String? {
        switch n {
        case 5, 6, 7, 9:       return "PR"
        case 8:                return "VI"
        case 10...27:          return "MA"
        case 28, 29:           return "RI"
        case 30...38:          return "NH"
        case 39:               return "ME"  // sparse
        case 40...49:          return "ME"
        case 50...54:          return "VT"
        case 55...59:          return "NH"  // overflow
        case 60...69:          return "CT"
        case 70...89:          return "NJ"
        case 100...104:        return "NY"  // NYC
        case 105...119:        return "NY"
        case 120...149:        return "NY"
        case 150...196:        return "PA"
        case 197...199:        return "DE"
        case 200, 202...205:   return "DC"
        case 201, 220...246:   return "VA"
        case 206...219:        return "MD"
        case 247...268:        return "WV"
        case 270...289:        return "NC"
        case 290...299:        return "SC"
        case 300...319:        return "GA"
        case 320...349:        return "FL"
        case 350...369:        return "AL"
        case 370...385:        return "TN"
        case 386...397:        return "MS"
        case 398...399:        return "GA"  // overflow
        case 400...427:        return "KY"
        case 430...459:        return "OH"
        case 460...479:        return "IN"
        case 480...499:        return "MI"
        case 500...528:        return "IA"
        case 530...549:        return "WI"
        case 550...567:        return "MN"
        case 570...577:        return "SD"
        case 580...588:        return "ND"
        case 590...599:        return "MT"
        case 600...629:        return "IL"
        case 630...658:        return "MO"
        case 660...679:        return "KS"
        case 680...693:        return "NE"
        case 700...714:        return "LA"
        case 716...729:        return "AR"
        case 730...749:        return "OK"
        case 750...799, 885:   return "TX"
        case 800...816:        return "CO"
        case 820...831:        return "WY"
        case 832...838:        return "ID"
        case 840...847:        return "UT"
        case 850...865:        return "AZ"
        case 870...884:        return "NM"
        case 889...898:        return "NV"
        case 900...961:        return "CA"
        case 967...968:        return "HI"
        case 970...979:        return "OR"
        case 980...994:        return "WA"
        case 995...999:        return "AK"
        default:               return nil
        }
    }
    // swiftlint:enable cyclomatic_complexity function_body_length
}
