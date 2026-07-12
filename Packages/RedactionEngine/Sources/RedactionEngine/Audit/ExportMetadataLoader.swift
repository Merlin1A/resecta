import Foundation
import os

// W-I2 — gazetteer-manifest.json `version` accessor for audit-export records.
//
// `Resources/Gazetteers/gazetteer-manifest.json` ships a `version` field
// (e.g. `"1.0.0"`) tracked by the data-side bloom build. W-I2 surfaces
// that string on every `MatchAuditRecord` so an audit export can pin
// which gazetteer-manifest version produced the match.
//
// Cache lifetime: lazy `static let shared` initializes once on first
// access; effectively per-app-session for V1 (Improvement 9). The manifest
// only changes via Jesse's `make install-assets` boundary-crossing, which
// happens between app invocations. Missing-file → `nil`; decode-error →
// log + `nil` (do NOT hard-fail the audit-export surface).

public enum ExportMetadataLoader {

    public struct Manifest: Sendable {
        public let manifestVersion: String?
    }

    public static let shared: Manifest = Manifest(manifestVersion: load())

    private static func load() -> String? {
        guard let url = Bundle.module.url(
            forResource: "gazetteer-manifest",
            withExtension: "json",
            subdirectory: "Gazetteers"
        ) else {
            return nil
        }
        do {
            let bytes = try Data(contentsOf: url)
            let manifest = try JSONDecoder().decode(GazetteerManifest.self, from: bytes)
            return manifest.version
        } catch {
            Logger(subsystem: "app.resecta.engine", category: "ExportMetadataLoader")
                .warning("gazetteer-manifest.json decode failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}
