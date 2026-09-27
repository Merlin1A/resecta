import Foundation

/// What a Scan ran with, as the app recorded it at apply time: the preset
/// threshold vector and the user terms the run compiled. Rides the applied
/// record (never the query's identity) so the Detection Sweep re-runs the
/// scan exactly as the user ran it — a later apply of the same categories
/// replaces the configuration through the existing latest-apply rule.
///
/// The user-terms inputs are kept in the shape `UserTermsIndex.compile`
/// takes so the engine compiles them itself on the output; nothing here is
/// logged or persisted.
public struct ScanRunConfiguration: Sendable, Hashable {
    public let thresholdVector: PresetThresholdVector?
    public let alwaysFlag: [UserTerm]
    public let neverFlag: [UserTerm]

    public init(thresholdVector: PresetThresholdVector?, alwaysFlag: [UserTerm] = [], neverFlag: [UserTerm] = []) {
        self.thresholdVector = thresholdVector
        self.alwaysFlag = alwaysFlag
        self.neverFlag = neverFlag
    }

    /// The compiled user-terms index the searcher takes, nil when the run
    /// carried no user term (the searcher's own default).
    var userTermsIndex: UserTermsIndex? {
        guard !alwaysFlag.isEmpty || !neverFlag.isEmpty else { return nil }
        return UserTermsIndex.compile(alwaysFlag: alwaysFlag, neverFlag: neverFlag)
    }
}
