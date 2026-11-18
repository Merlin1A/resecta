// The rule ids a detection can carry in its rationale, as one public set the
// app's display names are checked against. The test suite reads the
// detection sources and holds this set equal to the ids written there, so a
// new emission that is not added here fails the build's tests.

extension PIIDetector {

    /// Every rule id a match's rationale can carry: each detector's own ids,
    /// the per-kind defaults of the regex families, the user's always-flag
    /// term (`user.alwaysFlag`) and the fallback kind (`pii.other`).
    public static let emittedRuleIDs: Set<String> = [
        "ssn.state-machine", "ssn.regex",
        "cc.luhn",
        "email.regex", "phone.regex", "address.regex",
        "ein.regex", "itin.regex", "itin.yy-bucket",
        "dob.regex", "passport.regex", "dl.regex",
        "licensePlate.labeled",
        "mrn.labeled", "mrn.patientID", "mrn.institution", "mrn.regex",
        "npi.80840", "dea.letter-check",
        "account.regex", "routingNumber.aba-checksum",
        "name.nltagger", "name.label-anchor",
        "user.alwaysFlag", "pii.other",
    ]

    /// Rule ids that have a display name in the app but that no detector
    /// emits today. They are kept so a detector added later can take them,
    /// and no emission site may produce one until it moves to the set above.
    public static let reservedRuleIDs: Set<String> = [
        "barcode.vision", "signature.heuristic",
    ]
}
