import Foundation
import OSLog

// L6 / C12 / search-impl S5 item 2.9 — address-component gazetteer. Loads
// `address_components.json` produced by DataPipeline's
// src/resecta_data/gazetteers/address_components/ (C11). Schema:
// `cities: [String]`, `counties: [String]`, `street_types: [String]`.
//
// Cities are GNIS-derived entries cross-filtered through Census TIGER/Line
// 2024 PLACE boundaries (S5 item 2.9); junk entries with no formal municipal
// boundary are excluded at pipeline build time.
//
// `street_types` decodes non-optionally: the artifact has carried the key
// since C12 and the pipeline always emits it.
//
// Keys are NFKC-normalized and lowercased via `TextNormalizer.normalize(_:)`
// so callers can pass raw OCR text and hit case-insensitively.
//
// Absence of the gazetteer (resourceMissing) leaves all three lookup surfaces
// inert; callers check for nil via the optional shared instance in
// AddressSpatialAssembler.

public struct AddressComponentsGazetteer: Sendable {

    public enum LoaderError: Error {
        case resourceMissing
        case decodingFailed(underlying: Error)
        case unsupportedVersion(actual: Int, supported: ClosedRange<Int>)
    }

    private static let supportedVersions: ClosedRange<Int> = 1...1

    private let cities: Set<String>
    private let counties: Set<String>
    public let streetTypes: Set<String>

    // MARK: - Init

    /// Load from the module bundle.
    public init() throws {
        try self.init(bundle: .module)
    }

    /// Testing / composition init — inject a custom bundle.
    init(bundle: Bundle) throws {
        guard let url = bundle.url(
            forResource: "address_components",
            withExtension: "json",
            subdirectory: "Gazetteers"
        ) else {
            logger.info("address_components.json not bundled; address gazetteer inert")
            throw LoaderError.resourceMissing
        }

        do {
            let bytes = try Data(contentsOf: url)
            let wire = try JSONDecoder().decode(WireFormat.self, from: bytes)
            try LoaderVersionFence.assert(
                actual: wire.version,
                supported: Self.supportedVersions,
                assetName: "address_components",
                logger: logger,
                throwing: { LoaderError.unsupportedVersion(actual: $0, supported: $1) }
            )
            self.cities = Set(wire.cities.map(Self.normalize))
            self.counties = Set(wire.counties.map(Self.normalize))
            self.streetTypes = Set(wire.street_types.map(Self.normalize))
        } catch let error as LoaderError {
            throw error
        } catch {
            logger.warning(
                "address_components.json decode failed: \(String(describing: error), privacy: .public)"
            )
            throw LoaderError.decodingFailed(underlying: error)
        }
    }

    // MARK: - Lookup

    public func containsCity(_ name: String) -> Bool {
        cities.contains(Self.normalize(name))
    }

    public func containsCounty(_ name: String) -> Bool {
        counties.contains(Self.normalize(name))
    }

    /// Return whether *token* is a known street-type suffix.
    ///
    /// The street-types set is loaded from the pipeline artifact; it mirrors
    /// the full-word vocabulary enumerated in the Swift address regex so future
    /// pipeline-driven changes to the list flow here without Swift edits.
    public func containsStreetType(_ token: String) -> Bool {
        streetTypes.contains(Self.normalize(token))
    }

    // MARK: - Normalization

    private static func normalize(_ s: String) -> String {
        TextNormalizer.normalize(s)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Wire format

private struct WireFormat: Decodable {
    let version: Int
    let cities: [String]
    let counties: [String]
    // `street_types` has been present in address_components.json since C12;
    // decode non-optionally because the artifact always carries the key.
    let street_types: [String]
}

private let logger = Logger(
    subsystem: "app.resecta.engine",
    category: "AddressComponentsGazetteer"
)
