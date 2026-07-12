import Foundation

public enum RegexSentinelCheck {

    // W6-b §ReDoS sentinel — 200 ms leaves headroom for legitimate complex
    // patterns on older hardware; ratified in merry-hammock §ReDoS sentinel.
    static let validationBudget: Duration = .milliseconds(200)

    static let sentinelPayload: String = {
        let base = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 .,;:!?-_/()[]{}<>@#$%^&*+=\"'\n"
        let unicode = "π≠∞∑∂∫√→←↑↓αβγδεζηθικλ"
        var s = String()
        s.reserveCapacity(10_240)
        while s.count < 4_000 { s.append(base) }
        s.append(unicode)
        // Pathological `aaaa…aaab` block: exposes catastrophic backtracking
        // in patterns that survive stage 1's nested-quantifier heuristic.
        s.append(String(repeating: "a", count: 2_048))
        s.append("b")
        while s.count < 10_240 { s.append(base) }
        return String(s.prefix(10_240))
    }()

    @concurrent
    public static func validate(_ pattern: String) async -> Bool {
        // L-17 pre-compile ReDoS heuristic — reject obvious catastrophic
        // shapes synchronously, before detaching the enumerateMatches task
        // whose regex engine spins inside a non-cancellable C call. Also
        // covers ProfileImportExportService (single entry point).
        if RegexSafetyPrecheck.isLikelyPathological(pattern) { return false }

        guard DocumentSearcher.validateRegexPattern(pattern) != nil else { return false }

        let capturedPattern = pattern
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let resolver = ResumedFlag()

            // Orphans on catastrophic patterns; bounded by 200-char cap + OS finalization.
            Task.detached {
                guard let regex = try? NSRegularExpression(pattern: capturedPattern) else {
                    if resolver.setIfUnset() { cont.resume(returning: false) }
                    return
                }
                let payload = RegexSentinelCheck.sentinelPayload
                let deadline = ContinuousClock.now + RegexSentinelCheck.validationBudget
                regex.enumerateMatches(
                    in: payload,
                    range: NSRange(location: 0, length: (payload as NSString).length)
                ) { _, _, stop in
                    if ContinuousClock.now >= deadline {
                        stop.pointee = true
                    }
                }
                let accepted = ContinuousClock.now < deadline
                if resolver.setIfUnset() { cont.resume(returning: accepted) }
            }

            Task.detached {
                try? await Task.sleep(for: RegexSentinelCheck.validationBudget)
                if resolver.setIfUnset() { cont.resume(returning: false) }
            }
        }
    }

    private final class ResumedFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func setIfUnset() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if done { return false }
            done = true
            return true
        }
    }
}
