// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "RedactionEngine",
    // The deployment floor stays iOS 26.0 by design. The runtime `.nameType` NER
    // name model is reliably provisioned only on iOS 26.4+ (per the detection
    // harness pin), but the 26.0 floor is intentional: non-NER detectors plus the
    // auto-detect-degraded banner (which also fires when the NER MobileAsset is
    // absent) cover the 26.0–26.3 gap. Do not raise it to 26.4 here — that would
    // drop 26.0–26.3 devices.
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
                // Committed Stage-1 detection snapshot of the shipped packet
                // (`snapshots/packet-stage1.json`, produced by
                // `PacketSnapshotTests`) — bundled so `PacketPRHarnessTests`
                // can load it.
                .copy("Fixtures/snapshots"),
                // DataPipeline-produced fixtures. `corpus` is populated by the
                // datapipeline's `make install-assets` (an empty placeholder
                // README ships meanwhile).
                .copy("Fixtures/corpus"),
                .copy("Fixtures/fuzz"),
                .copy("Fixtures/vectors"),
                .copy("Fixtures/adversarial"),
                // Test-target resource wiring. The
                // `NegativeContextInstitutionAnchorTests` suite needs
                // `negative_context.json` (and the rest of the gazetteer
                // bundle) accessible from the test target's `Bundle.module`
                // — without this entry the canonical resources live only in
                // the source target's `.module`. Path is relative to the
                // test target's source dir (`Tests/RedactionEngineTests`).
                .copy("../../Sources/RedactionEngine/Resources/Gazetteers"),
                // The asset-diagnostics tests need the canonical Classifier/
                // assets (context-scorer / doctype-temperature /
                // preset-thresholds / doctype-keywords) reachable from the test
                // target's `Bundle.module` to build scratch bundles with
                // altered copies — same wiring rationale as the Gazetteers
                // entry above.
                .copy("../../Sources/RedactionEngine/Resources/Classifier"),
            ],
            swiftSettings: [
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
            ]
        ),
    ]
)
