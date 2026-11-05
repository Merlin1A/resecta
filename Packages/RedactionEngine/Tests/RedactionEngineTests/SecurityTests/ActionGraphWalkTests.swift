import Testing
@testable import RedactionEngine

// The action-chain walk over value graphs. The reference is the bounded
// reading: every path read in full, depth first in `/Next` order, nil at the
// depth bound. The walk must give the reference's answer on every graph,
// including loops (nil) and actions named more than once.

@Suite("Action-chain walk: the same answer as reading every path to the bound", .tags(.security))
struct ActionGraphWalkTests {

    typealias Graph = ActiveContentScan.ActionGraph
    typealias Node = Graph.Node

    /// The bounded reading from `node` at `depth`.
    static func boundedReading(_ graph: Graph, _ node: Int, depth: Int, maxDepth: Int) -> Bool? {
        guard depth < maxDepth else { return nil }
        let current = graph.nodes[node]
        if current.isActive { return true }
        for next in current.next {
            switch boundedReading(graph, next, depth: depth + 1, maxDepth: maxDepth) {
            case true: return true
            case nil: return nil
            case false: continue
            }
        }
        return false
    }

    /// Each node's possible shapes on `count` nodes: active, or not active
    /// with a `/Next` of no entry, one entry, or two entries. With `ordered`
    /// the two entries come in either order and may repeat; otherwise in
    /// index order (repeats allowed).
    static func shapes(count: Int, ordered: Bool) -> [Node] {
        var shapes: [Node] = [Node(isActive: true, next: []), Node(isActive: false, next: [])]
        for a in 0..<count { shapes.append(Node(isActive: false, next: [a])) }
        for a in 0..<count {
            for b in (ordered ? 0 : a)..<count { shapes.append(Node(isActive: false, next: [a, b])) }
        }
        return shapes
    }

    /// Calls `body` with every graph on `count` nodes built from `shapes`.
    static func everyGraph(count: Int, shapes: [Node], _ body: (Graph) -> Void) {
        var digits = [Int](repeating: 0, count: count)
        while true {
            body(Graph(nodes: digits.map { shapes[$0] }))
            var place = 0
            while place < count {
                digits[place] += 1
                if digits[place] < shapes.count { break }
                digits[place] = 0
                place += 1
            }
            if place == count { return }
        }
    }

    @Test("Every graph on one to four nodes, /Next lists of up to two entries in any order, depth bounds 1 to 6",
          arguments: 1...4)
    func everySmallGraphMatchesTheBoundedReading(count: Int) {
        let shapes = Self.shapes(count: count, ordered: true)
        var graphs = 0, mismatches: [String] = []
        Self.everyGraph(count: count, shapes: shapes) { graph in
            graphs += 1
            for maxDepth in 1...6 {
                let walked = ActiveContentScan.actionGraphIsActive(graph, maxDepth: maxDepth)
                let read = Self.boundedReading(graph, 0, depth: 0, maxDepth: maxDepth)
                if walked != read, mismatches.count < 5 {
                    mismatches.append("\(graph.nodes) bound \(maxDepth): walked \(String(describing: walked)), read \(String(describing: read))")
                }
            }
        }
        #expect(graphs == (0..<count).reduce(1) { product, _ in product * shapes.count })
        #expect(mismatches.isEmpty, "\(mismatches)")
    }

    @Test("Every graph on five nodes, /Next lists of up to two entries in index order, depth bounds 3 to 5")
    func everyFiveNodeGraphMatchesTheBoundedReading() {
        let shapes = Self.shapes(count: 5, ordered: false)
        var graphs = 0, mismatches: [String] = []
        Self.everyGraph(count: 5, shapes: shapes) { graph in
            graphs += 1
            for maxDepth in 3...5 {
                let walked = ActiveContentScan.actionGraphIsActive(graph, maxDepth: maxDepth)
                let read = Self.boundedReading(graph, 0, depth: 0, maxDepth: maxDepth)
                if walked != read, mismatches.count < 5 {
                    mismatches.append("\(graph.nodes) bound \(maxDepth): walked \(String(describing: walked)), read \(String(describing: read))")
                }
            }
        }
        #expect(graphs == 22 * 22 * 22 * 22 * 22)
        #expect(mismatches.isEmpty, "\(mismatches)")
    }

    @Test("A loop with no script is refused, whether it returns to the start or to a later action")
    func loopsAreRefused() {
        let selfLoop = Graph(nodes: [Node(isActive: false, next: [0])])
        let backToStart = Graph(nodes: [Node(isActive: false, next: [1]), Node(isActive: false, next: [0])])
        let laterLoop = Graph(nodes: [
            Node(isActive: false, next: [1]), Node(isActive: false, next: [2]), Node(isActive: false, next: [1]),
        ])
        for graph in [selfLoop, backToStart, laterLoop] {
            #expect(ActiveContentScan.actionGraphIsActive(graph) == nil)
        }
    }

    @Test("An action named twice is read clean once; a script it reaches is still found")
    func sharedActionsAreReadOnce() {
        // 0 → [1, 1], 1 → [2, 2], 2 → no /Next.
        let clean = Graph(nodes: [
            Node(isActive: false, next: [1, 1]), Node(isActive: false, next: [2, 2]), Node(isActive: false, next: []),
        ])
        #expect(ActiveContentScan.actionGraphIsActive(clean) == false)
        var scripted = clean
        scripted.nodes[2].isActive = true
        #expect(ActiveContentScan.actionGraphIsActive(scripted) == true)
    }

    @Test("Order: a chain that runs past the bound before a script refuses; the script first reports")
    func firstAnswerInNextOrderWins() {
        // Node 1 starts a chain past a bound of 3; node 2 is a script.
        let deep: [Node] = [
            Node(isActive: false, next: [3]), Node(isActive: false, next: [4]), Node(isActive: false, next: []),
        ]
        let deepFirst = Graph(nodes: [Node(isActive: false, next: [1, 2]), Node(isActive: false, next: [3]),
                                      Node(isActive: true, next: [])] + deep)
        let scriptFirst = Graph(nodes: [Node(isActive: false, next: [2, 1]), Node(isActive: false, next: [3]),
                                        Node(isActive: true, next: [])] + deep)
        #expect(ActiveContentScan.actionGraphIsActive(deepFirst, maxDepth: 3) == nil)
        #expect(ActiveContentScan.actionGraphIsActive(scriptFirst, maxDepth: 3) == true)
    }

    @Test("An action read clean near the start is read again when it is met deeper, and refused past the bound")
    func cleanAnswerHoldsOnlyAtTheDepthItWasRead() {
        // 0 → [2, 1]; 1 → 2; 2 → 3; 3 → no /Next. With a bound of 3, node 2
        // is clean when met first (depth 1, via 0), but met again at depth 2
        // (via 1) its chain reaches depth 3, past the bound.
        let graph = Graph(nodes: [
            Node(isActive: false, next: [2, 1]), Node(isActive: false, next: [2]),
            Node(isActive: false, next: [3]), Node(isActive: false, next: []),
        ])
        #expect(Self.boundedReading(graph, 0, depth: 0, maxDepth: 3) == nil)
        #expect(ActiveContentScan.actionGraphIsActive(graph, maxDepth: 3) == nil)
    }
}
