// TimeZone is not Sendable in swift-corelibs-foundation (Linux, Swift 5.10).
@preconcurrency import Foundation

// SPEC.md 3.5 rule 7 beyond the stop trigger itself (#73): usual pain, the
// next-morning trigger, how a stop ends (a passed test run), the return after
// it (the return guards) and the clinician flag. The pure rules live here;
// `AdaptationEngine+PainRecovery.swift` applies them inside the F4 engine.
//
// **Every number here is a heuristic** (SPEC 3.5 rule 7: "Evidence: weak").
// The 2-morning count, the test-run length and the +1 margin are coaching
// conventions; the 3 reports, 7 and 14 days, 6 weeks, the median of the last
// 5 check-ins, the interview seed, the frozen usual level, the usual +1
// allowance on week-1 return runs, rounding a half-point median down, when a
// runner counts as staying stopped and the 65% cap after short stops are
// product heuristics. The 4/10 limit matches the check-in's, the 48-hour
// limit follows [19], walking at 2/10 or less follows [17], alternate days
// in week 1 and distance before speed follow [18], and the step back follows
// [20]. Nothing here is a default for a particular runner: usual pain comes
// from the runner's own goal-interview answer (F2) and check-ins. CoachCore
// never diagnoses; the clinician advice is the app's wording.

/// The heuristics of SPEC.md 3.5 rule 7's end path, return and clinician
/// flag. Every default is the figure the rule names; none is a clinical cut-off.
/// A `Double` limit that isn't a finite number, or is below 0, is stored as its
/// default instead (see `valid`, #133), and so is a whole-number limit below 0
/// (#157) or, where it is used in date, week or score arithmetic, above its
/// input-sanity bound (`upperBound`, #147), and a `rampDaysOff` outside
/// `rampDaysOffBounds` (#157).
public struct PainRecoveryLimits: Equatable, Sendable {
    // Usual pain
    /// Usual pain is the median of this many latest stable post-run check-ins. Default 5.
    public var usualWindow: Int { didSet { usualWindow = Self.valid(usualWindow, \.usualWindow) } }
    /// Fewer stable check-ins than this and usual is the interview seed. Default 3.
    public var usualMinimumCheckIns: Int { didSet { usualMinimumCheckIns = Self.valid(usualMinimumCheckIns, \.usualMinimumCheckIns) } }

    // Next-morning trigger
    /// Next-morning pain this far above usual stops running. Default 2.
    public var nextMorningRise: Int { didSet { nextMorningRise = Self.valid(nextMorningRise, \.nextMorningRise) } }
    /// Next-morning pain at or above this stops running (the check-in's 4/10). Default 4.
    public var nextMorningHigh: Int { didSet { nextMorningHigh = Self.valid(nextMorningHigh, \.nextMorningHigh) } }
    /// Pain still above usual this many hours after the run stops running [19]. Default 48.
    public var persistHours: Double { didSet { persistHours = Self.valid(persistHours, \.persistHours) } }
    /// Weeks whose highest next-morning scores must rise in turn to freeze
    /// growth ("a rise over successive weeks"; 3 weeks is two rises). Default 3.
    public var risingWeeks: Int { didSet { risingWeeks = Self.valid(risingWeeks, \.risingWeeks) } }
    /// How long a next-morning freeze holds volume growth, in days ("for a week"). Default 7.
    public var freezeDays: Int { didSet { freezeDays = Self.valid(freezeDays, \.freezeDays) } }

    // Ending a stop
    /// Mornings in a row at or below usual before a test run. Default 2.
    public var morningsToEnd: Int { didSet { morningsToEnd = Self.valid(morningsToEnd, \.morningsToEnd) } }
    /// Pain on daily walking at or below this allows a test run [17]. Default 2.
    public var walkingMax: Int { didSet { walkingMax = Self.valid(walkingMax, \.walkingMax) } }
    /// The test run is at most this long, in seconds. Default 30 min.
    public var testMaxSeconds: Double { didSet { testMaxSeconds = Self.valid(testMaxSeconds, \.testMaxSeconds) } }
    /// The test run when the runner's usual easy run is unknown, in seconds. Default 20 min.
    public var testDefaultSeconds: Double { didSet { testDefaultSeconds = Self.valid(testDefaultSeconds, \.testDefaultSeconds) } }
    /// ...or this share of a usual easy run, when that is shorter. Default 0.5.
    public var testShareOfEasy: Double { didSet { testShareOfEasy = Self.valid(testShareOfEasy, \.testShareOfEasy) } }
    /// The shortest test run, in seconds, so half a very short easy run
    /// still makes a test (product heuristic). Default 10 min.
    public var testMinSeconds: Double { didSet { testMinSeconds = Self.valid(testMinSeconds, \.testMinSeconds) } }
    /// During a test run pain may be at most this far above usual. Default 1.
    public var testAllowance: Int { didSet { testAllowance = Self.valid(testAllowance, \.testAllowance) } }
    /// ...and at most this score. Default 3.
    public var testMaxScore: Int { didSet { testMaxScore = Self.valid(testMaxScore, \.testMaxScore) } }
    /// A stop that starts with usual at or above this can't end by the test
    /// run: the runner stays stopped with the clinician flag on. Default 4.
    public var cannotEndUsual: Int { didSet { cannotEndUsual = Self.valid(cannotEndUsual, \.cannotEndUsual) } }
    /// Walking pain at or above this about `stuckDays` into a stop keeps the
    /// runner stopped with the clinician flag on. Default 3.
    public var walkingStuck: Int { didSet { walkingStuck = Self.valid(walkingStuck, \.walkingStuck) } }
    /// When walking pain (and, with no pain history, pain above 0) is judged
    /// for staying stopped, in days from the stop's start. Default 7.
    public var stuckDays: Int { didSet { stuckDays = Self.valid(stuckDays, \.stuckDays) } }

    // The return
    /// Week 1's share of the pre-stop level, weekly and for the long run
    /// (rule 4's week-1 step, about 60 to 70%). Default 0.65.
    public var week1Fraction: Double { didSet { week1Fraction = Self.valid(week1Fraction, \.week1Fraction) } }
    /// Rule 6 grows back to the plan over this many weeks after week 1 ("1 to
    /// 2 weeks"; 2, the more cautious). Default 2.
    public var regrowthWeeks: Int { didSet { regrowthWeeks = Self.valid(regrowthWeeks, \.regrowthWeeks) } }
    /// Rule 4's week-2 step, used when the runner took `rampDaysOff` days off
    /// (about 80 to 90%). Default 0.85.
    public var rampWeek2Fraction: Double { didSet { rampWeek2Fraction = Self.valid(rampWeek2Fraction, \.rampWeek2Fraction) } }
    /// Days off for which rule 4's ramp applies (6 to 14). A range that
    /// doesn't lie within `rampDaysOffBounds` is stored as the default (#157).
    public var rampDaysOff: ClosedRange<Int> { didSet { rampDaysOff = Self.valid(rampDaysOff) } }
    /// The week at full plan volume counts as run "at plan volume" when what
    /// was run reaches this share of its fixed reference
    /// (`PainReturn.reference(forWeek:)`), a margin for GPS and moving-time
    /// noise. Default 0.9, pending the owner's OK (#92).
    public var fullWeekShare: Double { didSet { fullWeekShare = Self.valid(fullWeekShare, \.fullWeekShare) } }
    /// The most the return's level may be when the stop has none: the latest
    /// week in the spike window before the stop, capped at this small floor
    /// (three 30-minute easy runs), or the floor alone. In seconds when the
    /// guardrails measure time. Default 90 min, pending the owner's OK (#92).
    public var unknownLevelSeconds: Double { didSet { unknownLevelSeconds = Self.valid(unknownLevelSeconds, \.unknownLevelSeconds) } }
    /// The same floor in metres when the guardrails measure distance. Default 15 km.
    public var unknownLevelMetres: Double { didSet { unknownLevelMetres = Self.valid(unknownLevelMetres, \.unknownLevelMetres) } }

    // Clinician flag
    /// Reports in a row at or below usual (one of them a passed test run) that turn the flag off. Default 3.
    public var flagReportsToClear: Int { didSet { flagReportsToClear = Self.valid(flagReportsToClear, \.flagReportsToClear) } }
    /// With no report for this many days, the app asks once. Default 7.
    public var flagAskDays: Int { didSet { flagAskDays = Self.valid(flagAskDays, \.flagAskDays) } }
    /// With no report for this many days, the stretch closes as unresolved. Default 14.
    public var flagCloseDays: Int { didSet { flagCloseDays = Self.valid(flagCloseDays, \.flagCloseDays) } }
    /// A new stop trigger within this many days of the flag turning off or
    /// closing reopens it (6 weeks). Default 42.
    public var flagReopenDays: Int { didSet { flagReopenDays = Self.valid(flagReopenDays, \.flagReopenDays) } }

    public init(usualWindow: Int = 5, usualMinimumCheckIns: Int = 3,
                nextMorningRise: Int = 2, nextMorningHigh: Int = 4, persistHours: Double = 48, risingWeeks: Int = 3,
                freezeDays: Int = 7,
                morningsToEnd: Int = 2, walkingMax: Int = 2, testMaxSeconds: Double = 30 * 60,
                testDefaultSeconds: Double = 20 * 60, testShareOfEasy: Double = 0.5, testMinSeconds: Double = 10 * 60,
                testAllowance: Int = 1, testMaxScore: Int = 3, cannotEndUsual: Int = 4, walkingStuck: Int = 3,
                stuckDays: Int = 7,
                week1Fraction: Double = 0.65, regrowthWeeks: Int = 2, rampWeek2Fraction: Double = 0.85,
                rampDaysOff: ClosedRange<Int> = 6...14, fullWeekShare: Double = 0.9,
                unknownLevelSeconds: Double = 90 * 60, unknownLevelMetres: Double = 15_000,
                flagReportsToClear: Int = 3, flagAskDays: Int = 7, flagCloseDays: Int = 14, flagReopenDays: Int = 42) {
        self.usualWindow = Self.valid(usualWindow, \.usualWindow)
        self.usualMinimumCheckIns = Self.valid(usualMinimumCheckIns, \.usualMinimumCheckIns)
        self.nextMorningRise = Self.valid(nextMorningRise, \.nextMorningRise)
        self.nextMorningHigh = Self.valid(nextMorningHigh, \.nextMorningHigh)
        self.persistHours = Self.valid(persistHours, \.persistHours)
        self.risingWeeks = Self.valid(risingWeeks, \.risingWeeks)
        self.freezeDays = Self.valid(freezeDays, \.freezeDays)
        self.morningsToEnd = Self.valid(morningsToEnd, \.morningsToEnd)
        self.walkingMax = Self.valid(walkingMax, \.walkingMax)
        self.testMaxSeconds = Self.valid(testMaxSeconds, \.testMaxSeconds)
        self.testDefaultSeconds = Self.valid(testDefaultSeconds, \.testDefaultSeconds)
        self.testShareOfEasy = Self.valid(testShareOfEasy, \.testShareOfEasy)
        self.testMinSeconds = Self.valid(testMinSeconds, \.testMinSeconds)
        self.testAllowance = Self.valid(testAllowance, \.testAllowance)
        self.testMaxScore = Self.valid(testMaxScore, \.testMaxScore)
        self.cannotEndUsual = Self.valid(cannotEndUsual, \.cannotEndUsual)
        self.walkingStuck = Self.valid(walkingStuck, \.walkingStuck)
        self.stuckDays = Self.valid(stuckDays, \.stuckDays)
        self.week1Fraction = Self.valid(week1Fraction, \.week1Fraction)
        self.regrowthWeeks = Self.valid(regrowthWeeks, \.regrowthWeeks)
        self.rampWeek2Fraction = Self.valid(rampWeek2Fraction, \.rampWeek2Fraction)
        self.rampDaysOff = Self.valid(rampDaysOff)
        self.fullWeekShare = Self.valid(fullWeekShare, \.fullWeekShare)
        self.unknownLevelSeconds = Self.valid(unknownLevelSeconds, \.unknownLevelSeconds)
        self.unknownLevelMetres = Self.valid(unknownLevelMetres, \.unknownLevelMetres)
        self.flagReportsToClear = Self.valid(flagReportsToClear, \.flagReportsToClear)
        self.flagAskDays = Self.valid(flagAskDays, \.flagAskDays)
        self.flagCloseDays = Self.valid(flagCloseDays, \.flagCloseDays)
        self.flagReopenDays = Self.valid(flagReopenDays, \.flagReopenDays)
    }

    public static let `default` = PainRecoveryLimits()

    /// `value` for the limit at `field`, as it is stored (#133): a value that
    /// isn't a finite number, or is below 0, falls back to that limit's
    /// default, so a bad tunable can't crash the engine where it rounds a
    /// limit to a whole number (a test run's length, a ceiling's percent) or
    /// stall the return. Every `Double` limit goes through this, when the
    /// limits are built and whenever one is set; finite values at or above 0
    /// are kept as they are. The fallback reads `default` only for a bad
    /// value, and every default is valid, so building `default` never reads itself.
    static func valid(_ value: Double, _ field: KeyPath<PainRecoveryLimits, Double>) -> Double {
        value.isFinite && value >= 0 ? value : Self.default[keyPath: field]
    }

    /// `value` for the whole-number limit at `field`, as it is stored: below
    /// 0 falls back to the default (#157, as #142 does for `PainRuleLimits`;
    /// before, an `Int.min` `flagCloseDays` crashed the engine, and a negative
    /// score, count or day limit ran its rule inside out, such as a
    /// `nextMorningHigh` of -1 stopping running on every morning report), and
    /// so does a value above its `upperBound` (#147). Every whole-number limit
    /// goes through this, when the limits are built and whenever one is set.
    /// 0 and every value up to the bound are kept, with the meaning the rules
    /// already give them: a limit read through `max(...)` (`usualWindow`,
    /// `usualMinimumCheckIns`, `nextMorningRise`, `risingWeeks`, `freezeDays`,
    /// `morningsToEnd`, `regrowthWeeks`, `flagReportsToClear`) acts as that
    /// floor, and every other one is taken as it is: a score limit of 0 is a
    /// score of 0, a `testAllowance` of 0 allows no pain above usual in a
    /// test run, and a day limit of 0 acts on the day itself.
    static func valid(_ value: Int, _ field: KeyPath<PainRecoveryLimits, Int>) -> Int {
        value >= 0 && value <= (upperBound(field) ?? .max) ? value : Self.default[keyPath: field]
    }

    /// Where `rampDaysOff` must lie (#157): from 0 days off, since days off
    /// are never negative, to `LimitBounds.days`, the input-sanity bound of a
    /// limit counted in days, not a training rule. Before, `6...Int.max` was
    /// kept and applied rule 4's week-2 step after a break of any length.
    public static let rampDaysOffBounds = 0...LimitBounds.days

    /// `rampDaysOff` as it is stored: a range outside `rampDaysOffBounds`
    /// (below 0 at its start, or above the bound at its end) falls back to
    /// the default, 6 to 14. Every range inside is kept, a single day
    /// included. A `ClosedRange` is never empty, so there is no empty case.
    static func valid(_ value: ClosedRange<Int>) -> ClosedRange<Int> {
        rampDaysOffBounds.contains(value.lowerBound) && rampDaysOffBounds.contains(value.upperBound)
            ? value : Self.default.rampDaysOff
    }

    /// The input-sanity upper bound of a whole-number limit used in date,
    /// week or score arithmetic (#147, `LimitBounds`; not a training rule):
    /// `freezeDays` and `flagCloseDays` 730 days, `risingWeeks` and
    /// `regrowthWeeks` 104 weeks, and the margins added to a 0 to 10 score,
    /// `nextMorningRise` and `testAllowance`, 100. `Int.max` in
    /// `nextMorningRise`, `testAllowance`, `risingWeeks` or `regrowthWeeks`
    /// overflowed the engine. Nil for a score, a count or a day count that is
    /// only compared.
    static func upperBound(_ field: KeyPath<PainRecoveryLimits, Int>) -> Int? {
        switch field {
        case \PainRecoveryLimits.freezeDays, \PainRecoveryLimits.flagCloseDays: return LimitBounds.days
        case \PainRecoveryLimits.risingWeeks, \PainRecoveryLimits.regrowthWeeks: return LimitBounds.weeks
        case \PainRecoveryLimits.nextMorningRise, \PainRecoveryLimits.testAllowance: return LimitBounds.painScoreMargin
        default: return nil
        }
    }
}

// MARK: - Usual pain

/// One stable post-run check-in: taken while no pain stop, return or
/// clinician flag was active (SPEC 3.5 rule 7).
public struct UsualPainSample: Equatable, Sendable, Codable {
    public let date: Date
    public let score: Int

    public init(date: Date, score: Int) {
        self.date = date
        self.score = score
    }
}

/// Usual pain: the runner's own level for their pain spot (SPEC.md 3.5 rule 7).
public enum UsualPain {
    /// The median of `scores`, a half-point median rounded down (which makes
    /// every limit stricter). Nil for no scores. Scores outside 0...10 are ignored.
    public static func median(_ scores: [Int]) -> Int? {
        let s = scores.filter { PainCheckIn.validScores.contains($0) }.sorted()
        guard !s.isEmpty else { return nil }
        let mid = s.count / 2
        return s.count % 2 == 1 ? s[mid] : (s[mid - 1] + s[mid]) / 2   // integer division rounds a half down
    }

    /// Usual pain from the runner's own data: 0 for a runner with no pain
    /// history (`tracksPain` false); otherwise the median of the latest
    /// `usualWindow` stable check-ins once `usualMinimumCheckIns` exist (all
    /// of them while there are fewer than `usualWindow`), and until then the
    /// goal-interview seed (F2). A runner who tracks pain but gave no valid
    /// seed starts at 0, the strictest level. CoachCore models one pain spot
    /// (#92): an app with several interview spots passes the lowest seed.
    /// While a stop, return or flag is active the engine uses the value frozen
    /// when the stop began instead (`PainRecovery.frozenUsual`).
    public static func value(samples: [UsualPainSample], seed: Int?, tracksPain: Bool,
                             limits: PainRecoveryLimits = .default) -> Int {
        guard tracksPain else { return 0 }
        let valid = samples.filter { PainCheckIn.validScores.contains($0.score) && $0.date.timeIntervalSinceReferenceDate.isFinite }
            .sorted { $0.date < $1.date }
        if valid.count >= max(1, limits.usualMinimumCheckIns),
           let m = median(valid.suffix(max(1, limits.usualWindow)).map(\.score)) {
            return m
        }
        return seed.flatMap { PainCheckIn.validScores.contains($0) ? $0 : nil } ?? 0
    }
}

// MARK: - Next-morning trigger

/// The next-morning trigger (SPEC.md 3.5 rule 7, section 8).
public enum NextMorningRule {
    public enum Verdict: Equatable, Sendable {
        /// Within the runner's usual pain.
        case none
        /// One above usual: volume growth freezes for a week, as the check-in does.
        case freeze
        /// 2 or more above usual, 4/10 or more, or still above usual 48 hours
        /// after the run: running stops (a pain stop).
        case stop
    }

    /// The verdict on a morning report. Pain of unknown size (no valid score)
    /// is read as a stop, the stricter reading. An after-run report gives `.none`.
    public static func verdict(_ report: PainReport, usual: Int, hoursSinceRun: Double?,
                               limits: PainRecoveryLimits = .default) -> Verdict {
        guard report.timing == .nextMorning, report.isValid else { return .none }
        guard let level = report.painLevel else { return .stop }
        if level >= usual + max(1, limits.nextMorningRise) || level >= limits.nextMorningHigh { return .stop }
        guard level > usual else { return .none }
        if let h = hoursSinceRun, h.isFinite, h >= limits.persistHours { return .stop }
        return .freeze
    }

    /// True when the highest next-morning scores of the latest
    /// `risingWeeks` calendar weeks up to `asOf` (the week holding `asOf`
    /// and the ones before it, each with a scored morning report) rose week
    /// after week: "a rise over successive weeks" freezes volume growth for a
    /// week (heuristic reading of SPEC 3.5 rule 7, after [21]).
    public static func risingOverWeeks(_ reports: [PainReport], asOf: Date, timeZone: TimeZone,
                                       limits: PainRecoveryLimits = .default) -> Bool {
        let n = max(2, limits.risingWeeks)
        let mornings = reports.filter { $0.isValid && $0.timing == .nextMorning && $0.date <= asOf }
        guard !mornings.isEmpty else { return false }
        let cal = PlanCalendar.calendar(timeZone: timeZone)
        let thisWeek = PlanCalendar.weekStart(containing: asOf, timeZone: timeZone)
        var peaks: [Int] = []
        for k in stride(from: n - 1, through: 0, by: -1) {
            guard let start = cal.date(byAdding: .day, value: -7 * k, to: thisWeek) else { return false }
            let week = PlanCalendar.weekStart(containing: start.addingTimeInterval(3600), timeZone: timeZone)
            let scores = mornings.filter { PlanCalendar.weekStart(containing: $0.date, timeZone: timeZone) == week }
                .compactMap(\.validScore)
            guard let peak = scores.max() else { return false }
            peaks.append(peak)
        }
        return zip(peaks, peaks.dropFirst()).allSatisfy { $0 < $1 }
    }
}

// MARK: - Ending a stop

/// The test run that can end a stop (SPEC.md 3.5 rule 7): easy and flat, 20
/// to 30 minutes or half a usual easy run.
public struct PainTestRun: Equatable, Sendable, Codable {
    /// The planned session the engine made the test run.
    public let workoutID: String
    /// When it was offered: the second qualifying morning.
    public let offeredAt: Date
    public let seconds: Double
    /// The run done for it, once synced.
    public var activityID: String?
    public var ranAt: Date?
    /// True once the in-run report stayed within the test-run limits; nil
    /// until that report comes.
    public var inRunPassed: Bool?

    public init(workoutID: String, offeredAt: Date, seconds: Double, activityID: String? = nil, ranAt: Date? = nil,
                inRunPassed: Bool? = nil) {
        self.workoutID = workoutID
        self.offeredAt = offeredAt
        self.seconds = seconds
        self.activityID = activityID
        self.ranAt = ranAt
        self.inRunPassed = inRunPassed
    }
}

/// The pure parts of SPEC 3.5 rule 7's end path.
public enum PainStopEndRule {
    /// True for a morning report that counts toward ending a stop: pain at
    /// or below usual, walking pain known and at or below `walkingMax`, no
    /// movement change and no red flag.
    public static func qualifies(_ r: PainReport, usual: Int, limits: PainRecoveryLimits = .default) -> Bool {
        guard r.isValid, r.timing == .nextMorning, !r.changedMovement, r.redFlags.isEmpty,
              let level = r.painLevel, level <= usual,
              let walk = r.validWalkingScore, walk <= limits.walkingMax else { return false }
        return true
    }

    /// The date of the latest of `morningsToEnd` qualifying mornings on
    /// consecutive calendar days, when those are the latest morning reports
    /// after `from`; nil otherwise. A morning that doesn't qualify restarts
    /// the count; so does a missed day. Two reports on one day count as one,
    /// the worse of them (heuristic).
    public static func readySince(reports: [PainReport], from: Date, usual: Int, timeZone: TimeZone,
                                  limits: PainRecoveryLimits = .default) -> Date? {
        let need = max(1, limits.morningsToEnd)
        let cal = PlanCalendar.calendar(timeZone: timeZone)
        let mornings = reports.filter { $0.isValid && $0.timing == .nextMorning && $0.date > from }
        var byDay: [Date: [PainReport]] = [:]
        for r in mornings { byDay[cal.startOfDay(for: r.date), default: []].append(r) }
        let days = byDay.keys.sorted()
        guard days.count >= need else { return nil }
        let last = Array(days.suffix(need))
        for (a, b) in zip(last, last.dropFirst()) {
            guard (cal.dateComponents([.day], from: a, to: b).day ?? 0) == 1 else { return nil }
        }
        for d in last where !(byDay[d] ?? []).allSatisfy({ qualifies($0, usual: usual, limits: limits) }) { return nil }
        return byDay[last[last.count - 1]]?.map(\.date).max()
    }

    /// The test run's length: half the runner's usual easy run, at most
    /// `testMaxSeconds` and at least `testMinSeconds`; `testDefaultSeconds`
    /// when the usual easy run is unknown, zero, NaN or infinite.
    public static func testSeconds(usualEasySeconds: Double?, limits: PainRecoveryLimits = .default) -> Double {
        guard let e = usualEasySeconds, e.isFinite, e > 0 else { return limits.testDefaultSeconds }
        return min(limits.testMaxSeconds, max(limits.testMinSeconds, e * limits.testShareOfEasy))
    }

    /// True when the in-run report of a test run stays within the test-run
    /// limits: pain at most usual + `testAllowance` and at most `testMaxScore`
    /// (at most usual when the stop came from a movement change), and no
    /// movement change or red flag. Pain that got worse during the run is
    /// judged only by these limits. Pain of unknown size fails.
    public static func inRunPasses(_ r: PainReport, usual: Int, stopFromMovement: Bool,
                                   limits: PainRecoveryLimits = .default) -> Bool {
        guard r.isValid, !r.changedMovement, r.redFlags.isEmpty, let level = r.painLevel else { return false }
        if stopFromMovement { return level <= usual }
        return level <= usual + limits.testAllowance && level <= limits.testMaxScore
    }
}

// MARK: - The return

/// The return after a pain stop (SPEC.md 3.5 rule 7, with rules 4 and 6).
/// Steps run in plan weeks: step 1 is rule 7's week 1, then each plan week is
/// one step more, up to the step at full plan volume. A step back moves to
/// the step before, which then runs for a full plan week.
public struct PainReturn: Equatable, Sendable, Codable {
    /// When the stop ended (the morning after the passed test run).
    public let start: Date
    /// The pre-stop weekly level (`PainStop.level`), in the guardrail measure.
    public let level: Double?
    /// The pre-stop long run, in the guardrail measure; nil when unknown.
    public let preStopLongRun: Double?
    /// Days with no running before the test run, which decide whether rule
    /// 4's ramp applies; nil when no earlier run is known.
    public let daysOff: Int?
    /// The stop came from a movement change.
    public let fromMovement: Bool
    /// The step in force from `stepWeek` on (and in the weeks before it).
    public var step: Int
    /// Monday 00:00 of the plan week from which `step` counts up.
    public var stepWeek: Date
    /// Steps at which symptoms came back, in order: a second failure at the
    /// same step reopens the stop.
    public var failedSteps: [Int]
    /// Local midnight of the rest day after a recurrence, while it is to come.
    public var restDay: Date?
    /// The plan's weekly run volumes from the stop's week on, as the plan
    /// stood when the stop began, before the stop, the return, the
    /// guardrails over the stopped weeks or any freeze cut it.
    public var planWeeks: [PlanWeekVolume]

    public init(start: Date, level: Double?, preStopLongRun: Double?, daysOff: Int?, fromMovement: Bool,
                step: Int = 1, stepWeek: Date, failedSteps: [Int] = [], restDay: Date? = nil,
                planWeeks: [PlanWeekVolume] = []) {
        self.start = start
        self.level = level
        self.preStopLongRun = preStopLongRun
        self.daysOff = daysOff
        self.fromMovement = fromMovement
        self.step = step
        self.stepWeek = stepWeek
        self.failedSteps = failedSteps
        self.restDay = restDay
        self.planWeeks = planWeeks
    }

    /// The fixed volume the week at full plan volume is judged against: the
    /// pre-stop level, or that plan week's volume as planned before the stop
    /// where it is lower (a recovery week, a taper). Nil without a known
    /// level, in which case no week counts. Heuristic, SPEC 3.5 rule 7.
    public func reference(forWeek week: Date) -> Double? {
        guard let level, level.isFinite, level > 0 else { return nil }
        guard let planned = planWeeks.first(where: { $0.week == week })?.volume, planned.isFinite, planned > 0 else { return level }
        return min(level, planned)
    }

    /// The step in force in the plan week starting `week`.
    public func step(atWeek week: Date, timeZone: TimeZone, limits: PainRecoveryLimits = .default) -> Int {
        guard week >= stepWeek else { return step }
        let cal = PlanCalendar.calendar(timeZone: timeZone)
        let days = cal.dateComponents([.day], from: stepWeek, to: week).day ?? 0
        let weeks = Int((Double(days) / 7).rounded())
        return min(PainReturnRule.planVolumeStep(limits), step + weeks)
    }

    /// The plan week at which the full plan-volume step runs (the step that
    /// lifts the quality ban once it passes with no symptoms).
    public func planVolumeWeek(timeZone: TimeZone, limits: PainRecoveryLimits = .default) -> Date {
        let cal = PlanCalendar.calendar(timeZone: timeZone)
        let ahead = max(0, PainReturnRule.planVolumeStep(limits) - step)
        let d = cal.date(byAdding: .day, value: 7 * ahead, to: stepWeek) ?? stepWeek
        return PlanCalendar.weekStart(containing: d.addingTimeInterval(3600), timeZone: timeZone)
    }
}

/// One plan week's run volume (guardrail measure, races and rest left out).
public struct PlanWeekVolume: Equatable, Sendable, Codable {
    /// Monday 00:00 of the plan week.
    public let week: Date
    public let volume: Double

    public init(week: Date, volume: Double) {
        self.week = week
        self.volume = volume
    }
}

/// The pure parts of the return guards (SPEC 3.5 rule 7 with rules 4 and 6).
public enum PainReturnRule {
    /// The first step at full plan volume: one after rule 6's regrowth
    /// weeks, and never before rule 4's week 3.
    public static func planVolumeStep(_ limits: PainRecoveryLimits = .default) -> Int {
        max(3, max(1, limits.regrowthWeeks) + 1)
    }

    /// The weekly ceiling at `step` as a share of the pre-stop level, or nil
    /// at full plan volume (the plan and the guardrails then decide). Step 1
    /// is rule 7's week 1 at `week1Fraction`. Later steps take the lower of
    /// rule 6's regrowth (a straight line from week 1 to the plan over
    /// `regrowthWeeks`) and, when the runner took `rampDaysOff` days off,
    /// rule 4's week-2 step. After more than 14 days off, rules 1 and 2 (the
    /// guardrail checker over the runner's actual weeks) bound it as well.
    /// SPEC gives week 1's weekly volume only through the long-run cap; using
    /// the same 65% for the week is the stricter reading, pending the
    /// owner's OK (#92).
    public static func ceilingFraction(step: Int, daysOff: Int?, limits: PainRecoveryLimits = .default) -> Double? {
        // `PainRecoveryLimits.valid` stores `week1Fraction` finite and at
        // least 0 (#133), so a non-finite value can't reach here; only a value
        // above 1 is clamped (a return never starts above the pre-stop level).
        let w1 = min(1, limits.week1Fraction)
        let full = planVolumeStep(limits)
        guard step < full else { return nil }
        if step <= 1 { return w1 }
        let n = Double(max(1, limits.regrowthWeeks))
        let regrowth = min(1, w1 + (1 - w1) * Double(step - 1) / n)
        var f = regrowth
        if let d = daysOff, limits.rampDaysOff.contains(d), step == 2 { f = min(f, limits.rampWeek2Fraction) }
        return f < 1 ? f : nil
    }

    /// True when a run's report shows symptoms for the return step: at step 1,
    /// pain above usual + `testAllowance` or above `testMaxScore`; later,
    /// pain above usual. A movement change is always symptoms (it reopens the
    /// stop at once). Pain of unknown size counts as symptoms.
    public static func symptoms(level: Int?, changedMovement: Bool, step: Int, usual: Int,
                                limits: PainRecoveryLimits = .default) -> Bool {
        if changedMovement { return true }
        guard let level else { return true }
        if step <= 1 { return level > usual + limits.testAllowance || level > limits.testMaxScore }
        return level > usual
    }
}

// MARK: - Clinician flag

/// Why the clinician flag was raised (SPEC.md 3.5 rule 7). Every raise also
/// starts or reopens a pain stop.
public enum ClinicianFlagReason: String, CaseIterable, Equatable, Hashable, Sendable, Codable {
    /// Pain above usual on most days for about 7 days [22].
    case lastingAboveUsual
    /// A red flag (`PainRedFlag`) [23].
    case redFlag
    /// Symptoms came back twice at the same step of the return.
    case secondFailure
    /// The runner stays stopped: usual 4 or more at the start of the stop,
    /// walking pain still 3 or more about 7 days in, or (with no pain
    /// history) pain still above 0 then.
    case staysStopped
    /// A new stop trigger within 6 weeks of the flag turning off or closing.
    case reopened
    /// A change in how the runner moves during the return after a stop: it
    /// reopens the stop and, as a lasting movement change (a red flag),
    /// raises the flag. The stricter reading, a heuristic pending the
    /// owner's OK (#92).
    case movementChangeInReturn
}

/// The clinician flag (SPEC.md 3.5 rule 7): the app advises seeing a
/// clinician, in its own words, while it is on. It turns off only after
/// `flagReportsToClear` reports in a row at or below usual, at least one of
/// them a passed test run (which counts as one report). Silence never clears
/// it: with no reports the app asks once at `flagAskDays` and the stretch
/// closes as unresolved at `flagCloseDays`, which never ends a stop.
public struct ClinicianFlag: Equatable, Sendable, Codable {
    public let raisedAt: Date
    /// Every reason seen while it is on, in the order first seen.
    public var reasons: [ClinicianFlagReason]
    /// Reports in a row at or below usual since the last one above it.
    public var streak: Int
    /// A passed test run is among them.
    public var streakHasPassedTest: Bool
    /// The latest report while it is on.
    public var lastReport: Date?
    /// When the app was told to ask for a report after `flagAskDays` without one.
    public var askedAt: Date?

    public init(raisedAt: Date, reasons: [ClinicianFlagReason], streak: Int = 0, streakHasPassedTest: Bool = false,
                lastReport: Date? = nil, askedAt: Date? = nil) {
        self.raisedAt = raisedAt
        self.reasons = reasons
        self.streak = streak
        self.streakHasPassedTest = streakHasPassedTest
        self.lastReport = lastReport
        self.askedAt = askedAt
    }

    /// True once the reports in a row clear it.
    public func clears(_ limits: PainRecoveryLimits = .default) -> Bool {
        streak >= max(1, limits.flagReportsToClear) && streakHasPassedTest
    }
}

/// How a clinician flag stretch ended, for the 6-week reopen window.
public struct ClinicianFlagEnd: Equatable, Sendable, Codable {
    public enum How: String, Equatable, Sendable, Codable {
        /// Reports at or below usual cleared it.
        case cleared
        /// No report for `flagCloseDays`: closed as unresolved (advice given).
        case closedUnresolved
    }

    public let date: Date
    public let how: How

    public init(date: Date, how: How) {
        self.date = date
        self.how = how
    }
}

// MARK: - State

/// Everything SPEC 3.5 rule 7 remembers beyond `PainStop` (stored in
/// `AdaptationState.painRecovery`): stable check-ins for usual pain, the
/// frozen usual level, the stop's end path, the return and the clinician flag.
public struct PainRecovery: Equatable, Sendable, Codable {
    /// The latest stable post-run check-ins (at most `usualWindow` are kept).
    public var usualSamples: [UsualPainSample]
    /// Usual pain frozen at its pre-stop value while a stop, the return or
    /// the clinician flag is active; nil otherwise.
    public var frozenUsual: Int?
    /// Morning reports after this count toward ending the stop: the stop's
    /// start, or the latest failed test run.
    public var countFrom: Date?
    /// The test run offered or run, while one stands.
    public var test: PainTestRun?
    /// The stop began with usual at or above `cannotEndUsual`: it can't end
    /// by the test run (#85 is the open question on a way out).
    public var cannotEnd: Bool
    /// The stop came from a movement change (the test run then allows no pain above usual).
    public var stopFromMovement: Bool
    /// The pre-stop long run, in the guardrail measure, kept for the return's week-1 cap.
    public var preStopLongRun: Double?
    /// The plan's weekly run volumes from the stop's week on, as handed in
    /// when the stop began (`PainReturn.planWeeks`); empty for a stop stored
    /// before rule 7's state existed.
    public var prePlanWeeks: [PlanWeekVolume]
    /// The flag was raised during the stop that stands, so staying stopped
    /// doesn't raise it again after a 14-day close.
    public var flaggedThisStop: Bool
    /// The return after a stop, while it lasts.
    public var painReturn: PainReturn?
    /// The clinician flag, while it is on.
    public var flag: ClinicianFlag?
    /// How the latest flag stretch ended.
    public var flagEnded: ClinicianFlagEnd?
    /// The week whose test-run offer and drop the last event posted, so the
    /// same pair is not posted again on every event while that week can't
    /// hold the test run (#144, like `AdaptationState.reportedHoldShortfalls`).
    /// Only the records are skipped: the plan is the same either way. Cleared
    /// by an event that drops no test run.
    public var reportedTestRunDropWeek: Date?

    public init(usualSamples: [UsualPainSample] = [], frozenUsual: Int? = nil, countFrom: Date? = nil,
                test: PainTestRun? = nil, cannotEnd: Bool = false, stopFromMovement: Bool = false,
                preStopLongRun: Double? = nil, prePlanWeeks: [PlanWeekVolume] = [], flaggedThisStop: Bool = false,
                painReturn: PainReturn? = nil,
                flag: ClinicianFlag? = nil, flagEnded: ClinicianFlagEnd? = nil,
                reportedTestRunDropWeek: Date? = nil) {
        self.usualSamples = usualSamples
        self.frozenUsual = frozenUsual
        self.countFrom = countFrom
        self.test = test
        self.cannotEnd = cannotEnd
        self.stopFromMovement = stopFromMovement
        self.preStopLongRun = preStopLongRun
        self.prePlanWeeks = prePlanWeeks
        self.flaggedThisStop = flaggedThisStop
        self.painReturn = painReturn
        self.flag = flag
        self.flagEnded = flagEnded
        self.reportedTestRunDropWeek = reportedTestRunDropWeek
    }

    enum CodingKeys: String, CodingKey {
        case usualSamples, frozenUsual, countFrom, test, cannotEnd, stopFromMovement, preStopLongRun, prePlanWeeks,
             flaggedThisStop, painReturn, flag, flagEnded, reportedTestRunDropWeek
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(usualSamples: try c.decodeIfPresent([UsualPainSample].self, forKey: .usualSamples) ?? [],
                  frozenUsual: try c.decodeIfPresent(Int.self, forKey: .frozenUsual),
                  countFrom: try c.decodeIfPresent(Date.self, forKey: .countFrom),
                  test: try c.decodeIfPresent(PainTestRun.self, forKey: .test),
                  cannotEnd: try c.decodeIfPresent(Bool.self, forKey: .cannotEnd) ?? false,
                  stopFromMovement: try c.decodeIfPresent(Bool.self, forKey: .stopFromMovement) ?? false,
                  preStopLongRun: try c.decodeIfPresent(Double.self, forKey: .preStopLongRun),
                  prePlanWeeks: try c.decodeIfPresent([PlanWeekVolume].self, forKey: .prePlanWeeks) ?? [],
                  flaggedThisStop: try c.decodeIfPresent(Bool.self, forKey: .flaggedThisStop) ?? false,
                  painReturn: try c.decodeIfPresent(PainReturn.self, forKey: .painReturn),
                  flag: try c.decodeIfPresent(ClinicianFlag.self, forKey: .flag),
                  flagEnded: try c.decodeIfPresent(ClinicianFlagEnd.self, forKey: .flagEnded),
                  reportedTestRunDropWeek: try c.decodeIfPresent(Date.self, forKey: .reportedTestRunDropWeek))
    }
}

/// Where SPEC 3.5 rule 7 stands after an event, for the app (`AdaptationOutcome.painCourse`).
public struct PainCourseStatus: Equatable, Sendable {
    /// The usual pain level in use (frozen while a stop, return or flag is active).
    public let usual: Int
    /// A pain stop stands.
    public let stopped: Bool
    /// The stop can't end by the test run (usual was 4 or more when it began; #85).
    public let stopCannotEnd: Bool
    /// The test run offered or awaiting its next-morning report, as planned.
    public let testRun: PlannedWorkout?
    /// The return step in force this week, during the return.
    public let returnStep: Int?
    /// The clinician flag while it is on. The app advises seeing a clinician
    /// in its own words; CoachCore never diagnoses.
    public let clinicianFlag: ClinicianFlag?
    /// The flag has had no report for 7 days: ask once for one (set on one event only).
    public let askForReport: Bool
    /// This event closed the flag's stretch as unresolved after 14 days with
    /// no report (advice given). The stop and the return rules stay in force.
    public let flagClosedUnresolved: Bool
    /// During a stop and the return, ask each morning for pain in that spot
    /// and for pain on daily walking.
    public let askMorningQuestions: Bool
    /// This event ended a stop. After a rest-mode stop the plan holds only
    /// rest days, so the app hands the kept plan back on the next event; the
    /// return guards then shape it.
    public let returnStarted: Bool

    public static let none = PainCourseStatus(usual: 0, stopped: false, stopCannotEnd: false, testRun: nil,
                                              returnStep: nil, clinicianFlag: nil, askForReport: false,
                                              flagClosedUnresolved: false, askMorningQuestions: false,
                                              returnStarted: false)
}
