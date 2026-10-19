import Foundation
import OSLog

// W-O — shared loader-version fence. Each loader's `init(bundle:)`
// calls `LoaderVersionFence.assert(...)` immediately after decoding
// `WireFormat.version`. Centralizes the log message format, the
// error shape, and the supportedVersions semantics so future loader
// version-policy evolution is a single-site edit.

enum LoaderVersionFence {
    static func assert(
        actual: Int,
        supported: ClosedRange<Int>,
        assetName: String,
        logger: Logger,
        throwing makeError: (Int, ClosedRange<Int>) -> Error
    ) throws {
        guard supported.contains(actual) else {
            logger.warning(
                "\(assetName, privacy: .public).json version \(actual) outside supported range \(supported.lowerBound)...\(supported.upperBound)"
            )
            throw makeError(actual, supported)
        }
    }
}

/// A decoded gazetteer table that carries the loader-version field.
protocol VersionedWireTable: Decodable {
    var version: Int { get }
}

/// One loading path for the bundled pattern tables (the driver's-licence
/// and passport pattern gazetteers): the resource lookup, the decode and
/// the version fence in that order. Each failure is handed to the caller,
/// which logs its own line and names the error to throw.
enum PatternTableLoader {
    static func load<Wire: VersionedWireTable>(
        _ wireType: Wire.Type,
        resource: String,
        bundle: Bundle,
        supportedVersions: ClosedRange<Int>,
        logger: Logger,
        missing: () -> Error,
        decodeFailure: (Error) -> Error,
        unsupportedVersion: @escaping (Int, ClosedRange<Int>) -> Error
    ) throws -> Wire {
        guard let url = bundle.url(
            forResource: resource,
            withExtension: "json",
            subdirectory: "Gazetteers"
        ) else {
            throw missing()
        }

        let wire: Wire
        do {
            let bytes = try Data(contentsOf: url)
            wire = try JSONDecoder().decode(Wire.self, from: bytes)
        } catch {
            throw decodeFailure(error)
        }

        try LoaderVersionFence.assert(
            actual: wire.version,
            supported: supportedVersions,
            assetName: resource,
            logger: logger,
            throwing: unsupportedVersion
        )
        return wire
    }
}
