import Foundation

/// One answer to "pain 0 to 10?", asked after long runs and quality sessions,
/// and only of runners who report a recurring pain or injury area in the goal
/// interview (SPEC.md 3.5, F2, F9, section 8).
public struct PainCheckIn: Equatable, Sendable {
    public var date: Date
    /// 0 (none) to 10 (worst). Scores outside 0...10 are ignored, not clamped.
    public var score: Int

    public init(date: Date, score: Int) {
        self.date = date
        self.score = score
    }

    public static let validScores: ClosedRange<Int> = 0...10
}

/// Thresholds for the pain check-in rule. **Heuristics** from SPEC.md 3.5,
/// not clinical cut-offs. A limit below 0 is stored as its default instead
/// (see `valid`, #142), and so is `freezeDays` above its input-sanity bound
/// (`upperBound`, #147).
public struct PainRuleLimits: Equatable, Sendable {
    /// A score at or above this triggers the response. Default 4.
    public var highScore: Int { didSet { highScore = Self.valid(highScore, \.highScore) } }
    /// A rise of at least this much from the previous check-in triggers it. Default 2.
    public var minimumRise: Int { didSet { minimumRise = Self.valid(minimumRise, \.minimumRise) } }
    /// How long volume growth is frozen, in calendar days. Default 7 ("a week").
    public var freezeDays: Int { didSet { freezeDays = Self.valid(freezeDays, \.freezeDays) } }
    /// This many check-ins in a row at or above `highScore` count as
    /// persistent pain, which adds a prompt to see a clinician (3.5). Default 3.
    public var persistentCount: Int { didSet { persistentCount = Self.valid(persistentCount, \.persistentCount) } }

    public init(highScore: Int = 4, minimumRise: Int = 2, freezeDays: Int = 7, persistentCount: Int = 3) {
        self.highScore = Self.valid(highScore, \.highScore)
        self.minimumRise = Self.valid(minimumRise, \.minimumRise)
        self.freezeDays = Self.valid(freezeDays, \.freezeDays)
        self.persistentCount = Self.valid(persistentCount, \.persistentCount)
    }

    public static let `default` = PainRuleLimits()

    /// `value` for the limit at `field`, as it is stored (#142, the pattern
    /// of `AdaptationLimits.valid`, #133): a value below 0 falls back to that
    /// limit's default. A negative `persistentCount` crashed the rule
    /// (`suffix` of a negative length), a negative `highScore` or
    /// `minimumRise` fired it on every check-in (and `Int.min` overflowed
    /// where the engine cites the limit), and a negative `freezeDays` ended
    /// the freeze before it began. Values of 0 or more are kept as they are,
    /// so a `persistentCount` of 0 still never prompts a clinician visit.
    /// The fallback reads `default` only for a bad value, and every default
    /// is valid, so building `default` never reads itself.
    /// A limit above its `upperBound` falls back to its default too (#147).
    static func valid(_ value: Int, _ field: KeyPath<PainRuleLimits, Int>) -> Int {
        value >= 0 && value <= (upperBound(field) ?? .max) ? value : Self.default[keyPath: field]
    }

    /// The input-sanity upper bound of a limit used in date arithmetic (#147,
    /// `LimitBounds`; not a training rule): `freezeDays` 730 days. Nil for
    /// a score or a count, which is only compared.
    static func upperBound(_ field: KeyPath<PainRuleLimits, Int>) -> Int? {
        field == \PainRuleLimits.freezeDays ? LimitBounds.days : nil
    }
}

/// Why the pain rule fired. Both can apply to one check-in.
public enum PainTrigger: Equatable, Sendable {
    /// The score was at or above `PainRuleLimits.highScore`.
    case scoreAtOrAbove(threshold: Int)
    /// The score rose by `rise` (at least `PainRuleLimits.minimumRise`) from `previous`.
    case rise(previous: Int, rise: Int)
}

/// A quality session replaced by an easy run.
public struct QualitySwap: Equatable, Sendable {
    public let original: PlannedWorkout
    /// Same id, date and duration, kind `.easy` (see `PlannedWorkout.swappedToEasy()`).
    public let replacement: PlannedWorkout
}

/// What the plan must do after a pain check-in that fired the rule. It only
/// changes load; it never names a cause or a condition.
public struct PainResponse: Equatable, Sendable {
    public let checkIn: PainCheckIn
    public let triggers: [PainTrigger]
    /// Volume growth is frozen from `freezeStart` to `freezeEnd`
    /// (`PainRuleLimits.freezeDays` calendar days). Pass `freeze` to
    /// `GuardrailChecker.check(freezes:)` so plan changes respect it.
    public let freezeStart: Date
    public let freezeEnd: Date
    /// The first quality session after the check-in, turned easy; nil when
    /// none is planned after it or that session is already past.
    public let swap: QualitySwap?
    /// True when pain has stayed high for `PainRuleLimits.persistentCount`
    /// check-ins in a row: the app prompts the runner to see a clinician.
    public let suggestClinician: Bool
    public let explanation: String

    public var freeze: DateInterval { DateInterval(start: freezeStart, end: freezeEnd) }
}

public enum PainCheckInOutcome: Equatable, Sendable {
    /// The runner reported no pain history, so pain is not tracked and the rule never fires.
    case notTracked
    /// Tracked, but there is no valid check-in up to `asOf` to act on.
    case noCheckIns
    /// Nothing to do: the latest check-in did not fire the rule, its response
    /// was already applied, or its freeze has ended.
    case noAction
    case act(PainResponse)
}

/// The pain check-in rule (SPEC.md 3.5, section 8), a labeled heuristic:
/// if the runner tracks pain and the latest check-in is `highScore` or more,
/// or rose by `minimumRise` or more from the previous check-in, freeze volume
/// growth for `freezeDays` and swap the next quality session for easy running.
/// It never diagnoses; persistent pain only prompts a visit to a clinician.
///
/// Each check-in is acted on once. The rule keeps no state, so the caller
/// (the adaptation engine, F4) passes the date of the latest check-in whose
/// response it has already applied; a check-in at or before that date gives
/// `.noAction`, so one high score never swaps a second quality session. The
/// caller keeps enforcing the stored freeze itself until `freezeEnd`.
public enum PainCheckInRule {
    /// - Parameters:
    ///   - tracksPain: the explicit flag from the goal interview (F2). False
    ///     (no pain history reported, or not asked) means the rule never fires.
    ///   - checkIns: every check-in so far, in any order. Invalid scores and
    ///     check-ins after `asOf` are ignored.
    ///   - plan: sessions from the latest check-in onward, done ones included.
    ///     Only the first `.quality` session after the check-in is swapped, and
    ///     only while it is still ahead (its date is at or after `asOf`); once it
    ///     is past, the response carries the freeze alone. Later sessions are
    ///     never swapped for the same check-in.
    ///   - asOf: now. Once the freeze has ended (`asOf >= freezeEnd`) the
    ///     check-in is stale and gives `.noAction`.
    ///   - lastAppliedCheckIn: the date of the latest check-in whose response
    ///     the plan already contains, or nil if none has been applied.
    ///   - timeZone: the runner's time zone, for the calendar-day freeze and the wording.
    public static func evaluate(tracksPain: Bool,
                                checkIns: [PainCheckIn],
                                plan: [PlannedWorkout],
                                asOf: Date,
                                lastAppliedCheckIn: Date?,
                                timeZone: TimeZone,
                                limits: PainRuleLimits = .default) -> PainCheckInOutcome {
        guard tracksPain else { return .notTracked }
        let valid = checkIns
            .filter { PainCheckIn.validScores.contains($0.score) && $0.date <= asOf }
            .enumerated()
            .sorted { $0.element.date != $1.element.date ? $0.element.date < $1.element.date : $0.offset < $1.offset }
            .map(\.element)
        guard let latest = valid.last else { return .noCheckIns }
        if let applied = lastAppliedCheckIn, latest.date <= applied { return .noAction }

        var triggers: [PainTrigger] = []
        if latest.score >= limits.highScore {
            triggers.append(.scoreAtOrAbove(threshold: limits.highScore))
        }
        if valid.count >= 2 {
            let previous = valid[valid.count - 2].score
            let rise = latest.score - previous
            if rise >= limits.minimumRise {
                triggers.append(.rise(previous: previous, rise: rise))
            }
        }
        guard !triggers.isEmpty else { return .noAction }

        let cal = PlanCalendar.calendar(timeZone: timeZone)
        let freezeEnd = cal.date(byAdding: .day, value: limits.freezeDays, to: latest.date)
            ?? latest.date.addingTimeInterval(Double(limits.freezeDays) * 86_400)
        guard asOf < freezeEnd else { return .noAction }

        let firstQuality = plan
            .filter { $0.kind.isQuality && $0.date > latest.date }
            .min { $0.date < $1.date }
        let swap = firstQuality.flatMap { q in
            q.date >= asOf ? QualitySwap(original: q, replacement: q.swappedToEasy()) : nil
        }
        let recent = valid.suffix(limits.persistentCount)
        let persistent = limits.persistentCount > 0
            && recent.count == limits.persistentCount
            && recent.allSatisfy { $0.score >= limits.highScore }

        let explanation = explain(latest: latest, triggers: triggers, freezeEnd: freezeEnd, swap: swap,
                                  missedQuality: firstQuality != nil && swap == nil,
                                  persistent: persistent, timeZone: timeZone, limits: limits)
        return .act(PainResponse(checkIn: latest, triggers: triggers, freezeStart: latest.date, freezeEnd: freezeEnd,
                                 swap: swap, suggestClinician: persistent, explanation: explanation))
    }

    private static func explain(latest: PainCheckIn, triggers: [PainTrigger], freezeEnd: Date, swap: QualitySwap?,
                                missedQuality: Bool, persistent: Bool, timeZone: TimeZone, limits: PainRuleLimits) -> String {
        let reasons = triggers.map { trigger -> String in
            switch trigger {
            case .scoreAtOrAbove(let threshold):
                return "it is \(threshold) or more"
            case .rise(let previous, let rise):
                return "it rose by \(rise) from \(previous)/10 at your previous check-in"
            }
        }
        var text = "You rated pain \(latest.score)/10 on \(PlanFormatting.day(latest.date, timeZone: timeZone)), and \(reasons.joined(separator: " and ")). "
        text += "As a precaution, weekly volume won't grow for \(limits.freezeDays) days (until \(PlanFormatting.day(freezeEnd, timeZone: timeZone)))"
        if let swap {
            text += ", and your next quality session on \(PlanFormatting.day(swap.original.date, timeZone: timeZone)) becomes an easy run."
        } else if missedQuality {
            text += ". The next quality session after this check-in has already passed, so none is swapped."
        } else {
            text += ". No quality session is planned after this check-in, so none is swapped."
        }
        if persistent {
            text += " Pain has been \(limits.highScore) or more at your last \(limits.persistentCount) check-ins, so please see a clinician about it."
        }
        text += " This is a training adjustment, not a diagnosis. (Heuristic, SPEC 3.5.)"
        return text
    }
}
