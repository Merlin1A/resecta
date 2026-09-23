import Foundation

// One detector per PII family behind one registry. `PIIDetector` runs the
// rows in order for a page and looks a family up by category for the
// reverse-rationale explainer; the families own their patterns, keyword
// profiles, doctype gates and rationale assembly.

/// What one family detector reads for one page: the text as both a `String`
/// (the name detector's tagger indexes it) and an `NSString` (the regex
/// families scan it), the range to scan, and the page context the scored
/// families hand to the context scorer. Built once per `detect` call.
struct DetectionContext {
    let text: String
    let nsText: NSString
    let range: NSRange
    /// The page's doctype when the caller knows it; nil runs every family.
    let doctype: DoctypeClass?
    /// Negative-context gazetteer for per-(category, doctype) suppression;
    /// nil = no gazetteer layer.
    let gazetteer: NegativeContextGazetteer?
    /// First-page text prefix for the institution-anchor suppression path;
    /// nil = that path inactive.
    let documentHeader: String?

    /// A page: the whole buffer is the range.
    init(text: String, doctype: DoctypeClass?, gazetteer: NegativeContextGazetteer?, documentHeader: String?) {
        self.text = text
        let nsText = text as NSString
        self.nsText = nsText
        self.range = NSRange(location: 0, length: nsText.length)
        self.doctype = doctype
        self.gazetteer = gazetteer
        self.documentHeader = documentHeader
    }

    /// A snippet-as-page buffer from the reverse-rationale explainer: its own
    /// range, no doctype, gazetteer or header (every family runs as the
    /// forward path does with none of them).
    init(buffer: NSString, range: NSRange) {
        self.text = buffer as String
        self.nsText = buffer
        self.range = range
        self.doctype = nil
        self.gazetteer = nil
        self.documentHeader = nil
    }
}

/// One PII family. `category` keys the registry; `runs(doctype:)` is the
/// family's doctype gate (nil doctype runs everything; families with no
/// gate inherit `true`); `telemetryName(doctype:)` is the label the
/// per-detector elapsed-time telemetry logs; `detect(in:)` is the pass.
protocol FamilyDetector: Sendable {
    var category: PIICategory { get }
    var telemetryLabel: String { get }
    func runs(doctype: DoctypeClass?) -> Bool
    func telemetryName(doctype: DoctypeClass?) -> String
    func detect(in context: DetectionContext) -> [PIIDetector.PIIMatch]
}

extension FamilyDetector {
    func runs(doctype: DoctypeClass?) -> Bool { true }
    func telemetryName(doctype: DoctypeClass?) -> String { telemetryLabel }
}

/// The family detectors, constructed once with the shared corpus loaders and
/// held by `PIIDetector`. `rows` is the evaluation order of a page scan (the
/// order the matches reach the overlap resolver in); the table keys the same
/// instances by category for the explainer.
struct DetectorRegistry: Sendable {
    let ssn: SSNDetector
    let creditCard: CreditCardDetector
    let email: EmailDetector
    let phone: PhoneDetector
    let ein: EINDetector
    let address: AddressDetector
    let dateOfBirth: DOBDetector
    let itin: ITINDetector
    let driversLicense: DriversLicenseDetector
    let passport: PassportDetector
    let medicalRecord: MRNDetector
    let licensePlate: LicensePlateDetector

    /// Evaluation order: the structured families first, the name passes
    /// last. Adding a family = a row here, keyed by its `PIICategory`.
    let rows: [any FamilyDetector]
    private let table: [PIICategory: any FamilyDetector]

    init(
        nameGazetteer: NameGazetteer?,
        dlPatternGazetteer: DLPatternGazetteer?,
        passportPatternGazetteer: PassportPatternGazetteer?,
        contextLoader: ContextKeywordsLoader?
    ) {
        // One stateless scorer shared by the three scored families.
        let contextScorer = ContextWindowScorer()
        ssn = SSNDetector(contextScorer: contextScorer, contextLoader: contextLoader)
        creditCard = CreditCardDetector()
        email = EmailDetector()
        phone = PhoneDetector()
        ein = EINDetector()
        address = AddressDetector()
        dateOfBirth = DOBDetector()
        itin = ITINDetector()
        driversLicense = DriversLicenseDetector(dlPatternGazetteer: dlPatternGazetteer)
        passport = PassportDetector(passportPatternGazetteer: passportPatternGazetteer)
        medicalRecord = MRNDetector(contextScorer: contextScorer, contextLoader: contextLoader)
        licensePlate = LicensePlateDetector(contextScorer: contextScorer, contextLoader: contextLoader)
        rows = [ssn, creditCard, email, phone, ein, address, dateOfBirth, itin, driversLicense, passport, medicalRecord, licensePlate]
        table = Dictionary(uniqueKeysWithValues: rows.map { ($0.category, $0) })
    }

    /// The family for `category`, or nil for a category no row serves.
    subscript(category: PIICategory) -> (any FamilyDetector)? { table[category] }
}
