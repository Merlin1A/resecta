import Foundation

// Plan §5 — string similarity metrics for entity clustering. All three
// metrics return values in [0.0, 1.0]; the cluster rule unions on
// max(jaroWinkler, tokenSort, initialism) ≥ 0.70.

enum JaroWinkler {

    /// Classic Jaro-Winkler similarity. Prefix scale 0.1 (standard), max
    /// prefix length 4.
    static func similarity(_ a: String, _ b: String, prefixScale: Double = 0.1) -> Double {
        let aArr = Array(a.lowercased())
        let bArr = Array(b.lowercased())
        guard !aArr.isEmpty && !bArr.isEmpty else { return 0 }
        if aArr == bArr { return 1 }

        let matchWindow = max(aArr.count, bArr.count) / 2 - 1
        let window = max(matchWindow, 0)

        var aMatches = Array(repeating: false, count: aArr.count)
        var bMatches = Array(repeating: false, count: bArr.count)
        var matchCount = 0

        for i in 0..<aArr.count {
            let start = max(0, i - window)
            let end = min(bArr.count, i + window + 1)
            guard start < end else { continue }
            for j in start..<end {
                if !bMatches[j], aArr[i] == bArr[j] {
                    aMatches[i] = true
                    bMatches[j] = true
                    matchCount += 1
                    break
                }
            }
        }
        guard matchCount > 0 else { return 0 }

        var transpositions = 0
        var k = 0
        for i in 0..<aArr.count where aMatches[i] {
            while !bMatches[k] { k += 1 }
            if aArr[i] != bArr[k] { transpositions += 1 }
            k += 1
        }
        let t = Double(transpositions) / 2

        let mDouble = Double(matchCount)
        let jaro = (mDouble / Double(aArr.count) +
                    mDouble / Double(bArr.count) +
                    (mDouble - t) / mDouble) / 3

        // Prefix boost — up to 4 leading characters in common.
        var prefixLen = 0
        for i in 0..<min(4, min(aArr.count, bArr.count)) {
            if aArr[i] == bArr[i] { prefixLen += 1 } else { break }
        }
        return jaro + Double(prefixLen) * prefixScale * (1 - jaro)
    }

    /// Token-sort ratio: split each string on whitespace, sort tokens
    /// lexically, rejoin, then run Jaro-Winkler. Handles out-of-order
    /// multi-word names ("Jane Smith" vs "Smith, Jane").
    static func tokenSortRatio(_ a: String, _ b: String) -> Double {
        let aSorted = a.split(whereSeparator: { $0.isWhitespace || $0 == "," })
            .map(String.init)
            .sorted()
            .joined(separator: " ")
        let bSorted = b.split(whereSeparator: { $0.isWhitespace || $0 == "," })
            .map(String.init)
            .sorted()
            .joined(separator: " ")
        return similarity(aSorted, bSorted)
    }

    /// Initialism match: if one string looks like initials ("J.B.S." or
    /// "JBS") and the other is a multi-token name starting with those
    /// letters ("John Brown Smith"), return 0.80.
    static func initialismMatch(_ a: String, _ b: String) -> Double {
        let compact = { (s: String) -> String in
            s.filter { $0.isLetter }.lowercased()
        }
        let candidate: String
        let multi: String
        // Accept strings whose non-letter-stripped form is ≤ 4 letters AND
        // whose original contains either '.' separators or is all-caps.
        if a.count <= 8 && a.contains(".") {
            candidate = compact(a)
            multi = b
        } else if b.count <= 8 && b.contains(".") {
            candidate = compact(b)
            multi = a
        } else if a.count <= 4 && a.uppercased() == a && a.allSatisfy(\.isLetter) {
            candidate = a.lowercased()
            multi = b
        } else if b.count <= 4 && b.uppercased() == b && b.allSatisfy(\.isLetter) {
            candidate = b.lowercased()
            multi = a
        } else {
            return 0
        }

        let tokens = multi.split(whereSeparator: { $0.isWhitespace })
        guard tokens.count >= candidate.count else { return 0 }
        let firstLetters = tokens.compactMap { $0.first?.lowercased() }.joined()
        if firstLetters.hasPrefix(candidate) {
            return 0.80
        }
        return 0
    }

    /// Convenience: the max of the three metrics.
    static func combinedSimilarity(_ a: String, _ b: String) -> Double {
        let jw = similarity(a, b)
        let ts = tokenSortRatio(a, b)
        let im = initialismMatch(a, b)
        return max(jw, max(ts, im))
    }
}
