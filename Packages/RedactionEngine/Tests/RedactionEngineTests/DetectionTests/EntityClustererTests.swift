import Testing
import Foundation
@testable import RedactionEngine

// Plan Phase 3 / §5 / A5 — entity clustering correctness + bare-surname flag.

@Suite("EntityClusterer (A5)")
struct EntityClustererTests {

    private func input(_ id: UUID = UUID(), name: String) -> EntityClusterer.ClusterInput {
        EntityClusterer.clusterInput(for: id, rawName: name)!
    }

    @Test("John Smith and J. Smith cluster into same group")
    func clusterByInitial() {
        let ids = (0..<2).map { _ in UUID() }
        let inputs = [
            EntityClusterer.clusterInput(for: ids[0], rawName: "John Smith")!,
            EntityClusterer.clusterInput(for: ids[1], rawName: "J. Smith")!,
        ]
        let clusterer = EntityClusterer()
        let report = clusterer.cluster(names: inputs)
        #expect(report.clusters.count == 1)
        #expect(Set(report.clusters[0]) == Set(ids))
    }

    @Test("20 bare 'Smith' entries flagged as ambiguous")
    func bareSurnameFlagged() {
        var inputs: [EntityClusterer.ClusterInput] = []
        var ids: [UUID] = []
        for _ in 0..<20 {
            let id = UUID()
            ids.append(id)
            inputs.append(EntityClusterer.clusterInput(for: id, rawName: "Smith")!)
        }
        let report = EntityClusterer().cluster(names: inputs)
        #expect(report.bareSurnameFlags.count == 20)
        for id in ids { #expect(report.bareSurnameFlags.contains(id)) }
    }

    @Test("14 bare 'Smith' entries NOT flagged")
    func justUnderThreshold() {
        var inputs: [EntityClusterer.ClusterInput] = []
        for _ in 0..<14 {
            inputs.append(EntityClusterer.clusterInput(for: UUID(), rawName: "Smith")!)
        }
        let report = EntityClusterer().cluster(names: inputs)
        #expect(report.bareSurnameFlags.isEmpty)
    }

    @Test("Different surnames do not cluster")
    func differentSurnames() {
        let inputs = [
            EntityClusterer.clusterInput(for: UUID(), rawName: "John Smith")!,
            EntityClusterer.clusterInput(for: UUID(), rawName: "Mary Johnson")!,
        ]
        let clusterer = EntityClusterer()
        let report = clusterer.cluster(names: inputs)
        #expect(report.clusters.count == 2)
    }

    @Test("JaroWinkler near-match unions")
    func nearMatchUnion() {
        // "Jonathan" vs "Jonathon" — near-identical given name, same surname.
        let ids = (0..<2).map { _ in UUID() }
        let inputs = [
            EntityClusterer.clusterInput(for: ids[0], rawName: "Jonathan Smith")!,
            EntityClusterer.clusterInput(for: ids[1], rawName: "Jonathon Smith")!,
        ]
        let report = EntityClusterer().cluster(names: inputs)
        #expect(report.clusters.count == 1)
    }
}
