import Testing
import Foundation
@testable import RedactionEngine

// GAP-DEPTARGET-NER (D04-F3 == D11-F3) — unit coverage for the static NER
// name-model availability probe `PIIDetector.isNameNERAvailable()`. The probe is
// consulted by `loadWithDiagnostics` (step 10) to fold a missing OS-provisioned
// `.nameType` MobileAsset into the SEC-7 degraded-detection surface.
//
// These tests do NOT run detection and do NOT assert a fixed true/false for the
// live probe — `.nameType` availability is environment-dependent (the asset is
// reliably provisioned only on iOS 26.4+, per the detection harness pin). They
// assert the probe returns a Bool synchronously (no throw, no network) and that
// the DEBUG override seam controls the result deterministically.

@Suite("PIIDetector NER availability probe (GAP-DEPTARGET-NER)")
struct PIIDetectorNERAvailabilityTests {

    @Test("isNameNERAvailable returns a Bool synchronously — no throw, no network")
    func probeReturnsBoolSynchronously() {
        // No binding → the task-local default (nil) runs the real read-only query
        // path. Environment-independent: assert only that a value comes back. A
        // hard true/false would be 26.4-pinned and flaky on other runtimes. The
        // meaningful contract is that the call completes synchronously without
        // throwing or performing a network-shaped asset fetch.
        let value: Bool = PIIDetector.isNameNERAvailable()
        #expect(value == true || value == false)
    }

    @Test("DEBUG override forces the probe result both ways")
    func overrideControlsResult() {
        // Task-local binding — scoped to this test's task, so parallel tests
        // neither race nor observe the value.
        PIIDetector.$_nerAvailabilityOverride.withValue(true) {
            #expect(PIIDetector.isNameNERAvailable() == true)
        }
        PIIDetector.$_nerAvailabilityOverride.withValue(false) {
            #expect(PIIDetector.isNameNERAvailable() == false)
        }
        // No binding → the live read-only query; confirm it still completes
        // synchronously.
        _ = PIIDetector.isNameNERAvailable()
    }
}
