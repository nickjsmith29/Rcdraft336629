import Foundation

/// Limits for the load guardrails (SPEC.md 3.5, F9). Every value is a
/// **heuristic** from 3.5, not a validated injury threshold; the evidence
/// for load-ratio rules is weak (3.5), so they are kept configurable.
/// A limit that isn't a finite number, or is below 0, is stored as its
/// default instead; `.infinity` is kept only for `maxSingleRunIncrease`,
/// where it switches the spike rule off (see `valid`, #142). So is a
/// whole-number limit above its input-sanity bound (`upperBound`, #147).
///
/// **Behaviour change (#142).** `.infinity` on `maxWeeklyIncrease`,
/// `maxFourWeekIncrease`, `maxLongRunShare` or `recoveryWeekMaxRatio` used to
/// switch that rule off without warning; it now falls back to the default,
/// so the rule stays on. Only `maxSingleRunIncrease` can be switched off
/// with `.infinity`.
public struct GuardrailLimits: Equatable, Sendable {
    /// How weekly volume is measured. Default `.time` (3.5 allows time or distance).
    public var measure: VolumeMeasure
    /// Largest week-over-week rise, as a fraction. Default 0.10 ("about 10%").
    public var maxWeeklyIncrease: Double { didSet { maxWeeklyIncrease = Self.valid(maxWeeklyIncrease, \.maxWeeklyIncrease) } }
    /// Largest rise of a rolling 4-week total over the 4 weeks before it,
    /// as a fraction. Default 0.30 ("no more than 30% over any rolling 4 weeks").
    public var maxFourWeekIncrease: Double { didSet { maxFourWeekIncrease = Self.valid(maxFourWeekIncrease, \.maxFourWeekIncrease) } }
    /// Largest share of a week's **time** one long run may take. Default 0.35:
    /// 3.5 rule 5 says "about 30 to 35% of weekly time"; 35% is the hard limit
    /// here and 30% is what the plan builder (F3) should aim for. Always read
    /// in time, whatever `measure` is (see `GuardrailChecker`). In a marathon
    /// plan it is the warning line instead (`marathonMaxLongRunShare`).
    public var maxLongRunShare: Double { didSet { maxLongRunShare = Self.valid(maxLongRunShare, \.maxLongRunShare) } }
    /// The long-run share's hard ceiling in a marathon plan (3.5 rule 5):
    /// weeks up to and including the week of a race of marathon distance.
    /// Default 0.45. Above `maxLongRunShare` and up to this, the share is an
    /// information flag (a warning, never a block). Heuristic: coaching
    /// sources disagree (25 to 30% [11][13], novice plans 45 to 50%) and no
    /// study tests a share threshold. Read as at least `maxLongRunShare`.
    public var marathonMaxLongRunShare: Double { didSet { marathonMaxLongRunShare = Self.valid(marathonMaxLongRunShare, \.marathonMaxLongRunShare) } }
    /// A week counts as a recovery week when its volume is at most this
    /// fraction of the week before it (or it has no volume at all). Default 0.80.
    public var recoveryWeekMaxRatio: Double { didSet { recoveryWeekMaxRatio = Self.valid(recoveryWeekMaxRatio, \.recoveryWeekMaxRatio) } }
    /// Most non-recovery weeks allowed in a row. Default 3, so a recovery
    /// week comes every third or fourth week (3.5).
    public var maxConsecutiveBuildWeeks: Int { didSet { maxConsecutiveBuildWeeks = Self.valid(maxConsecutiveBuildWeeks, \.maxConsecutiveBuildWeeks) } }
    /// Most quality sessions in one week. Default 2 (3.5).
    public var maxQualitySessionsPerWeek: Int { didSet { maxQualitySessionsPerWeek = Self.valid(maxQualitySessionsPerWeek, \.maxQualitySessionsPerWeek) } }
    /// Whether a race counts toward `maxQualitySessionsPerWeek`. Default true:
    /// a race is at least as hard as a quality session.
    public var racesCountAsQuality: Bool
    /// Most one planned run may be longer than the longest run of the
    /// previous `spikeWindowDays`, as a fraction (single-run spike rule, 3.5
    /// rule 1). Default 0.10. A heuristic from Garmin-RUNSAFE [1]: SPEC 3.5
    /// sets 5 to 10% as the target. `.infinity` switches the rule off.
    public var maxSingleRunIncrease: Double { didSet { maxSingleRunIncrease = Self.valid(maxSingleRunIncrease, \.maxSingleRunIncrease) } }
    /// Days back the spike rule looks for the longest run. Default 30 [1].
    public var spikeWindowDays: Int { didSet { spikeWindowDays = Self.valid(spikeWindowDays, \.spikeWindowDays) } }
    /// Whether a race counts as the longest run for the spike checks of the
    /// runs after it. Default false (heuristic, the conservative reading of
    /// 3.5 rules 1 and 3): a race is usually longer than any training run, so
    /// counting it would let the next long runs jump.
    public var racesSetSpikeReference: Bool
    /// A week is a break week (3.5 rule 4, read in weeks) when its volume
    /// outside races is at most this fraction of the pre-break weekly volume
    /// ("little or no running"). Default 0.25. Heuristic: SPEC 3.5 counts a
    /// break in days with no running, and a week with at most a quarter of
    /// the usual running is one that held most of a week off.
    public var breakWeekMaxRatio: Double { didSet { breakWeekMaxRatio = Self.valid(breakWeekMaxRatio, \.breakWeekMaxRatio) } }
    /// Weeks before a break whose mean is the pre-break weekly volume. Default
    /// 4, the window of the baseline's recent weekly volume (F1). Heuristic.
    public var preBreakWeeks: Int { didSet { preBreakWeeks = Self.valid(preBreakWeeks, \.preBreakWeeks) } }
    /// Most break weeks in a row that are a short break (one or two weeks
    /// off, 3.5 rule 4), after which the return ramp applies and the rolling
    /// 4-week check counts the break weeks at the pre-break level. Default 2;
    /// a longer break keeps the plain rules. 0 switches the ramp off. Heuristic.
    public var maxShortBreakWeeks: Int { didSet { maxShortBreakWeeks = Self.valid(maxShortBreakWeeks, \.maxShortBreakWeeks) } }
    /// The return ramp after a short break (3.5 rule 4): week `k` back may
    /// hold at most `breakReturnSteps[k-1]` × the pre-break weekly volume,
    /// and from week 2 on at most the ramp's own rise over the week before.
    /// Default [0.70, 0.90, 1.00]: the upper ends of rule 4's steps (about 60
    /// to 70%, then 80 to 90%, then full volume). Heuristic: no study tests a
    /// return ramp [6][9][10]. Empty switches the ramp off.
    public var breakReturnSteps: [Double] { didSet { breakReturnSteps = Self.valid(breakReturnSteps, \.breakReturnSteps) } }
    /// Most quality sessions in week `k` of the return ramp after a short
    /// break (3.5 rule 4): `breakReturnMaxQualitySessions[k-1]`, never above
    /// `maxQualitySessionsPerWeek`; races count as `racesCountAsQuality`
    /// says. Default [0, 1]: rule 4's "no hard sessions" in week 1 and "one
    /// quality session" in week 2 (the owner's amendment on #62). Weeks past
    /// the list keep the plain limit; empty switches the limit off. The long
    /// run's steady finish is part of the long run, not a quality session.
    public var breakReturnMaxQualitySessions: [Int] { didSet { breakReturnMaxQualitySessions = Self.valid(breakReturnMaxQualitySessions, \.breakReturnMaxQualitySessions) } }
    /// Most a regrowth week may rise over the week before it as run, as a
    /// fraction (3.5 rule 6, owner decision Nov 21, #107; `GuardrailRegrowth`).
    /// Default `PlanHeuristics.regrowthMaxWeeklyRise` (0.20). Heuristic.
    public var regrowthMaxWeeklyRise: Double { didSet { regrowthMaxWeeklyRise = Self.valid(regrowthMaxWeeklyRise, \.regrowthMaxWeeklyRise) } }
    /// The return steps of a regrowth, as shares of the original plan's week
    /// (3.5 rule 6, owner decision Nov 21, #107; `GuardrailRegrowth`): a
    /// regrowth week may hold the higher of its step and
    /// `regrowthMaxWeeklyRise` over the week before. Default
    /// `PlanHeuristics.regrowthReturnSteps` (0.65, 0.825, 1.0). Heuristic.
    public var regrowthReturnSteps: [Double] { didSet { regrowthReturnSteps = Self.valid(regrowthReturnSteps, \.regrowthReturnSteps) } }

    public init(measure: VolumeMeasure = .time,
                maxWeeklyIncrease: Double = 0.10,
                maxFourWeekIncrease: Double = 0.30,
                maxLongRunShare: Double = 0.35,
                recoveryWeekMaxRatio: Double = 0.80,
                maxConsecutiveBuildWeeks: Int = 3,
                maxQualitySessionsPerWeek: Int = 2,
                racesCountAsQuality: Bool = true,
                maxSingleRunIncrease: Double = 0.10,
                spikeWindowDays: Int = 30,
                racesSetSpikeReference: Bool = false,
                marathonMaxLongRunShare: Double = 0.45,
                breakWeekMaxRatio: Double = 0.25,
                preBreakWeeks: Int = 4,
                maxShortBreakWeeks: Int = 2,
                breakReturnSteps: [Double] = [0.70, 0.90, 1.00],
                breakReturnMaxQualitySessions: [Int] = [0, 1],
                regrowthMaxWeeklyRise: Double = PlanHeuristics.regrowthMaxWeeklyRise,
                regrowthReturnSteps: [Double] = PlanHeuristics.regrowthReturnSteps) {
        self.measure = measure
        self.maxWeeklyIncrease = Self.valid(maxWeeklyIncrease, \.maxWeeklyIncrease)
        self.maxFourWeekIncrease = Self.valid(maxFourWeekIncrease, \.maxFourWeekIncrease)
        self.maxLongRunShare = Self.valid(maxLongRunShare, \.maxLongRunShare)
        self.recoveryWeekMaxRatio = Self.valid(recoveryWeekMaxRatio, \.recoveryWeekMaxRatio)
        self.maxConsecutiveBuildWeeks = Self.valid(maxConsecutiveBuildWeeks, \.maxConsecutiveBuildWeeks)
        self.maxQualitySessionsPerWeek = Self.valid(maxQualitySessionsPerWeek, \.maxQualitySessionsPerWeek)
        self.racesCountAsQuality = racesCountAsQuality
        self.maxSingleRunIncrease = Self.valid(maxSingleRunIncrease, \.maxSingleRunIncrease)
        self.spikeWindowDays = Self.valid(spikeWindowDays, \.spikeWindowDays)
        self.racesSetSpikeReference = racesSetSpikeReference
        self.marathonMaxLongRunShare = Self.valid(marathonMaxLongRunShare, \.marathonMaxLongRunShare)
        self.breakWeekMaxRatio = Self.valid(breakWeekMaxRatio, \.breakWeekMaxRatio)
        self.preBreakWeeks = Self.valid(preBreakWeeks, \.preBreakWeeks)
        self.maxShortBreakWeeks = Self.valid(maxShortBreakWeeks, \.maxShortBreakWeeks)
        self.breakReturnSteps = Self.valid(breakReturnSteps, \.breakReturnSteps)
        self.breakReturnMaxQualitySessions = Self.valid(breakReturnMaxQualitySessions, \.breakReturnMaxQualitySessions)
        self.regrowthMaxWeeklyRise = Self.valid(regrowthMaxWeeklyRise, \.regrowthMaxWeeklyRise)
        self.regrowthReturnSteps = Self.valid(regrowthReturnSteps, \.regrowthReturnSteps)
    }

    /// Most quality sessions allowed in week `step` of the return ramp (3.5
    /// rule 4), or nil when the ramp sets no limit of its own for that week.
    func returnRampMaxQuality(step: Int) -> Int? {
        guard step >= 1, step <= breakReturnMaxQualitySessions.count else { return nil }
        return max(0, min(breakReturnMaxQualitySessions[step - 1], maxQualitySessionsPerWeek))
    }

    /// The long-run share ceiling in a week of a marathon plan (3.5 rule 5):
    /// `marathonMaxLongRunShare`, never below `maxLongRunShare`.
    var marathonLongRunCeiling: Double { max(maxLongRunShare, marathonMaxLongRunShare) }

    public static let `default` = GuardrailLimits()

    /// `value` for the limit at `field`, as it is stored (#142, the same
    /// pattern as `AdaptationLimits.valid`, #133): a value that is NaN, below
    /// 0 or -inf falls back to that limit's default, so a bad tunable can't
    /// change the adaptation engine's outcomes (a weekly rise or long-run
    /// share of -1 used as given gave different outcomes from the default's
    /// through a pain stop's return; the stall once seen there was the test
    /// driver's `follow` loop, fixed in #148) or turn a rule inside out.
    /// +inf also falls back, except for `maxSingleRunIncrease`,
    /// where `.infinity` is the documented way to switch the spike rule off.
    /// Every `Double` and `Int` limit and every list goes through this, when
    /// the limits are built and whenever one is set. Finite values at or
    /// above 0 are kept as they are, so 0 keeps its meaning where it has one
    /// (`maxShortBreakWeeks` 0 switches the return ramp off, a 0 quality
    /// limit allows none). The fallback reads `default` only for a bad
    /// value, and every default is valid, so building `default` never reads
    /// itself.
    static func valid(_ value: Double, _ field: KeyPath<GuardrailLimits, Double>) -> Double {
        if value == .infinity && field == \.maxSingleRunIncrease { return value }
        guard value.isFinite, value >= 0 else { return Self.default[keyPath: field] }
        return value
    }

    /// An `Int` limit below 0 falls back to its default (#142), and so does
    /// one above its `upperBound` (#147).
    static func valid(_ value: Int, _ field: KeyPath<GuardrailLimits, Int>) -> Int {
        value >= 0 && value <= (upperBound(field) ?? .max) ? value : Self.default[keyPath: field]
    }

    /// The input-sanity upper bound of a whole-number limit used in date or
    /// week arithmetic (#147, `LimitBounds`; not a training rule):
    /// `spikeWindowDays` 730 days, `preBreakWeeks` and
    /// `maxShortBreakWeeks` 104 weeks. `Int.max` in any of the three
    /// overflowed the checker or the engine, or ran a loop of that many
    /// weeks. Nil for a count that is only compared
    /// (`maxConsecutiveBuildWeeks`, `maxQualitySessionsPerWeek`).
    static func upperBound(_ field: KeyPath<GuardrailLimits, Int>) -> Int? {
        switch field {
        case \GuardrailLimits.spikeWindowDays: return LimitBounds.days
        case \GuardrailLimits.preBreakWeeks, \GuardrailLimits.maxShortBreakWeeks: return LimitBounds.weeks
        default: return nil
        }
    }

    /// A list of shares (`breakReturnSteps`, `regrowthReturnSteps`) with a
    /// step that isn't a finite number of 0 or more falls back, as a whole,
    /// to its default list (#142). An empty list is kept: it switches that
    /// ramp off, as documented.
    static func valid(_ value: [Double], _ field: KeyPath<GuardrailLimits, [Double]>) -> [Double] {
        value.allSatisfy { $0.isFinite && $0 >= 0 } ? value : Self.default[keyPath: field]
    }

    /// A list of counts (`breakReturnMaxQualitySessions`) with an entry below
    /// 0 falls back, as a whole, to its default list (#142). An empty list
    /// is kept: it switches that limit off, as documented.
    static func valid(_ value: [Int], _ field: KeyPath<GuardrailLimits, [Int]>) -> [Int] {
        value.allSatisfy { $0 >= 0 } ? value : Self.default[keyPath: field]
    }
}

/// The guardrail rules (SPEC.md 3.5, F9).
public enum GuardrailRule: String, CaseIterable, Equatable, Hashable, Sendable {
    /// One planned run at most `maxSingleRunIncrease` longer than the longest
    /// run of the previous `spikeWindowDays` (3.5 rule 1, the primary check).
    /// Reported per run (`GuardrailViolation.workoutID`); a race is only a flag.
    case singleRunSpike
    /// Weekly volume outside races up at most `maxWeeklyIncrease` over the
    /// reference week, or within the return ramp after a short break (3.5
    /// rules 2 to 4).
    case weeklyIncrease
    /// Rolling 4-week total outside races up at most `maxFourWeekIncrease`
    /// over the 4 weeks before (3.5 rules 2 to 4).
    case fourWeekIncrease
    /// Longest long run at most `maxLongRunShare` of the week's time, or
    /// `marathonMaxLongRunShare` in a marathon plan, where a share above
    /// `maxLongRunShare` is an information flag (3.5 rule 5).
    case longRunShare
    /// No more than `maxConsecutiveBuildWeeks` non-recovery weeks in a row.
    case recoveryWeek
    /// At most `maxQualitySessionsPerWeek` quality sessions a week, and in
    /// weeks 1 and 2 of the return ramp after a short break at most
    /// `breakReturnMaxQualitySessions` (3.5 rule 4).
    case qualitySessions
    /// No volume growth in a week that overlaps a freeze (pain check-in, 3.5).
    case volumeFreeze
}

/// One broken guardrail, explained in plain English.
public struct GuardrailViolation: Equatable, Sendable {
    /// What `measured` and `allowed` are in.
    public enum Unit: String, Equatable, Sendable {
        /// Weekly volume in seconds (`VolumeMeasure.time`).
        case seconds
        /// Weekly volume in meters (`VolumeMeasure.distance`).
        case meters
        /// A ratio, e.g. 0.38 for 38% of the week.
        case fraction
        case sessions
        case weeks
    }

    public let rule: GuardrailRule
    /// Monday 00:00 of the week that breaks the rule.
    public let weekStart: Date
    public let measured: Double
    public let allowed: Double
    public let unit: Unit
    public let explanation: String
    /// Set on a weekly-rise or freeze violation whose reference is 0 and rests
    /// on a week of unknown volume with nothing of known time (#40), which
    /// allows nothing. No cut fixes it: the week needs a reference of known volume.
    /// A plan can be built on this date, the Monday after this week, once the
    /// week has been run, as with `PlanBuildIssue.historyVolumeUnknown(rebuildOn:)`.
    /// Nil otherwise.
    public let rebuildOn: Date?
    /// The session that breaks the rule, for a rule about one session (the
    /// single-run spike rule, 3.5 rule 1). Nil for a rule about a whole week.
    public let workoutID: String?

    public init(rule: GuardrailRule, weekStart: Date, measured: Double, allowed: Double, unit: Unit, explanation: String,
                rebuildOn: Date? = nil, workoutID: String? = nil) {
        self.rule = rule
        self.weekStart = weekStart
        self.measured = measured
        self.allowed = allowed
        self.unit = unit
        self.explanation = explanation
        self.rebuildOn = rebuildOn
        self.workoutID = workoutID
    }
}

/// An information-only finding (F9): shown with its reason, never a block and
/// never a reason to cut. Same shape as a violation: the single-run spike
/// rule on a race (3.5 rules 1 and 3), and a marathon plan's long run above
/// the usual share (3.5 rule 5, `workoutID` the long run).
public typealias GuardrailFlag = GuardrailViolation

/// A rule that could not be checked for a week, and why. The checker never
/// guesses: missing data is reported here instead of passing or failing.
public struct GuardrailSkip: Equatable, Sendable {
    public let rule: GuardrailRule
    public let weekStart: Date
    public let reason: String
    /// The session that could not be checked, for a rule about one session
    /// (the single-run spike rule). Nil for a rule about a whole week.
    public let workoutID: String?

    public init(rule: GuardrailRule, weekStart: Date, reason: String, workoutID: String? = nil) {
        self.rule = rule
        self.weekStart = weekStart
        self.reason = reason
        self.workoutID = workoutID
    }
}

public struct GuardrailReport: Equatable, Sendable {
    public let violations: [GuardrailViolation]
    public let notEvaluated: [GuardrailSkip]
    /// Information-only findings (F9), such as a race longer than the 30-day
    /// longest run (3.5 rules 1 and 3) or a marathon long run above the usual
    /// share (3.5 rule 5). Shown with their reason; they never fail the report.
    public let informationFlags: [GuardrailFlag]
    /// True when no rule was broken. Check `notEvaluated` too: a rule that
    /// could not run is not a pass. `informationFlags` don't count.
    public var passed: Bool { violations.isEmpty }

    public init(violations: [GuardrailViolation], notEvaluated: [GuardrailSkip], informationFlags: [GuardrailFlag] = []) {
        self.violations = violations
        self.notEvaluated = notEvaluated
        self.informationFlags = informationFlags
    }
}

/// Checks a plan against the load guardrails (SPEC.md 3.5, F9). It is meant to
/// run over every plan and every plan change (F2 re-plans, F3, F4).
///
/// Input is one timeline: `history` (sessions already done, any kind) and
/// `planned` (sessions to come). Sessions are grouped into Monday-start weeks
/// (`PlanCalendar`) with empty weeks filled in, and only the weeks from the
/// first planned session's week to the last one's are checked; a week that
/// mixes done and planned sessions (a mid-week re-plan) is checked as a whole.
///
/// How each heuristic is read (all limits in `GuardrailLimits`):
/// - **Single-run spike** (3.5 rule 1, the primary check): each planned run
///   at most `maxSingleRunIncrease` longer than the longest run of the
///   `spikeWindowDays` before it, history and earlier planned runs alike.
///   See `checkSingleRunSpikes` (SingleRunSpike.swift) for the window, races
///   (a flag, never a violation) and unknown times.
/// - **Recovery week:** volume ≤ `recoveryWeekMaxRatio` × the week before, or
///   zero volume. The first week of the timeline has no week before it, so it
///   counts as a build week unless it is empty.
/// - **Races** (3.5 rule 3, #62): the weekly caps (week over week, rolling 4
///   weeks and the return ramp) measure each week's volume **outside races**,
///   in the week of a race and as the reference of the weeks after it, so a
///   race neither needs room under a cap nor raises a later one. Everything
///   else in race week still counts. The recovery cadence, the long-run share
///   and the freeze still count the race (unchanged, the conservative reading).
/// - **Breaks** (3.5 rules 2 and 4, read in weeks, #62): a break week holds at
///   most `breakWeekMaxRatio` of the pre-break weekly volume (the mean of the
///   `preBreakWeeks` weeks before the break) outside races, with no race and a
///   known volume (`breaks`). A break of at most `maxShortBreakWeeks` weeks is
///   short: the `breakReturnSteps.count` weeks after it are the return ramp
///   (`returnRamp`), whose caps replace the 10% check, and in the rolling
///   check its weeks count at the pre-break level among the earlier 4 weeks
///   (`rollingPriorVolume`), so the window holding the break doesn't refuse a
///   return to the pre-break level. A longer break keeps the plain rules.
/// - **Regrowth** (3.5 rules 2 and 6, owner decision Nov 21, #107): in the
///   weeks of `regrowth`, which the adaptation engine hands in, the 10% check
///   is replaced by the regrowth's bound (`GuardrailRegrowth.Week.allowed(previous:)`:
///   the higher of `regrowthMaxWeeklyRise` above the week before and the
///   week's return step in `regrowthReturnSteps`, never above the original
///   plan), or the lower of the ramp cap and that bound in a
///   return-ramp week; in the rolling check a cut week counts at its
///   original-plan volume among the earlier 4 (`GuardrailRegrowth`).
/// - **Week over week:** volume ≤ (1 + `maxWeeklyIncrease`) × reference. The
///   reference is the week before, except when that week was a recovery week:
///   then it is the week before the recovery week, because returning to the
///   pre-recovery level is not growth. Only one step back is taken, so after
///   two or more down weeks (a break, a taper) the lower level is the reference.
///   A week of unknown volume holds at least its known sessions (`L`); after
///   one, the reference is the least it can have been as a build week,
///   `max(L, recoveryWeekMaxRatio × the week before it)`, so the week after
///   is still checked and the check holds for every true volume
///   (`reference(before:)`).
///   A reference of 0 that rests on an unknown week with no session of known
///   time allows nothing (a violation with `allowed` 0), since the week may
///   truly have been almost nothing; a known zero week is reported as not
///   evaluated.
/// - **Rolling 4 weeks:** the total of the 4 weeks ending this week ≤
///   (1 + `maxFourWeekIncrease`) × the total of the 4 weeks before them. Totals
///   are used rather than one week against the week 4 earlier, because a single
///   recovery week as the starting point would otherwise flag a normal return
///   to load. Needs 8 weeks of timeline; with fewer it is reported as not evaluated.
///   A week of unknown volume counts at its known lower bound: in the earlier
///   4 weeks that is safe (it only lowers the allowance); in the recent 4 a
///   total over the limit even at the bound is a violation, and otherwise the
///   check is reported as not evaluated, since the true total may be higher.
/// - **Long run:** the longest `.long` session ≤ `maxLongRunShare` × the
///   week's **time**; in a marathon plan (`marathonWeeks`) ≤
///   `marathonMaxLongRunShare`, with a share above `maxLongRunShare` reported
///   as an information flag. SPEC 3.5 rule 5 states the share as a share of weekly
///   time, so it is read in time whatever `measure` is: with `measure`
///   `.time` the week's volume is its moving time (history converts in as
///   moving time, `PlannedWorkout.init?(activity:kind:)`), so the two agree;
///   with `.distance` the share is still of time, not of distance.
/// - **Recovery cadence:** at most `maxConsecutiveBuildWeeks` non-recovery weeks
///   in a row, counting history weeks. A week of unknown volume may have been
///   a build week, so it counts as one; the week after it is a recovery week
///   when it is at most `recoveryWeekMaxRatio` × the unknown week's known lower bound
///   (it is then one whatever the unknown week truly held).
/// - **Quality:** at most `maxQualitySessionsPerWeek` `.quality` sessions
///   (plus races when `racesCountAsQuality`); in week `k` of the return ramp
///   after a short break, at most `breakReturnMaxQualitySessions[k-1]` (3.5
///   rule 4), read with the ramp's own certainty rules.
/// - **Freeze:** in a week overlapping one of `freezes` (from a pain check-in),
///   volume ≤ the previous week's actual volume (no growth, and no step back
///   past a recovery week). Not evaluated when the previous week is known and
///   empty. When it is unknown the freeze holds to its known part `L` (#40);
///   with `L` 0 it allows nothing (a violation with `allowed` 0 and `rebuildOn`).
/// Exactly hitting a limit passes (a tiny tolerance absorbs floating-point error).
///
/// Weeks of unknown volume (#40): every rule above holds for every volume such
/// a week may truly have held (at least its sessions of known value) where
/// it is the week checked against. There are three exceptions, all where the
/// true total has no upper bound:
/// 1. the rolling 4-week rule for a week whose recent 4 include an unknown
///    week;
/// 2. the 10% rise and the freeze for a week that is itself unknown (say, a
///    broken run already done with sessions still to come);
/// 3. the long-run share for a week that is itself unknown (in time).
/// The first two are read at the known part: a violation there is sure and
/// is reported, and otherwise the check is reported in `notEvaluated`. The
/// long-run share is always reported in `notEvaluated` for such a week, since
/// a share read at the known part is only the worst case and repair would cut
/// the long run on it; the 10%, rolling and freeze rules still bound that week.
/// The single-run spike rule reads unknown runs the same lower-bound way: an
/// unknown run never counts as the longest run, so the reference is the
/// longest known one, which the true longest is at least; with no run of known
/// time in the window it is not evaluated (no reference is invented).
public enum GuardrailChecker {
    static let tolerance = 1e-9

    /// Where a week-over-week reference comes from.
    enum ReferenceSource: Equatable {
        /// The week before, at its known volume.
        case weekBefore
        /// The week before was a recovery week: the week before that (at its
        /// known volume, or the lower bound of its volume when unknown).
        case beforeRecovery
        /// The week before has unknown volume: the smallest reference it can
        /// give under every volume it may truly have (`reference(before:)`).
        case unknownWeekBound
    }

    /// The 10% reference for week `i` (see the type's doc), the smallest it
    /// can be under every true volume of the weeks with unknown volume.
    ///
    /// A week of unknown volume (a session with no valid duration or
    /// distance) is known to hold at least `low`, the total of its sessions
    /// with a valid value (`PlanWeek.knownVolume`), the way #53's open start
    /// week is known to hold what was run so far. When the week before `i` is
    /// unknown with lower bound `L`, and the week before it holds (at least)
    /// `P`: if it was truly a build week its own volume is the reference, at
    /// least `max(L, recoveryRatio × P)` (just over the recovery line); if it
    /// was truly a recovery week the reference is the week before it, at least
    /// `P`, which is larger. So `max(L, recoveryRatio × P)` is safe for every
    /// true volume (#40). A known week whose week before is unknown is a
    /// recovery week only when it is one for every true volume (`isRecovery`
    /// reads it that way), so the reference never steps back past a recovery
    /// week that might not be one. Shared with the plan builder's ledger. Nil
    /// for the first week.
    static func reference(before i: Int, volumes: [Double?], lows: [Double], recoveryRatio: Double,
                          isRecovery: (Int) -> Bool) -> (value: Double, index: Int, source: ReferenceSource)? {
        guard i >= 1, i - 1 < volumes.count else { return nil }
        func low(_ k: Int) -> Double { volumes[k] ?? (k < lows.count ? max(0, lows[k]) : 0) }
        let j = i - 1
        if let v = volumes[j] {
            if isRecovery(j), j >= 1 { return (low(j - 1), j - 1, .beforeRecovery) }
            return (v, j, .weekBefore)
        }
        let before = j >= 1 ? low(j - 1) : 0
        return (max(low(j), recoveryRatio * before), j, .unknownWeekBound)
    }

    /// Unplanned runs count in a checked week's volume and in the references
    /// the weekly rules compare against, but are never checked themselves as
    /// spikes, except a done race, which is flagged for information and never
    /// as a violation. Every session in `history` is volume the runner actually did,
    /// whether or not the plan had it (a run on a planned rest day, an extra
    /// run), so it adds to the week it falls in like any planned session. Only
    /// weeks from the plan's first to its last are checked, so an unplanned run
    /// in an earlier week only adds to the volume the next week is compared
    /// with. The single-run spike rule checks planned runs and done races, and
    /// uses history only to set the longest-run reference. Exempting unplanned
    /// runs from the weekly rules would be a guardrail rule change and the
    /// owner's call (#149).
    ///
    /// `units` sets only how distances read in the explanations (km or mi,
    /// `UnitPreference`); every limit and decision is the same in both.
    public static func check(history: [PlannedWorkout],
                             planned: [PlannedWorkout],
                             timeZone: TimeZone,
                             limits: GuardrailLimits = .default,
                             freezes: [DateInterval] = [],
                             units: UnitPreference = .metric,
                             regrowth: GuardrailRegrowth = .none) -> GuardrailReport {
        guard let planFirst = planned.map(\.date).min(), let planLast = planned.map(\.date).max() else {
            return GuardrailReport(violations: [], notEvaluated: [])
        }
        let all = history + planned
        let first = all.map(\.date).min() ?? planFirst
        let last = all.map(\.date).max() ?? planLast
        let weeks = PlanWeek.weeks(from: all, firstWeekContaining: first, lastWeekContaining: last, timeZone: timeZone)
        let firstChecked = PlanCalendar.weekStart(containing: planFirst, timeZone: timeZone)
        let lastChecked = PlanCalendar.weekStart(containing: planLast, timeZone: timeZone)
        let checked = weeks.indices.filter { weeks[$0].weekStart >= firstChecked && weeks[$0].weekStart <= lastChecked }

        var ctx = Context(weeks: weeks, limits: limits, timeZone: timeZone, units: units, regrowth: regrowth)
        for i in checked {
            ctx.checkWeeklyIncrease(i)
            ctx.checkFourWeekIncrease(i)
            ctx.checkLongRunShare(i)
            ctx.checkQualitySessions(i)
            if freezes.contains(where: { $0.start < weeks[i].weekEnd && $0.end > weeks[i].weekStart }) {
                ctx.checkFreeze(i)
            }
        }
        ctx.checkRecoveryCadence(checked: Set(checked))
        let checkedEnd = PlanCalendar.nextWeekStart(after: lastChecked, timeZone: timeZone)
        let spikes = checkSingleRunSpikes(history: history, planned: planned, checked: firstChecked..<checkedEnd,
                                          timeZone: timeZone, limits: limits, units: units)
        return GuardrailReport(violations: spikes.violations + ctx.violations, notEvaluated: spikes.skips + ctx.skips,
                               informationFlags: spikes.flags + ctx.flags)
    }

    private struct Context {
        let weeks: [PlanWeek]
        let limits: GuardrailLimits
        let timeZone: TimeZone
        let units: UnitPreference
        let volumes: [Double?]
        /// Known part of each week's volume: equal to `volumes` where known, a
        /// lower bound of the true volume where `volumes` is nil (#40).
        let lows: [Double]
        /// Each week's volume outside races and its known part (3.5 rule 3):
        /// what the weekly caps measure. Equal to `volumes` in a week with no race.
        let outside: [Double?]
        let outsideLows: [Double]
        let raceWeeks: Set<Int>
        /// Breaks in `outside` (3.5 rule 4, read in weeks).
        let breaks: [LoadBreak]
        /// Weeks where the marathon long-run share applies (3.5 rule 5).
        let marathon: [Bool]
        /// The regrowth week at each index, and the original-plan volume of
        /// each cut week a regrowth follows (3.5 rule 6, `GuardrailRegrowth`).
        let regrowthWeeks: [GuardrailRegrowth.Week?]
        let cutOriginals: [Double?]
        var violations: [GuardrailViolation] = []
        var skips: [GuardrailSkip] = []
        var flags: [GuardrailFlag] = []

        init(weeks: [PlanWeek], limits: GuardrailLimits, timeZone: TimeZone, units: UnitPreference,
             regrowth: GuardrailRegrowth = .none) {
            self.weeks = weeks
            self.regrowthWeeks = weeks.map { w in
                regrowth.week(w.weekStart).flatMap { $0.original.isFinite && $0.original >= 0 && $0.step >= 1 ? $0 : nil }
            }
            self.cutOriginals = weeks.map { w in
                regrowth.cutOriginal(w.weekStart).flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            }
            self.limits = limits
            self.timeZone = timeZone
            self.units = units
            self.volumes = weeks.map { $0.volume(limits.measure) }
            self.lows = weeks.map { $0.knownVolume(limits.measure) }
            self.outside = weeks.map { $0.volumeOutsideRaces(limits.measure) }
            self.outsideLows = weeks.map { $0.knownVolumeOutsideRaces(limits.measure) }
            self.raceWeeks = Set(weeks.indices.filter { weeks[$0].hasRace })
            self.breaks = GuardrailChecker.breaks(volumes: outside, lows: outsideLows, raceWeeks: raceWeeks, limits: limits)
            self.marathon = GuardrailChecker.marathonWeeks(weeks)
        }

        /// " outside the race" for a week holding one (3.5 rule 3).
        func outsideNote(_ i: Int) -> String { raceWeeks.contains(i) ? " outside the race" : "" }

        var unit: GuardrailViolation.Unit { limits.measure == .time ? .seconds : .meters }
        func day(_ i: Int) -> String { PlanFormatting.day(weeks[i].weekStart, timeZone: timeZone) }
        func vol(_ v: Double) -> String { PlanFormatting.volume(v, limits.measure, units: units) }
        static func exceeds(_ measured: Double, _ allowed: Double) -> Bool {
            measured > allowed + GuardrailChecker.tolerance * max(1, abs(allowed))
        }

        mutating func skip(_ rule: GuardrailRule, _ i: Int, _ reason: String) {
            skips.append(GuardrailSkip(rule: rule, weekStart: weeks[i].weekStart, reason: reason))
        }

        mutating func violate(_ rule: GuardrailRule, _ i: Int, measured: Double, allowed: Double,
                              unit: GuardrailViolation.Unit, _ text: String, rebuildOn: Date? = nil) {
            let explanation = "Week of \(day(i)): \(text) (Heuristic guardrail, SPEC 3.5.)"
            violations.append(GuardrailViolation(rule: rule, weekStart: weeks[i].weekStart, measured: measured,
                                                 allowed: allowed, unit: unit, explanation: explanation,
                                                 rebuildOn: rebuildOn))
        }

        /// "at least " for a week read at its known part.
        func atLeast(_ known: Bool) -> String { known ? "" : "at least " }
        /// Says a week was read at its known part.
        func knownNote(_ known: Bool) -> String { known ? "" : " (\(unknownVolumeReason); this is its known part)" }

        var unknownVolumeReason: String {
            limits.measure == .time
                ? "a session in this week has no valid duration"
                : "a session in this week has no valid distance"
        }

        /// See the type's doc comment for the definition. A week of unknown
        /// volume is never a recovery week. A week whose week before is
        /// unknown is one only when it is for every true volume of that week:
        /// at most `recoveryWeekMaxRatio` × its known lower bound.
        func isRecovery(_ j: Int) -> Bool {
            guard j >= 0, j < volumes.count, let v = volumes[j] else { return false }
            if v == 0 { return true }
            guard j >= 1 else { return false }
            let prev = volumes[j - 1] ?? lows[j - 1]
            guard prev > 0 else { return false }
            return !Self.exceeds(v, limits.recoveryWeekMaxRatio * prev)
        }

        /// `isRecovery` read on the volume outside races, for the 10% rule's
        /// step back past a recovery week (3.5 rule 3: a race neither makes
        /// nor hides a recovery week there).
        func isOutsideRecovery(_ j: Int) -> Bool {
            guard j >= 0, j < outside.count, let v = outside[j] else { return false }
            if v == 0 { return true }
            guard j >= 1 else { return false }
            let prev = outside[j - 1] ?? outsideLows[j - 1]
            guard prev > 0 else { return false }
            return !Self.exceeds(v, limits.recoveryWeekMaxRatio * prev)
        }

        /// Week-over-week reference volume (outside races), the index it came from, and how.
        func reference(for i: Int) -> (value: Double, index: Int, source: ReferenceSource)? {
            GuardrailChecker.reference(before: i, volumes: outside, lows: outsideLows,
                                       recoveryRatio: limits.recoveryWeekMaxRatio, isRecovery: isOutsideRecovery)
        }

        mutating func checkWeeklyIncrease(_ i: Int) {
            // Measured outside races (3.5 rule 3). A week of unknown volume is
            // read at its known part (#40): a rise over the allowance even
            // there is sure; otherwise not evaluated.
            let known = outside[i] != nil
            let v = outside[i] ?? outsideLows[i]
            guard i >= 1 else { return skip(.weeklyIncrease, i, "no earlier week to compare with") }
            // After a pain stop of more than 14 days, the return's own
            // ceilings and the spike rule bound the weeks back, not rule 2's
            // checks or rule 4's ramp measured from the stop weeks (3.5 rule 7).
            if let g = regrowthWeeks[i], g.maxRise == nil { return checkRegrowth(i, g, volume: v, known: known) }
            if let ramp = GuardrailChecker.returnRamp(i, volumes: outside, lows: outsideLows, breaks: breaks, limits: limits) {
                return checkReturnRamp(i, ramp, volume: v, known: known, regrowth: regrowthWeeks[i])
            }
            if let g = regrowthWeeks[i] { return checkRegrowth(i, g, volume: v, known: known) }
            // A week of unknown volume nearby may hide a short break, after
            // which the ramp would hold this week lower (#40): over the least
            // such cap, the check is not evaluated, unless the plain rule
            // below finds a sure rise.
            if let floor = GuardrailChecker.hiddenBreakFloor(i, volumes: outside, lows: outsideLows, raceWeeks: raceWeeks, unbounded: true,
                                                             limits: limits),
               Self.exceeds(v, floor) {
                let before = violations.count
                checkPlainWeeklyIncrease(i, volume: v, known: known)
                if violations.count == before {
                    skips.removeAll { $0.rule == .weeklyIncrease && $0.weekStart == weeks[i].weekStart }
                    skip(.weeklyIncrease, i, "a week of unknown volume in the weeks before may hide a short break, after which the return ramp (SPEC 3.5 rule 4) would allow as little as \(vol(floor))")
                }
                return
            }
            checkPlainWeeklyIncrease(i, volume: v, known: known)
        }

        mutating func checkPlainWeeklyIncrease(_ i: Int, volume v: Double, known: Bool) {
            guard let ref = reference(for: i) else {
                return skip(.weeklyIncrease, i, "no earlier week has known volume")
            }
            guard ref.value > 0 else {
                // Resting on an unknown week with no session of known time, the
                // reference may truly be any small volume, so the only allowance
                // safe for all of them is none (the plan builder's ledger caps
                // the week at 0 too). A known zero week is a real zero: no rise
                // can be measured from it (#40).
                let restsOnUnknown = ref.source == .unknownWeekBound
                    || (ref.source == .beforeRecovery && outside[ref.index] == nil)
                guard restsOnUnknown else {
                    return skip(.weeklyIncrease, i, "the reference week (\(day(ref.index))) has no volume, so a percentage rise can't be measured")
                }
                guard Self.exceeds(v, 0) else { return known ? () : skip(.weeklyIncrease, i, unknownVolumeReason) }
                return violate(.weeklyIncrease, i, measured: v, allowed: 0, unit: unit,
                               "volume\(outsideNote(i)) \(atLeast(known))\(vol(v)) follows the week of \(day(ref.index)), whose volume is unknown and has no session with a known time, so it may have been almost nothing. No rise over it is known to be within \(PlanFormatting.percent(limits.maxWeeklyIncrease)), so this week can't be planned until a week of known volume has been run.",
                               rebuildOn: PlanCalendar.nextWeekStart(after: weeks[i].weekStart, timeZone: timeZone))
            }
            let allowed = ref.value * (1 + limits.maxWeeklyIncrease)
            guard Self.exceeds(v, allowed) else {
                return known ? () : skip(.weeklyIncrease, i, "\(unknownVolumeReason); its known part is within the limit, the rest may not be")
            }
            let rise = v / ref.value - 1
            let refText: String
            switch ref.source {
            case .weekBefore:
                refText = "the week before (\(vol(ref.value))\(outsideNote(ref.index)))"
            case .beforeRecovery:
                refText = outside[ref.index] == nil
                    ? "the week before the recovery week of \(day(i - 1)), which has unknown volume but at least \(vol(ref.value))"
                    : "the last week before the recovery week of \(day(i - 1)) (\(vol(ref.value))\(outsideNote(ref.index)))"
            case .unknownWeekBound:
                refText = "the least the week before can have held (\(vol(ref.value))): its volume is unknown, at least \(vol(outsideLows[i - 1])) known, and as a build week it was over \(PlanFormatting.percent(limits.recoveryWeekMaxRatio)) of the week before it"
            }
            let raceText = raceWeeks.contains(i) || raceWeeks.contains(ref.index)
                ? " The race itself is left out of this check (SPEC 3.5 rule 3)." : ""
            violate(.weeklyIncrease, i, measured: v, allowed: allowed, unit: unit,
                    "volume\(outsideNote(i)) \(atLeast(known))\(vol(v))\(knownNote(known)) is \(known ? "" : "at least ")\(PlanFormatting.percent(rise)) above \(refText). The limit is a rise of \(PlanFormatting.percent(limits.maxWeeklyIncrease)), so at most \(vol(allowed)).\(raceText)")
        }

        /// The regrowth's bound for week `i` (3.5 rule 6, owner decision Nov
        /// 21, #107): `Week.allowed(previous:)` over the week before as run or
        /// planned: the higher of the weekly rise and the week's return step,
        /// never above the original plan's week. Nil when the week
        /// before is unknown and the week has a weekly bound.
        func regrowthCap(_ i: Int, _ g: GuardrailRegrowth.Week) -> Double? {
            g.allowed(previous: i >= 1 ? outside[i - 1] : nil)
        }

        func regrowthWhy(_ i: Int, _ g: GuardrailRegrowth.Week, cap: Double) -> String {
            let plan = "never above the original plan's \(vol(g.original))"
            guard let rise = g.maxRise else {
                return "this is week \(g.step) back after a pain stop of more than 14 days, bounded by the original plan and the return's own ceilings (\(plan))"
            }
            let before = i >= 1 ? (outside[i - 1] ?? 0) : 0
            let share = PlanFormatting.percent(g.stepShare)
            let level = "week \(g.step)'s return step of \(share) of the original plan (\(vol(g.stepShare * g.original)))"
            guard before > 0 else {
                return "this is week \(g.step) of growing back after a cut week, and the week before ran nothing, so \(level) bounds it, \(plan)"
            }
            var why = "this is week \(g.step) of growing back after a cut week: at most the higher of \(PlanFormatting.percent(rise)) more than the week before (\(vol(before))) and \(level)"
            if let p = g.previousOriginal, p > 0, g.original / p > 1 + rise, before >= g.atPlanShare * p - 1e-9 {
                why += ", or as much as the original plan itself rises into this week after a week at plan (\(PlanFormatting.percent(g.original / p - 1)))"
            }
            return why + ", \(plan)"
        }

        /// The 10% check's stand-in for a week of a regrowth after a cut week
        /// (3.5 rules 2 and 6, owner decision Nov 21, #107): at most the
        /// regrowth's bound (`regrowthCap`), which grows toward the original
        /// plan and never above it. When the week before is unknown, the plain
        /// check applies instead (#40).
        mutating func checkRegrowth(_ i: Int, _ g: GuardrailRegrowth.Week, volume v: Double, known: Bool) {
            guard let allowed = regrowthCap(i, g) else { return checkPlainWeeklyIncrease(i, volume: v, known: known) }
            guard Self.exceeds(v, allowed) else {
                if let floor = GuardrailChecker.hiddenBreakFloor(i, volumes: outside, lows: outsideLows, raceWeeks: raceWeeks,
                                                                 unbounded: true, limits: limits),
                   Self.exceeds(v, floor) {
                    return skip(.weeklyIncrease, i, "a week of unknown volume in the weeks before may hide a short break, after which the return ramp (SPEC 3.5 rule 4) would allow as little as \(vol(floor))")
                }
                return known ? () : skip(.weeklyIncrease, i, "\(unknownVolumeReason); its known part is within the regrowth, the rest may not be")
            }
            violate(.weeklyIncrease, i, measured: v, allowed: allowed, unit: unit,
                    "volume\(outsideNote(i)) \(atLeast(known))\(vol(v))\(knownNote(known)) is above the regrowth: \(regrowthWhy(i, g, cap: allowed)) (SPEC 3.5 rule 6). So at most \(vol(allowed)).")
        }

        /// The 10% check's stand-in for a week of the return ramp after a short
        /// break (3.5 rules 2 and 4): at most the ramp's cap, and in a week
        /// that is also in a regrowth (rule 6) at most the lower of the two.
        mutating func checkReturnRamp(_ i: Int, _ ramp: ReturnRamp, volume v: Double, known: Bool,
                                      regrowth g: GuardrailRegrowth.Week? = nil) {
            let grow = g.flatMap { regrowthCap(i, $0) }
            let cap = min(ramp.allowed, grow ?? .infinity)
            guard Self.exceeds(v, cap) else {
                return known ? () : skip(.weeklyIncrease, i, "\(unknownVolumeReason); its known part is within the return ramp, the rest may not be")
            }
            if let g, let grow, grow < ramp.allowed {
                return violate(.weeklyIncrease, i, measured: v, allowed: cap, unit: unit,
                               "volume\(outsideNote(i)) \(atLeast(known))\(vol(v))\(knownNote(known)) is above the regrowth: this week is both in the return ramp after a short break (at most \(vol(ramp.allowed))) and in the regrowth, where \(regrowthWhy(i, g, cap: grow)) (at most \(vol(grow))), and the lower of the two applies (SPEC 3.5 rules 4 and 6), so at most \(vol(cap)).")
            }
            let b = ramp.brk
            let weeksOff = b.length == 1 ? "a week" : "\(b.length) weeks"
            let share = PlanFormatting.percent(limits.breakReturnSteps[ramp.step - 1])
            let ratio = PlanFormatting.percent(limits.breakWeekMaxRatio)
            var why = "this is week \(ramp.step) back after \(weeksOff) of little or no running (at most \(ratio) of the pre-break \(vol(b.level)) a week), and the return ramp allows week \(ramp.step) at most \(share) of the pre-break volume"
            if ramp.limitedByWeekBefore, ramp.step >= 2 {
                let steps = limits.breakReturnSteps
                let rise = PlanFormatting.percent(steps[ramp.step - 1] / steps[ramp.step - 2] - 1)
                why += ", and at most \(rise) more than the week before (\(vol(outside[i - 1] ?? outsideLows[i - 1]))), as the ramp itself rises"
            }
            violate(.weeklyIncrease, i, measured: v, allowed: ramp.allowed, unit: unit,
                    "volume\(outsideNote(i)) \(atLeast(known))\(vol(v))\(knownNote(known)) is above the return ramp: \(why), so at most \(vol(ramp.allowed)).")
        }

        mutating func checkFourWeekIncrease(_ i: Int) {
            // Not after a pain stop of more than 14 days: the return's own
            // ceilings bound those weeks (3.5 rule 7).
            if let g = regrowthWeeks[i], g.maxRise == nil {
                return skip(.fourWeekIncrease, i, "this is week \(g.step) back after a pain stop of more than 14 days, which the return's own ceilings bound instead (SPEC 3.5 rule 7)")
            }
            guard i >= 7 else {
                return skip(.fourWeekIncrease, i, "needs 8 weeks of history and plan up to this week; only \(i + 1) available")
            }
            // Outside races (3.5 rule 3). Unknown weeks count at their known
            // lower bound (#40). In the earlier 4 weeks that only lowers the
            // allowance, so the check stands; in the recent 4 it can only show
            // a sure violation. A week of a short break counts at the
            // pre-break level among the earlier 4 (3.5 rule 4).
            func low(_ k: Int) -> Double { outside[k] ?? outsideLows[k] }
            // A cut week a regrowth follows counts at its original-plan volume
            // among the earlier 4 (3.5 rules 2 and 6), as a short break does.
            func priorVolume(_ k: Int) -> Double {
                max(GuardrailChecker.rollingPriorVolume(k, volumes: outside, lows: outsideLows, breaks: breaks, limits: limits),
                    cutOriginals[k] ?? 0)
            }
            let prior = ((i - 7)...(i - 4)).reduce(0) { $0 + priorVolume($1) }
            let recent = ((i - 3)...i).reduce(0) { $0 + low($1) }
            let recentKnown = ((i - 3)...i).allSatisfy { outside[$0] != nil }
            let priorKnown = ((i - 7)...(i - 4)).allSatisfy { outside[$0] != nil }
            let substituted = ((i - 7)...(i - 4)).contains { priorVolume($0) > low($0) }
            guard prior > 0 else {
                return skip(.fourWeekIncrease, i, "the 4 weeks before the window have no volume")
            }
            let allowed = prior * (1 + limits.maxFourWeekIncrease)
            guard Self.exceeds(recent, allowed) else {
                if !recentKnown {
                    skip(.fourWeekIncrease, i, "a week in the 4 weeks up to this one has unknown volume")
                }
                return
            }
            let races = ((i - 7)...i).contains { raceWeeks.contains($0) } ? " Races are left out (SPEC 3.5 rule 3)." : ""
            let breakText = substituted ? " A short break or a cut week among those 4 weeks counts at the pre-break level or the original plan (SPEC 3.5 rules 4 and 6)." : ""
            violate(.fourWeekIncrease, i, measured: recent, allowed: allowed, unit: unit,
                    "the 4 weeks ending this week total \(recentKnown ? "" : "at least ")\(vol(recent)), \(PlanFormatting.percent(recent / prior - 1)) more than the 4 weeks before (\(priorKnown ? "" : "at least ")\(vol(prior))). The limit is \(PlanFormatting.percent(limits.maxFourWeekIncrease)) over any rolling 4 weeks, so at most \(vol(allowed)).\(breakText)\(races)")
        }

        mutating func checkLongRunShare(_ i: Int) {
            let longs = weeks[i].workouts.filter { $0.kind == .long }
            guard !longs.isEmpty else { return }
            // Read in time (3.5 rule 5: a share of weekly time), whatever
            // `measure` is. A week of unknown time has no upper bound, so a
            // share read at its known part is only the worst case, not a sure
            // violation, and repair would cut on it (#40): not evaluated.
            guard let total = weeks[i].volume(.time) else {
                return skip(.longRunShare, i, "a session in this week has no valid duration")
            }
            // Week time known implies every session's time is known.
            guard let longest = longs.max(by: { ($0.volume(.time) ?? 0) < ($1.volume(.time) ?? 0) }),
                  let seconds = longest.volume(.time), total > 0 else { return }
            func time(_ v: Double) -> String { PlanFormatting.volume(v, .time) }
            let share = seconds / total
            let marathonPlan = marathon[i]
            let limit = marathonPlan ? limits.marathonLongRunCeiling : limits.maxLongRunShare
            guard Self.exceeds(share, limit) else {
                // A marathon plan's long run above the usual share is a warning only (3.5 rule 5).
                guard marathonPlan, Self.exceeds(share, limits.maxLongRunShare) else { return }
                let text = "Week of \(day(i)): the long run (\(time(seconds))) is \(PlanFormatting.percent(share)) of the week's \(time(total)) of running, above the usual \(PlanFormatting.percent(limits.maxLongRunShare)). Marathon plans allow up to \(PlanFormatting.percent(limit)); if this holds week after week, more weekly volume or a longer build is the better fix. (Heuristic guardrail, SPEC 3.5 rule 5; a warning, not a block.)"
                flags.append(GuardrailFlag(rule: .longRunShare, weekStart: weeks[i].weekStart, measured: share,
                                           allowed: limits.maxLongRunShare, unit: .fraction, explanation: text,
                                           workoutID: longest.id))
                return
            }
            let marathonText = marathonPlan ? " in a marathon plan" : ""
            violate(.longRunShare, i, measured: share, allowed: limit, unit: .fraction,
                    "the long run (\(time(seconds))) is \(PlanFormatting.percent(share)) of the week's \(time(total)) of running. The limit is \(PlanFormatting.percent(limit)) of weekly time\(marathonText), so at most \(time(total * limit)) for this week.")
        }

        mutating func checkQualitySessions(_ i: Int) {
            let count = weeks[i].workouts.filter { $0.kind.isQuality || (limits.racesCountAsQuality && $0.kind == .race) }.count
            let races = limits.racesCountAsQuality ? " (races count as quality sessions)" : ""
            // Weeks 1 and 2 back after a short break hold fewer (3.5 rule 4).
            if let ramp = GuardrailChecker.returnRamp(i, volumes: outside, lows: outsideLows, breaks: breaks, limits: limits),
               let allowed = limits.returnRampMaxQuality(step: ramp.step) {
                guard count > allowed else { return }
                let off = ramp.brk.length == 1 ? "a week" : "\(ramp.brk.length) weeks"
                let limit = allowed == 0 ? "no quality sessions" : allowed == 1 ? "at most 1 quality session" : "at most \(allowed) quality sessions"
                return violate(.qualitySessions, i, measured: Double(count), allowed: Double(allowed), unit: .sessions,
                               "\(count) quality sessions are planned\(races) in week \(ramp.step) back after \(off) off. The return ramp (SPEC 3.5 rule 4) allows \(limit) in that week.")
            }
            // A week of unknown volume nearby may hide a short break (#40),
            // after which the ramp would allow fewer: within the plain limit
            // but over that, the check is not evaluated.
            if count <= limits.maxQualitySessionsPerWeek,
               let hidden = GuardrailChecker.hiddenBreakMaxQuality(i, volumes: outside, lows: outsideLows, raceWeeks: raceWeeks,
                                                                   unbounded: true, limits: limits),
               count > hidden {
                return skip(.qualitySessions, i, "a week of unknown volume in the weeks before may hide a short break, after which the return ramp (SPEC 3.5 rule 4) would allow as few as \(hidden) quality sessions")
            }
            guard count > limits.maxQualitySessionsPerWeek else { return }
            violate(.qualitySessions, i, measured: Double(count), allowed: Double(limits.maxQualitySessionsPerWeek), unit: .sessions,
                    "\(count) quality sessions are planned\(races). The limit is \(limits.maxQualitySessionsPerWeek) a week.")
        }

        mutating func checkFreeze(_ i: Int) {
            // A week of unknown volume is read at its known part (#40), as above.
            let thisKnown = volumes[i] != nil
            let v = volumes[i] ?? lows[i]
            // Held to the previous week's actual volume: unlike the 10% rule there
            // is no step back past a recovery week, because a freeze stops growth.
            guard i >= 1 else {
                return skip(.volumeFreeze, i, "there is no week before, so there is nothing to hold to")
            }
            // A week before of unknown volume held at least its known part
            // (`lows`, #40): holding to that keeps the freeze for every
            // volume the week may truly have held.
            let known = volumes[i - 1] != nil
            let prev = volumes[i - 1] ?? lows[i - 1]
            guard prev > 0 else {
                guard !known else {
                    return skip(.volumeFreeze, i, "the week before has no volume, so there is nothing to hold to")
                }
                // Unknown with nothing of known time: it may have been almost
                // nothing, so the freeze allows nothing until a week of known
                // volume has been run, as the 10% rule does.
                guard Self.exceeds(v, 0) else { return thisKnown ? () : skip(.volumeFreeze, i, unknownVolumeReason) }
                return violate(.volumeFreeze, i, measured: v, allowed: 0, unit: unit,
                               "volume growth is frozen after a pain check-in, and the week before has unknown volume with no session of known time, so it may have been almost nothing. No volume this week is known to stay within it, so this week can't be planned until a week of known volume has been run.",
                               rebuildOn: PlanCalendar.nextWeekStart(after: weeks[i].weekStart, timeZone: timeZone))
            }
            guard Self.exceeds(v, prev) else {
                return thisKnown ? () : skip(.volumeFreeze, i, "\(unknownVolumeReason); its known part is within the freeze, the rest may not be")
            }
            let before = known ? "the \(vol(prev)) of the week before"
                : "the \(vol(prev)) known of the week before (its volume is unknown, at least that)"
            violate(.volumeFreeze, i, measured: v, allowed: prev, unit: unit,
                    "volume growth is frozen after a pain check-in, but this week plans \(atLeast(thisKnown))\(vol(v))\(knownNote(thisKnown)), more than \(before).")
        }

        mutating func checkRecoveryCadence(checked: Set<Int>) {
            var streak = 0
            for j in weeks.indices {
                // A week of unknown volume may have been a build week, so it
                // counts as one (#40); `isRecovery` never calls it a recovery week.
                if isRecovery(j) { streak = 0; continue }
                streak += 1
                guard streak > limits.maxConsecutiveBuildWeeks, checked.contains(j) else { continue }
                let ratio = PlanFormatting.percent(limits.recoveryWeekMaxRatio)
                violate(.recoveryWeek, j, measured: Double(streak), allowed: Double(limits.maxConsecutiveBuildWeeks), unit: .weeks,
                        "this would be week \(streak) in a row without a recovery week. A recovery week (volume at most \(ratio) of the week before) is needed after at most \(limits.maxConsecutiveBuildWeeks) build weeks.")
            }
        }
    }
}
