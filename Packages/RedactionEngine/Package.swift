// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "RedactionEngine",
    // GAP-DEPTARGET-NER (D04-F3 == D11-F3) — deployment floor stays iOS 26.0 by
    // design. The runtime `.nameType` NER name model is reliably provisioned only
    // on iOS 26.4+ (per the detection harness pin), but the 26.0 floor is
    // INTENTIONAL: non-NER detectors plus the SEC-7 auto-detect-degraded banner
    // (which now also fires when the NER MobileAsset is absent) cover the 26.0–26.3
    // gap. Do NOT raise to 26.4 here — that would drop 26.0–26.3 devices and is a
    // Jesse decision (J-DEPTARGET / J-NER-ONDEVICE option B). On-device asset-absent
    // confirmation is owned by GAP-REL-ONDEVICE / J-NER-ONDEVICE.
    // macOS is a TOOLING destination only (lets `swift test` run on Mac hosts);
    // the shipping product is iOS. Platform seams are conditional-compilation
    // only — the iOS compilation path is unchanged.
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [
        .library(name: "RedactionEngine", targets: ["RedactionEngine"]),
    ],
    targets: [
        .target(
            name: "RedactionEngine",
            resources: [
                .copy("Resources/Gazetteers"),
                .copy("Resources/Classifier"),
                .copy("Resources/Audit"),
            ],
            swiftSettings: [
                // CPU-bound library — do NOT use MainActor default isolation
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
            ]
        ),
        .testTarget(
            name: "RedactionEngineTests",
            dependencies: ["RedactionEngine"],
            resources: [
                .copy("Fixtures/TestResources"),
                // S01 (sample-packet series) — committed Stage-1 detection
                // snapshot of the shipped statement (sample-statement-stage1.json).
                // Bundled so S05's manifest-driven P/R harness can load it.
                .copy("Fixtures/snapshots"),
                // DataPipeline-produced fixtures. Phase 2 adds `corpus`
                // (awaits Jesse's `make install-assets` for real g8 corpus;
                // empty placeholder README meanwhile).
                .copy("Fixtures/corpus"),
                .copy("Fixtures/fuzz"),
                .copy("Fixtures/vectors"),
                .copy("Fixtures/adversarial"),
                // Package J — TEST-neg-ctx-test-target-wiring. The
                // `NegativeContextInstitutionAnchorTests` suite needs
                // `negative_context.json` (and the rest of the gazetteer
                // bundle) accessible from the test target's `Bundle.module`
                // — without this entry the canonical resources live only in
                // the source target's `.module`. Path is relative to the
                // test target's source dir (`Tests/RedactionEngineTests`).
                .copy("../../Sources/RedactionEngine/Resources/Gazetteers"),
            ],
            swiftSettings: [
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
            ]
        ),
    ]
)
