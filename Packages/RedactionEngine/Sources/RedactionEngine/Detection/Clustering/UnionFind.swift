import Foundation

// Plan §5 — union-find (DSU) over integer indices. Used by EntityClusterer
// to merge name detections into equivalence classes.

struct UnionFind {
    private var parent: [Int]
    private var rank: [Int]

    init(count: Int) {
        self.parent = Array(0..<count)
        self.rank = Array(repeating: 0, count: count)
    }

    mutating func find(_ x: Int) -> Int {
        if parent[x] != x {
            parent[x] = find(parent[x])
        }
        return parent[x]
    }

    @discardableResult
    mutating func union(_ a: Int, _ b: Int) -> Bool {
        let ra = find(a)
        let rb = find(b)
        guard ra != rb else { return false }
        if rank[ra] < rank[rb] {
            parent[ra] = rb
        } else if rank[ra] > rank[rb] {
            parent[rb] = ra
        } else {
            parent[rb] = ra
            rank[ra] += 1
        }
        return true
    }

    mutating func groups() -> [[Int]] {
        var buckets: [Int: [Int]] = [:]
        for i in 0..<parent.count {
            let root = find(i)
            buckets[root, default: []].append(i)
        }
        return Array(buckets.values)
    }
}
