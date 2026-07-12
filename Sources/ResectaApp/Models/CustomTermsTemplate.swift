import Foundation
import RedactionEngine

// License-plate 50-state starter template loader.
// Decodes the JSON template at
// `Resources/CustomTermsTemplates/license_plate_us_50_state_starter.json`
// into a list of UserTerms ready to import into the active profile's
// alwaysFlagTerms list. F-4 disposition: copying a row makes it
// user-owned; no template-lineage tracking. The shipped per-state
// regex is a permissive shape default — users tighten per row.

public struct CustomTermsTemplate: Sendable, Equatable, Codable {
    public let templateID: String
    public let templateName: String
    public let templateVersion: Int
    public let description: String
    public let entries: [Entry]

    public struct Entry: Sendable, Equatable, Codable {
        public let label: String
        public let polarity: String
        public let regex: String
        public let scope: String
    }

    enum CodingKeys: String, CodingKey {
        case templateID = "template_id"
        case templateName = "template_name"
        case templateVersion = "template_version"
        case description
        case entries
    }
}

public enum CustomTermsTemplateLoader {

    public enum LoaderError: Error {
        case resourceMissing
        case decodingFailed(underlying: Error)
    }

    public static func licensePlate50StateStarter(
        bundle: Bundle = .main
    ) throws -> CustomTermsTemplate {
        guard let url = bundle.url(
            forResource: "license_plate_us_50_state_starter",
            withExtension: "json"
        ) else { throw LoaderError.resourceMissing }
        do {
            let bytes = try Data(contentsOf: url)
            return try JSONDecoder().decode(CustomTermsTemplate.self, from: bytes)
        } catch {
            throw LoaderError.decodingFailed(underlying: error)
        }
    }

    public static func userTerms(
        from template: CustomTermsTemplate
    ) -> [UserTerm] {
        template.entries.map { UserTerm(pattern: $0.regex, isRegex: true) }
    }

    public static func deduplicating(
        _ candidates: [UserTerm],
        against existing: [UserTerm]
    ) -> (toImport: [UserTerm], skipped: [UserTerm]) {
        let existingPatterns = Set(existing.map { $0.pattern })
        var toImport: [UserTerm] = []
        var skipped: [UserTerm] = []
        for candidate in candidates {
            if existingPatterns.contains(candidate.pattern) {
                skipped.append(candidate)
            } else {
                toImport.append(candidate)
            }
        }
        return (toImport, skipped)
    }
}
