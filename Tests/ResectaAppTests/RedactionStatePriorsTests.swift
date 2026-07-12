import Testing
import Foundation
@testable import ResectaApp
@testable import RedactionEngine

// Phase 3 §A7 — priors + surface forms + ambiguity flag + clearAll.

@Suite("RedactionState priors + surface forms (Phase 3)")
@MainActor
struct RedactionStatePriorsTests {

    @Test("Empty state starts with zero priors and no surface forms")
    func freshState() {
        let state = RedactionState()
        #expect(state.priors.mean(.ssn) == 0.5)
        #expect(state.surfaceForms.isEmpty)
        #expect(state.pageDiagnostics.isEmpty)
        #expect(state.ambiguousSurnameDetectionIDs.isEmpty)
    }

    @Test("applyTriagedResults on accept updates SSN prior upward")
    func applyAcceptUpdatesPrior() {
        let state = RedactionState()
        let detection = makeDetection(kind: .pii(.ssn), text: "123-45-6789")
        state.pendingTriage = [0: [detection]]
        state.triageSelections = [detection.id: true]

        state.applyTriagedResults(undoManager: nil)
        #expect(state.priors.mean(.ssn) > 0.5)
        #expect(state.surfaceForms.lookup("123-45-6789") == .accepted)
        #expect(state.pendingTriage == nil)
    }

    @Test("applyTriagedResults on reject updates SSN prior downward")
    func applyRejectUpdatesPrior() {
        let state = RedactionState()
        let detection = makeDetection(kind: .pii(.ssn), text: "987-65-4321")
        state.pendingTriage = [0: [detection]]
        state.triageSelections = [detection.id: false]

        state.applyTriagedResults(undoManager: nil)
        #expect(state.priors.mean(.ssn) < 0.5)
        #expect(state.surfaceForms.lookup("987-65-4321") == .rejected)
    }

    @Test("Undo reverses the prior + surface form update")
    func undoReversesPriorUpdate() {
        let undoManager = UndoManager()
        let state = RedactionState()
        let detection = makeDetection(kind: .pii(.ssn), text: "111-22-3333")
        state.pendingTriage = [0: [detection]]
        state.triageSelections = [detection.id: true]

        state.applyTriagedResults(undoManager: undoManager)
        #expect(state.priors.mean(.ssn) > 0.5)
        #expect(state.surfaceForms.lookup("111-22-3333") == .accepted)

        undoManager.undo()
        #expect(state.priors.mean(.ssn) == 0.5)
        #expect(state.surfaceForms.lookup("111-22-3333") == nil)
    }

    @Test("clearAll persists+rehydrates priors; wipes surface forms, diagnostics, ambiguity flags")
    func clearAllResetsPhase3State() {
        // S7 / design 03 §3.6 behavior change: priors now SURVIVE clearAll
        // (saved before the wipe, rehydrated after) so triage history
        // accumulates across documents. Everything else still wipes.
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let state = RedactionState()
        state.priorsDefaults = defaults
        let detection = makeDetection(kind: .pii(.name), text: "John Smith")
        state.pendingTriage = [0: [detection]]
        state.triageSelections = [detection.id: true]
        state.pageDiagnostics[0] = ClassificationDiagnostic(
            primary: .medical,
            runnerUp: .court,
            softmaxSnapshot: [.medical: 0.6, .court: 0.3],
            topKeywords: []
        )
        state.ambiguousSurnameDetectionIDs = [detection.id]

        state.applyTriagedResults(undoManager: nil)
        state.clearAll()

        #expect(state.priors.mean(.name) > 0.5,
                "priors persist across clearAll by design (S7 §3.6)")
        #expect(state.priors.byCategory[.name]?.streakLen == 0,
                "streaks are session-scoped and reset on rehydrate")
        #expect(defaults.dictionary(forKey: RedactionState.priorsStorageKey) != nil,
                "clearAll writes the persisted payload")
        #expect(state.surfaceForms.isEmpty)
        #expect(state.pageDiagnostics.isEmpty)
        #expect(state.ambiguousSurnameDetectionIDs.isEmpty)
        #expect(state.regionMetadata.isEmpty)
        #expect(state.regions.isEmpty)
    }

    // MARK: - S7 / design 03 §3.6 — priors persistence

    @Test("savePriors/loadPriors round-trip preserves alpha+beta, resets streaks")
    func priorsPersistenceRoundTrip() {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        var priors = PerCategoryPriors()
        priors = priors.updated(category: .ssn, decision: .accepted)
        priors = priors.updated(category: .ssn, decision: .accepted)
        priors = priors.updated(category: .account, decision: .rejected)

        RedactionState.savePriors(priors, defaults: defaults)
        let restored = RedactionState.loadPriors(defaults: defaults)

        #expect(restored.byCategory[.ssn]?.alpha == priors.byCategory[.ssn]?.alpha)
        #expect(restored.byCategory[.ssn]?.beta == priors.byCategory[.ssn]?.beta)
        #expect(restored.byCategory[.account]?.beta == priors.byCategory[.account]?.beta)
        #expect(restored.byCategory[.ssn]?.streakLen == 0)
        #expect(restored.byCategory[.ssn]?.streakDir == 0)
        #expect(restored.mean(.ssn) == priors.mean(.ssn))
    }

    @Test("loadPriors with no stored payload yields the uniform default")
    func priorsLoadEmptyDefaults() {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let restored = RedactionState.loadPriors(defaults: defaults)
        #expect(restored == PerCategoryPriors())
        #expect(restored.mean(.ssn) == 0.5)
    }

    @Test("loadPriors clamps a poisoned payload to the G10 invariants")
    func priorsLoadClampsPoisonedPayload() {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(
            [
                "SSN": ["alpha": 1_000_000.0, "beta": 1.0],        // ESS bomb
                "Name": ["alpha": -5.0, "beta": 0.0],               // below floors
                "EIN": ["alpha": Double.infinity, "beta": 2.0],     // non-finite
                "NotACategory": ["alpha": 2.0, "beta": 2.0],        // unknown key
                "Phone": ["alpha": 3.0]                              // missing beta
            ],
            forKey: RedactionState.priorsStorageKey
        )
        let restored = RedactionState.loadPriors(defaults: defaults)

        if let ssn = restored.byCategory[.ssn] {
            // The α/β ≥ 1 floors apply AFTER the ESS scaling — identical
            // to PerCategoryPriors.updated()/merged() — so the total can
            // land up to 1 above the 50 cap when one arm was scaled to
            // near zero. ≤ 51 is the engine's real invariant.
            #expect(ssn.alpha + ssn.beta <= 51.0, "ESS cap (+floor slack) applies on load")
            #expect(ssn.beta >= 1.0)
        } else {
            Issue.record("SSN entry should survive with clamped values")
        }
        if let name = restored.byCategory[.name] {
            #expect(name.alpha >= 1.0 && name.beta >= 1.0, "alpha/beta floors apply")
        } else {
            Issue.record("Name entry should survive with floored values")
        }
        #expect(restored.byCategory[.ein] == nil, "non-finite entries are dropped")
        #expect(restored.byCategory[.phone] == nil, "incomplete entries are dropped")
    }

    @Test("clearPersistedPriors removes the stored payload")
    func clearPersistedPriorsRemovesKey() {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        RedactionState.savePriors(
            PerCategoryPriors().updated(category: .ssn, decision: .accepted),
            defaults: defaults
        )
        #expect(defaults.dictionary(forKey: RedactionState.priorsStorageKey) != nil)
        RedactionState.clearPersistedPriors(defaults: defaults)
        #expect(defaults.dictionary(forKey: RedactionState.priorsStorageKey) == nil)
        #expect(RedactionState.loadPriors(defaults: defaults) == PerCategoryPriors())
    }

    @Test("Simulated relaunch: triage history shapes the next session's scoring")
    func priorsSurviveSimulatedRelaunch() {
        // Session 1: accept two SSN detections, close the document
        // (clearAll = the tearDown path's save point).
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let session1 = RedactionState()
        session1.priorsDefaults = defaults
        session1.priors = session1.priors.updated(category: .ssn, decision: .accepted)
        session1.priors = session1.priors.updated(category: .ssn, decision: .accepted)
        let session1Mean = session1.priors.mean(.ssn)
        session1.clearAll()

        // "Relaunch": a fresh instance hydrating the same store (the
        // RedactWorkspace-init path).
        let session2 = RedactionState()
        session2.priorsDefaults = defaults
        session2.priors = RedactionState.loadPriors(defaults: defaults)
        #expect(session2.priors.mean(.ssn) == session1Mean,
                "next session starts from the saved history")
        #expect(session2.priors.mean(.ssn) > 0.5)
    }

    @Test("Accepted detection whose ID is flagged ambiguous carries isAmbiguousSurname forward")
    func ambiguityFlagFlowsToMetadata() {
        let state = RedactionState()
        let detection = makeDetection(kind: .pii(.name), text: "Smith")
        state.pendingTriage = [0: [detection]]
        state.triageSelections = [detection.id: true]
        state.ambiguousSurnameDetectionIDs = [detection.id]

        state.applyTriagedResults(undoManager: nil)

        let region = state.regions[0]?.first
        let meta = state.regionMetadata[region?.id ?? UUID()]
        #expect(meta?.isAmbiguousSurname == true)
    }

    // MARK: - Helper

    private func makeDetection(kind: DetectionResult.Kind, text: String) -> DetectionResult {
        DetectionResult(
            id: UUID(),
            normalizedRect: CGRect(x: 0.1, y: 0.5, width: 0.2, height: 0.03),
            kind: kind,
            confidence: 0.9,
            matchedText: text,
            recognitionLevel: .fast
        )
    }
}
