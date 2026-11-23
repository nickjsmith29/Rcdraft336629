// TimeZone is not Sendable in swift-corelibs-foundation
// (Linux, Swift 5.10); @preconcurrency keeps AdaptationContext's Sendable conformance warning-free there.
@preconcurrency import Foundation

/// What one completed run says about fitness against the plan (SPEC.md F4, section 8).
public enum RunSignal: String, CaseIterable, Equatable, Hashable, Sendable, Codable {
    /// Beat the target pace at a low heart rate: fitness is ahead of the plan.
    case ahead
    /// Pace and heart rate where the plan expected them.
    case onTrack
    /// Missed the target pace, or hit it only at a high heart rate.
    case behind
    /// Signs of strain (high heart rate with drift, cadence fade or a high RPE).
    case overreached
}

/// One measured value behind an assessment or a plan change, so every change
/// can say which numbers triggered it (F4 acceptance).
public struct TriggerMetric: Equatable, Sendable, Codable {
    public enum Metric: String, Equatable, Hashable, Sendable, Codable {
        /// Mean grade-unadjusted pace over the session's key segments (F7 adds GAP).
        case pace
        /// Mean heart rate over the session's key segments.
        case heartRate
        /// Pace-to-HR aerobic decoupling (3.3).
        case decoupling
        /// Power-to-HR aerobic decoupling (3.3).
        case powerToHeartRate
        /// Cadence drop in the final third versus the first third (F4).
        case cadenceFade
        /// Rating of perceived exertion, 1 to 10, when the runner gives one.
        case rpe
        /// A pain check-in score, 0 to 10 (3.5).
        case painScore
        /// The rise of a pain score from the check-in before it (3.5).
        case painRise
        /// How many recent sessions pointed the same way (section 8).
        case signalCount
        /// A planned session that was not run.
        case missedSession
        /// Weekly volume against a guardrail limit (3.5).
        case weeklyVolume
        /// Long-run share of the week against the guardrail (3.5).
        case longRunShare
        /// Weeks in a row without a recovery week (3.5).
        case buildWeeks
        /// Duration of a completed or planned long run.
        case longRunDuration
        /// A planned run's length against the longest run of the previous 30
        /// days (single-run spike rule, 3.5 rule 1), in seconds or meters.
        case singleRunSpike
        /// Sessions in a week with no known duration or distance, so the
        /// week's volume can't be measured (a count, not a volume).
        case unmeasuredSessions
        /// Calendar days between two hard days (quality sessions or races).
        case daysBetweenHardDays
        /// How far power-to-HR over the key part fell below the runner's own
        /// mean over recent sessions of the same kind, in percent (3.3, F4).
        case powerToHeartRateDrop
        /// How many pain stop triggers a pain report fired (3.5 rule 7; a count).
        case painStopTriggers
        /// The step of the return after a pain stop (3.5 rule 7; 1 is week 1).
        case painReturnStep
        /// Quality sessions planned in a week against the limit (3.5 rule 4's
        /// return ramp or the weekly limit; a count).
        case qualitySessions
        /// Days without a run in the break behind the return factor (3.5 rule 4).
        case daysOff
    }

    public enum Unit: String, Equatable, Hashable, Sendable, Codable {
        case secondsPerKm, bpm, percent, rpe, painScore, count, seconds, meters, fraction, weeks, days
    }

    public let metric: Metric
    public let value: Double
    /// The expected or allowed range, when there is one; either end may be open.
    public let expectedLow: Double?
    public let expectedHigh: Double?
    public let unit: Unit
    /// The activity, session or check-in the value came from, when there is one.
    public let sourceID: String?
    /// One plain-English line, e.g. "pace 4:52/km against a target of 4:40 to 4:47/km".
    public let detail: String

    public init(metric: Metric, value: Double, expectedLow: Double? = nil, expectedHigh: Double? = nil,
                unit: Unit, sourceID: String? = nil, detail: String) {
        self.metric = metric
        self.value = value
        self.expectedLow = expectedLow
        self.expectedHigh = expectedHigh
        self.unit = unit
        self.sourceID = sourceID
        self.detail = detail
    }
}

/// One change the adaptation engine made to the plan, with the metrics that
/// triggered it (F4: "each change cites its trigger metrics"). `triggers` is
/// never empty.
public struct PlanChange: Equatable, Sendable, Codable {
    public enum Kind: String, CaseIterable, Equatable, Hashable, Sendable, Codable {
        /// Progression stopped by the pain stop rule (3.5 rule 7), or a
        /// standing stop made stricter (easy-only to rest). Touches no session
        /// itself; the `qualitySwappedToEasy` and `sessionRested` changes that
        /// carry it out follow. First in `allCases`, so the debrief (F6) states it
        /// first. See `AdaptationState.painStop`.
        case painStop
        /// Quality pace targets one step faster (section 8).
        case paceTargetsFaster
        /// Quality pace targets one step slower (section 8).
        case paceTargetsSlower
        /// Volume held for a week after sessions pointed behind (section 8).
        case volumeHeld
        /// Easy pace targets one step slower because easy runs ran above the zone-2 cap (section 8).
        case easyPaceSlower
        /// Anchor- and easy-derived paces moved by the factor for the days off after a break (3.5 rule 4, #28), slower or back toward the pre-break targets.
        case returnPaces
        /// The next long run kept at its current length until decoupling allows a step (3.3).
        case longRunHeld
        /// Volume growth frozen after a pain check-in (3.5).
        case painVolumeFreeze
        /// A quality session turned into an easy run of the same length: the
        /// next one after a pain check-in (3.5), or one that a quality session
        /// run on another day than planned now sits on or next to (F4: never
        /// stack two quality days). `rule` says which.
        case qualitySwappedToEasy
        /// A long run turned into an easy run of the same length because no
        /// cut could bring it within the long-run share: it was the only run
        /// left in its week, or at its floor (3.5 rules 5 and 6, #64). Or a
        /// long run that a pain-stop cap (the return's week-1 cap, the
        /// easy-only stop's long-run share) would leave under the easy-run
        /// floor, turned into an easy run at the floor (3.5 rules 5 and 7, #101).
        case longRunSwappedToEasy
        /// A missed session moved onto the day of a lower-value one (F4 missed days).
        case sessionMoved
        /// A session left out: missed and not made up, or the lowest-value one of a short week.
        case sessionDropped
        /// A session shortened to keep the plan inside the guardrails (3.5, F9).
        case sessionShortened
        /// A volume hold that could not be met: cutting what it may cut
        /// (easy and recovery runs, and long runs down to their hold floor)
        /// leaves the week above the held level, or the week's volume is
        /// unknown. A measured week cites two `weeklyVolume` triggers (the
        /// planned volume and what is left, each against the held level); an
        /// unknown week cites one `unmeasuredSessions` trigger (how many
        /// sessions have no known volume) and no volume, since none was
        /// measured. Posted only when it is new or differs from the one the
        /// previous event found for that week (`AdaptationState.reportedHoldShortfalls`);
        /// `AdaptationOutcome.holdsSatisfied` stays false while it lasts.
        case holdShortfall
        /// A run turned into a rest day while a pain stop in rest mode stands,
        /// or by the return guards (alternate days, the rest day after a
        /// recurrence) (3.5 rule 7), or a long run a pain-stop cap would leave
        /// under the easy-run floor where no run at the floor fits (#101).
        case sessionRested
        /// A session made the test run that can end a pain stop (3.5 rule 7).
        case painTestRun
        /// A test run that didn't pass: pain past the test-run limits, a
        /// movement change, no in-run report, or a next morning above usual;
        /// the stop stays and the 2-morning count starts again (3.5 rule 7).
        case painTestRunFailed
        /// A test run withdrawn (it becomes a rest day) because a later
        /// report broke the 2-morning count before it was run (3.5 rule 7).
        case painTestRunWithdrawn
        /// Other runs of the test run's week dropped so that the test run
        /// fits the load guardrails (3.5 rule 7).
        case painTestRunRoom
        /// A pain stop ended by its end path; the return starts (3.5 rule 7).
        case painStopEnded
        /// The return after a stop moved: a step back after symptoms came
        /// back, or the return finished and quality sessions come back (3.5 rule 7).
        case painReturnStep
        /// The week at full plan volume was short of its planned volume or
        /// had symptoms, so it repeats and quality stays out (3.5 rule 7).
        case painReturnRepeated
        /// Sessions of a week grown back toward the plan the app handed in,
        /// never above it, after a missed, cut or painful week (3.5 rule 6,
        /// #64). Cites the week's new volume against the original plan.
        case sessionRegrown
    }

    public let kind: Kind
    /// Sessions the change touched (empty for a change that only flags something).
    public let workoutIDs: [String]
    public let triggers: [TriggerMetric]
    /// The SPEC sections behind the change, e.g. "SPEC F4, section 8 (heuristic)".
    public let rule: String
    public let explanation: String

    public init(kind: Kind, workoutIDs: [String], triggers: [TriggerMetric], rule: String, explanation: String) {
        self.kind = kind
        self.workoutIDs = workoutIDs
        self.triggers = triggers
        self.rule = rule
        self.explanation = explanation
    }
}

/// Thresholds for the adaptation engine. Every value is a **heuristic** from
/// SPEC.md F4 and section 8 (or 3.3 and 3.5 where noted), not a validated cut-off.
/// A `Double` limit that isn't a finite number, or is below 0, is stored as its
/// default instead (see `valid`, #133), and so is a whole-number limit below 0
/// (#157) or, where it is used in date or week arithmetic, above its
/// input-sanity bound (`upperBound`, #147).
public struct AdaptationLimits: Equatable, Sendable {
    /// Pace within this fraction of the target range counts as on target. Default 0.01 (1%).
    public var paceTolerance: Double { didSet { paceTolerance = Self.valid(paceTolerance, \.paceTolerance) } }
    /// One pace step, as a fraction (section 8: "about 1 to 2%"). Default 0.015.
    public var paceStep: Double { didSet { paceStep = Self.valid(paceStep, \.paceStep) } }
    /// Sessions looked back over for a pace move (section 8: "the last three"). Default 3.
    public var signalWindow: Int { didSet { signalWindow = Self.valid(signalWindow, \.signalWindow) } }
    /// Sessions in that window that must agree (section 8, F4: "two or more"). Default 2.
    public var signalsToMove: Int { didSet { signalsToMove = Self.valid(signalsToMove, \.signalsToMove) } }
    /// Easy runs averaged for the zone-2 cap check. Default 3.
    public var easyRunsForCapCheck: Int { didSet { easyRunsForCapCheck = Self.valid(easyRunsForCapCheck, \.easyRunsForCapCheck) } }
    /// Decoupling above this (percent) on a steady run is a strain marker. Default 10 (3.3: "above aerobic threshold").
    public var strainDecouplingPercent: Double { didSet { strainDecouplingPercent = Self.valid(strainDecouplingPercent, \.strainDecouplingPercent) } }
    /// A cadence drop of at least this (percent) is a strain marker. Default 3.
    public var strainCadenceFadePercent: Double { didSet { strainCadenceFadePercent = Self.valid(strainCadenceFadePercent, \.strainCadenceFadePercent) } }
    /// RPE this far above the session's expected range is a strain marker. Default 2.
    public var strainRPEMargin: Int { didSet { strainRPEMargin = Self.valid(strainRPEMargin, \.strainRPEMargin) } }
    /// RPE this far above the expected range alone means overreached. Default 3.
    public var overreachedRPEMargin: Int { didSet { overreachedRPEMargin = Self.valid(overreachedRPEMargin, \.overreachedRPEMargin) } }
    /// Long-run decoupling must stay under this (percent) to allow a step (3.3). Default 5.
    public var longRunDecouplingLimit: Double { didSet { longRunDecouplingLimit = Self.valid(longRunDecouplingLimit, \.longRunDecouplingLimit) } }
    /// A long run counts as done "at target duration" at this share of its planned time. Default 0.95.
    public var longRunCompletionShare: Double { didSet { longRunCompletionShare = Self.valid(longRunCompletionShare, \.longRunCompletionShare) } }
    /// Qualifying long runs needed in a row before the next step (section 8: "twice"). Default 2.
    public var longRunQualifyingCount: Int { didSet { longRunQualifyingCount = Self.valid(longRunQualifyingCount, \.longRunQualifyingCount) } }
    /// The largest long-run step the gate allows. Default `PlanHeuristics.longRunStepSeconds` (10 min).
    public var longRunStepSeconds: Double { didSet { longRunStepSeconds = Self.valid(longRunStepSeconds, \.longRunStepSeconds) } }
    /// Recent long runs whose longest planned length is the level a step starts from. Default 4.
    public var longRunReferenceRuns: Int { didSet { longRunReferenceRuns = Self.valid(longRunReferenceRuns, \.longRunReferenceRuns) } }
    /// Days volume is held after sessions point behind. Default 7.
    public var holdVolumeDays: Int { didSet { holdVolumeDays = Self.valid(holdVolumeDays, \.holdVolumeDays) } }
    /// A volume hold shortens a long run to no less than this share of its
    /// planned length (the long-run floor); it never cuts races or quality
    /// sessions. The long-run share guardrail can still cut below it (see
    /// `VolumeHold.longRunFloorSeconds`). Heuristic. Default 0.85.
    public var holdLongRunFloorShare: Double { didSet { holdLongRunFloorShare = Self.valid(holdLongRunFloorShare, \.holdLongRunFloorShare) } }
    /// Climb per km at or above which raw pace can't be judged until GAP (F7) exists. Default 15 m/km.
    public var hillyClimbMetersPerKm: Double { didSet { hillyClimbMetersPerKm = Self.valid(hillyClimbMetersPerKm, \.hillyClimbMetersPerKm) } }
    /// A run must cover at least this share of the planned key time to be classified. Default 0.5.
    public var minimumKeyShare: Double { didSet { minimumKeyShare = Self.valid(minimumKeyShare, \.minimumKeyShare) } }
    /// Shortest easy, recovery or long run a guardrail trim leaves. Default `PlanHeuristics.minimumEasyRunSeconds`.
    /// A finite value of 0 or less applies no floor; NaN, +inf and -inf aren't finite, so each becomes the default floor (see `valid`).
    public var minimumTrimmedSeconds: Double { didSet { minimumTrimmedSeconds = Self.valid(minimumTrimmedSeconds, \.minimumTrimmedSeconds) } }
    /// Power-to-HR against the runner's own history (F4 "power-to-HR"), a
    /// heuristic like Friel's efficiency factor: at most this many of the most
    /// recent planned sessions of the same kind are averaged. Default 5.
    public var powerHistoryRuns: Int { didSet { powerHistoryRuns = Self.valid(powerHistoryRuns, \.powerHistoryRuns) } }
    /// Only sessions within this many days before the run count. Default 42 (6 weeks).
    public var powerHistoryDays: Int { didSet { powerHistoryDays = Self.valid(powerHistoryDays, \.powerHistoryDays) } }
    /// Fewer comparable sessions than this and no comparison is made. Default 3.
    public var powerHistoryMinimumRuns: Int { didSet { powerHistoryMinimumRuns = Self.valid(powerHistoryMinimumRuns, \.powerHistoryMinimumRuns) } }
    /// Power-to-HR this many percent or more below that mean is a strain
    /// marker (the same heart rate bought less power). Default 5.
    public var powerToHeartRateDropPercent: Double { didSet { powerToHeartRateDropPercent = Self.valid(powerToHeartRateDropPercent, \.powerToHeartRateDropPercent) } }
    /// Regrowth after a cut week (3.5 rule 6, owner decision Nov 21, #107): a
    /// regrowth goes on, measured against the original plan, until a week
    /// holds at least this share of its original-plan volume (what was run,
    /// plus what the plan still holds for the current week): back at plan.
    /// A margin for GPS and moving-time noise. Heuristic. Default 0.98.
    public var regrowthAtPlanShare: Double { didSet { regrowthAtPlanShare = Self.valid(regrowthAtPlanShare, \.regrowthAtPlanShare) } }
    /// Weeks of the plan as handed in kept before the current week
    /// (`PlanSnapshot`), enough to see the cut weeks a regrowth follows and
    /// the 8 weeks the rolling check reads. Default 10.
    public var regrowthSnapshotWeeks: Int { didSet { regrowthSnapshotWeeks = Self.valid(regrowthSnapshotWeeks, \.regrowthSnapshotWeeks) } }

    public init(paceTolerance: Double = 0.01,
                paceStep: Double = 0.015,
                signalWindow: Int = 3,
                signalsToMove: Int = 2,
                easyRunsForCapCheck: Int = 3,
                strainDecouplingPercent: Double = 10,
                strainCadenceFadePercent: Double = 3,
                strainRPEMargin: Int = 2,
                overreachedRPEMargin: Int = 3,
                longRunDecouplingLimit: Double = 5,
                longRunCompletionShare: Double = 0.95,
                longRunQualifyingCount: Int = 2,
                longRunStepSeconds: Double = PlanHeuristics.longRunStepSeconds,
                longRunReferenceRuns: Int = 4,
                holdVolumeDays: Int = 7,
                holdLongRunFloorShare: Double = 0.85,
                hillyClimbMetersPerKm: Double = 15,
                minimumKeyShare: Double = 0.5,
                minimumTrimmedSeconds: Double = PlanHeuristics.minimumEasyRunSeconds,
                powerHistoryRuns: Int = 5,
                powerHistoryDays: Int = 42,
                powerHistoryMinimumRuns: Int = 3,
                powerToHeartRateDropPercent: Double = 5,
                regrowthAtPlanShare: Double = 0.98,
                regrowthSnapshotWeeks: Int = 10) {
        self.paceTolerance = Self.valid(paceTolerance, \.paceTolerance)
        self.paceStep = Self.valid(paceStep, \.paceStep)
        self.signalWindow = Self.valid(signalWindow, \.signalWindow)
        self.signalsToMove = Self.valid(signalsToMove, \.signalsToMove)
        self.easyRunsForCapCheck = Self.valid(easyRunsForCapCheck, \.easyRunsForCapCheck)
        self.strainDecouplingPercent = Self.valid(strainDecouplingPercent, \.strainDecouplingPercent)
        self.strainCadenceFadePercent = Self.valid(strainCadenceFadePercent, \.strainCadenceFadePercent)
        self.strainRPEMargin = Self.valid(strainRPEMargin, \.strainRPEMargin)
        self.overreachedRPEMargin = Self.valid(overreachedRPEMargin, \.overreachedRPEMargin)
        self.longRunDecouplingLimit = Self.valid(longRunDecouplingLimit, \.longRunDecouplingLimit)
        self.longRunCompletionShare = Self.valid(longRunCompletionShare, \.longRunCompletionShare)
        self.longRunQualifyingCount = Self.valid(longRunQualifyingCount, \.longRunQualifyingCount)
        self.longRunStepSeconds = Self.valid(longRunStepSeconds, \.longRunStepSeconds)
        self.longRunReferenceRuns = Self.valid(longRunReferenceRuns, \.longRunReferenceRuns)
        self.holdVolumeDays = Self.valid(holdVolumeDays, \.holdVolumeDays)
        self.holdLongRunFloorShare = Self.valid(holdLongRunFloorShare, \.holdLongRunFloorShare)
        self.hillyClimbMetersPerKm = Self.valid(hillyClimbMetersPerKm, \.hillyClimbMetersPerKm)
        self.minimumKeyShare = Self.valid(minimumKeyShare, \.minimumKeyShare)
        self.minimumTrimmedSeconds = Self.valid(minimumTrimmedSeconds, \.minimumTrimmedSeconds)
        self.powerHistoryRuns = Self.valid(powerHistoryRuns, \.powerHistoryRuns)
        self.powerHistoryDays = Self.valid(powerHistoryDays, \.powerHistoryDays)
        self.powerHistoryMinimumRuns = Self.valid(powerHistoryMinimumRuns, \.powerHistoryMinimumRuns)
        self.powerToHeartRateDropPercent = Self.valid(powerToHeartRateDropPercent, \.powerToHeartRateDropPercent)
        self.regrowthAtPlanShare = Self.valid(regrowthAtPlanShare, \.regrowthAtPlanShare)
        self.regrowthSnapshotWeeks = Self.valid(regrowthSnapshotWeeks, \.regrowthSnapshotWeeks)
    }

    public static let `default` = AdaptationLimits()

    /// `value` for the limit at `field`, as it is stored (#133): a value that
    /// isn't a finite number, or is below 0, falls back to that limit's
    /// default, so a bad tunable can't crash the engine where it rounds a
    /// limit to a whole number ("Double value cannot be converted to Int") or
    /// turn a rule inside out. Every `Double` limit goes through this, when
    /// the limits are built and whenever one is set. One exception keeps its
    /// documented meaning: a `minimumTrimmedSeconds` of 0 or less, finite,
    /// applies no floor, as before. Finite values at or above 0 are kept as
    /// they are. The fallback reads `default` only for a bad value, and every
    /// default is valid, so building `default` never reads itself.
    static func valid(_ value: Double, _ field: KeyPath<AdaptationLimits, Double>) -> Double {
        guard value.isFinite, value >= 0 || field == \.minimumTrimmedSeconds else { return Self.default[keyPath: field] }
        return value
    }

    /// `value` for the whole-number limit at `field`, as it is stored: below
    /// 0 falls back to the default (#157, as #142 does for `GuardrailLimits`;
    /// before, a negative `holdVolumeDays` crashed the engine, and a negative
    /// margin or count ran its rule inside out), and so does a value above
    /// its `upperBound` (#147). Every whole-number limit goes through this,
    /// when the limits are built and whenever one is set. 0 and every value
    /// up to the bound are kept, with the meaning the engine gives them: a
    /// `longRunQualifyingCount`, `powerHistoryRuns` or `powerHistoryDays` of
    /// 0 switches its rule off (the engine's `> 0` checks), an RPE margin of
    /// 0 counts an RPE at the top of the expected range, a `holdVolumeDays` of
    /// 0 holds nothing, and the windows and counts read through `max(1, ...)`
    /// act as 1.
    static func valid(_ value: Int, _ field: KeyPath<AdaptationLimits, Int>) -> Int {
        value >= 0 && value <= (upperBound(field) ?? .max) ? value : Self.default[keyPath: field]
    }

    /// The input-sanity upper bound of a whole-number limit used in date or
    /// week arithmetic (#147, `LimitBounds`; not a training rule):
    /// `holdVolumeDays` and `powerHistoryDays` 730 days,
    /// `regrowthSnapshotWeeks` 104 weeks. `Int.max` weeks of snapshot
    /// overflowed the engine, and a million-day hold ran it past a minute.
    /// Nil for a count or a margin, which is only compared.
    static func upperBound(_ field: KeyPath<AdaptationLimits, Int>) -> Int? {
        switch field {
        case \AdaptationLimits.holdVolumeDays, \AdaptationLimits.powerHistoryDays: return LimitBounds.days
        case \AdaptationLimits.regrowthSnapshotWeeks: return LimitBounds.weeks
        default: return nil
        }
    }
}

/// What the engine needs to know about the runner, all of it from their own
/// data or the goal interview (nothing hard-coded).
public struct AdaptationContext: Equatable, Sendable {
    /// The runner's current zones (3.2).
    public var zones: HRZones
    public var timeZone: TimeZone
    /// The explicit pain-history flag from the goal interview (F2). It turns
    /// on the pain check-in rule only; the pain stop rule applies to everyone.
    public var tracksPain: Bool
    public var guardrails: GuardrailLimits
    public var painLimits: PainRuleLimits
    public var limits: AdaptationLimits
    /// How paces and distances read in explanations and trigger details
    /// (`UnitPreference`). Only the wording changes; every rule runs in SI units.
    public var units: UnitPreference
    /// The pain stop rule's heuristics (3.5 rule 7). It applies to every
    /// runner, whatever `tracksPain` says.
    public var painStopLimits: PainStopLimits
    /// The usual pain level the runner gave for their pain spot in the goal
    /// interview (F2), 0 to 10: the seed for usual pain (3.5 rule 7) until 3
    /// stable check-ins exist. Runner-entered, never a default; ignored when
    /// `tracksPain` is false (usual is then 0).
    public var usualPainSeed: Int?
    /// The heuristics of rule 7's end path, return and clinician flag.
    public var painRecoveryLimits: PainRecoveryLimits

    public init(zones: HRZones, timeZone: TimeZone, tracksPain: Bool,
                guardrails: GuardrailLimits = .default, painLimits: PainRuleLimits = .default,
                limits: AdaptationLimits = .default, units: UnitPreference = .metric,
                painStopLimits: PainStopLimits = .default, usualPainSeed: Int? = nil,
                painRecoveryLimits: PainRecoveryLimits = .default) {
        self.zones = zones
        self.timeZone = timeZone
        self.tracksPain = tracksPain
        self.guardrails = guardrails
        self.painLimits = painLimits
        self.limits = limits
        self.units = units
        self.painStopLimits = painStopLimits
        self.usualPainSeed = usualPainSeed
        self.painRecoveryLimits = painRecoveryLimits
    }
}

/// A run that just synced, with what the engine can't read from the streams.
public struct CompletedRun: Equatable, Sendable {
    public var activity: Activity
    /// The planned session it was run for, when the app knows. When nil, the
    /// engine matches the planned session on the same day in the runner's time zone.
    public var plannedWorkoutID: String?
    /// RPE 1 to 10 if the runner gave one. Values outside 1...10 are ignored.
    public var rpe: Int?
    /// From the history cleanup (`TreadmillTagger`). Treadmill pace is not
    /// compared with outdoor targets until the treadmill offset (3.8, F8) exists.
    public var isTreadmill: Bool
    /// Kind to log an unplanned run as. Default `.easy`.
    public var unplannedKind: PlannedWorkout.Kind

    public init(activity: Activity, plannedWorkoutID: String? = nil, rpe: Int? = nil, isTreadmill: Bool = false,
                unplannedKind: PlannedWorkout.Kind = .easy) {
        self.activity = activity
        self.plannedWorkoutID = plannedWorkoutID
        self.rpe = rpe
        self.isTreadmill = isTreadmill
        self.unplannedKind = unplannedKind
    }

    public static let validRPE: ClosedRange<Int> = 1...10
}
