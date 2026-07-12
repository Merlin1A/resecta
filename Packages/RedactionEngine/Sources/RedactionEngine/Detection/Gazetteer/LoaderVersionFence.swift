import Foundation
import OSLog

// W-O — shared loader-version fence. Each loader's `init(bundle:)`
// calls `LoaderVersionFence.assert(...)` immediately after decoding
// `WireFormat.version`. Centralizes the log message format, the
// error shape, and the supportedVersions semantics so future loader
// version-policy evolution is a single-site edit.

public enum LoaderVersionFence {
    public static func assert(
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
