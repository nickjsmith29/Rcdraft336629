import Foundation

/// The race distances the plan builder knows (SPEC.md F3: 5K to marathon).
/// Distances in between use the nearest category's heuristics.
public enum RaceCategory: String, CaseIterable, Equatable, Hashable, Sendable {
    case fiveK, tenK, half, marathon

    /// The category for a race distance, or nil outside 5 km to the marathon (1% slack each way).
    public init?(meters: Double) {
        guard meters.isFinite, meters >= Distance.fiveK * 0.99, meters <= Distance.marathon * 1.01 else { return nil }
        switch meters {
        case ..<7_500: self = .fiveK
        case ..<15_000: self = .tenK
        case ..<30_000: self = .half
        default: self = .marathon
        }
    }

    /// Whether a race distance is "a race of marathon distance", the case
    /// SPEC 3.5 rule 5's marathon allowances apply to (the 45% long-run share
    /// ceiling and the 180-minute long-run cap): within
    /// `PlanFormatting.raceNameTolerance` (0.5%, a heuristic) of 42,195 m, the
    /// tolerance race names use. A race from 30 km up to that is category
    /// `.marathon` for F3's other heuristics but is planned with the usual
    /// share and the 150-minute default cap (#30). A nil, NaN or infinite
    /// distance is not marathon distance (the conservative reading).
    public static func isMarathonDistance(meters: Double?) -> Bool {
        guard let m = meters, m.isFinite else { return false }
        return abs(m - Distance.marathon) / Distance.marathon <= PlanFormatting.raceNameTolerance
    }
}

/// The plan builder's tunable numbers (SPEC.md F3). **Every value here is a
/// heuristic**, chosen to sit inside the SPEC 3.1 intensity band and the
/// SPEC 3.5 guardrails with some margin; none is a validated optimum and none
/// stands for a particular runner.
public enum PlanHeuristics {
    // MARK: Phase lengths (F3)

    /// Fewest weeks (race week included) for a periodized plan. Below this the
    /// builder returns `PlanBuildIssue.leadTimeTooShort` rather than squeeze phases.
    public static func minimumWeeks(_ c: RaceCategory) -> Int {
        switch c {
        case .fiveK: return 4
        case .tenK: return 5
        case .half: return 6
        case .marathon: return 8
        }
    }

    /// Longest plan the builder makes, in weeks.
    public static let maximumWeeks = 52

    /// Taper length in weeks, race week included: one recovery week plus the
    /// race week from the 10K up, the race week alone for the 5K. A heuristic.
    /// The guardrails no longer force it short: the race is left out of the
    /// weekly caps (3.5 rule 3, #62), so it needs no room in race week. A
    /// longer marathon taper is a plan-design choice still open.
    public static func taperWeeks(_ c: RaceCategory) -> Int {
        c == .fiveK ? 1 : 2
    }

    /// Most weeks of peak phase.
    public static func maximumPeakWeeks(_ c: RaceCategory) -> Int {
        switch c {
        case .fiveK, .tenK: return 2
        case .half, .marathon: return 3
        }
    }

    /// Most weeks of build phase; the base phase takes every week left over.
    public static func maximumBuildWeeks(_ c: RaceCategory) -> Int {
        switch c {
        case .fiveK: return 4
        case .tenK: return 5
        case .half: return 6
        case .marathon: return 8
        }
    }

    // MARK: Volume (3.5)

    /// How far above the recent weekly volume the peak week aims, as a fraction.
    /// The guardrail ramp and the runner's schedule may stop it lower.
    public static func peakGrowth(_ c: RaceCategory) -> Double {
        switch c {
        case .fiveK: return 0.15
        case .tenK: return 0.20
        case .half: return 0.25
        case .marathon: return 0.35
        }
    }

    /// Training time in the race week (race excluded) as a fraction of the
    /// peak week, before the guardrail cap.
    public static func raceWeekTrainingShare(_ c: RaceCategory) -> Double {
        switch c {
        case .fiveK: return 0.50
        case .tenK: return 0.40
        case .half: return 0.35
        case .marathon: return 0.25
        }
    }

    /// Weekly growth the builder aims for in a build week; kept under the 3.5
    /// limit (and never above 80% of it) so rounding can't break it.
    public static let weeklyGrowth = 0.08
    /// A recovery week's volume as a fraction of the week before; under the
    /// checker's 80% so it is always classed as a recovery week.
    public static let recoveryWeekRatio = 0.75
    /// Growing back after a cut week (SPEC 3.5 rule 6, owner decision Nov 21,
    /// #107): a regrowth week may hold this fraction more than the week
    /// before it as run (or its return step, `regrowthReturnSteps`, if that is
    /// more), and a week counts as cut when going straight back to the
    /// original plan the week after would rise more than this over it (or
    /// break the spike rule, 3.5 rule 1). Heuristic: the owner's value; no
    /// study tests a weekly regrowth rate.
    public static let regrowthMaxWeeklyRise = 0.20
    /// The return steps of a regrowth (SPEC 3.5 rule 6, owner decision Nov
    /// 21, #107): regrowth week `k` after a cut week may hold
    /// `regrowthReturnSteps[k-1]` × its original-plan volume (the last step
    /// from then on) when that is more than `regrowthMaxWeeklyRise` over the
    /// week before, so a week run very short, or missed, comes back in three
    /// weeks rather than by 20% at a time from almost nothing. Heuristic: the
    /// owner's values.
    public static let regrowthReturnSteps = [0.65, 0.825, 1.0]
    /// Planned volumes stay this fraction under each guardrail cap: always
    /// under the weekly caps (3.5 rule 2, the return ramp and recovery
    /// weeks). Under the single-run spike rule (3.5 rule 1, F3) only when a
    /// week is drafted again under its cap: a week drafted without the rule
    /// whose sessions all keep the true 10% limit is kept as it is, so a
    /// session there may come up to the limit itself, still inside 3.5's 5 to
    /// 10% target (`PlanBuilder`, `spikeHolds`).
    public static let guardrailMargin = 0.99
    /// Smallest workable training week: room for a long run, a short quality
    /// session and an easy run. A week the guardrails would hold below this is
    /// refused (`PlanBuildIssue.noWorkableWeek`) rather than left empty.
    public static let minimumWeekSeconds: Double = 60 * 60
    /// Smallest recovery week the guardrails require. In practice the plan
    /// builder plans a sub-hour recovery week as one easy run plus a short
    /// fartlek (at least `minimumEasyRunSeconds` for the run, about 25
    /// minutes for the fartlek session), so weeks it can build are at least
    /// 50 minutes (46 in a marathon plan, with a 20-minute long run); a
    /// smaller one is refused. Lower than
    /// `minimumWeekSeconds` because a recovery week after a small week (for
    /// example on the way back from a break) is 75 to 80% of it.
    public static let minimumRecoveryWeekSeconds: Double = 40 * 60
    /// Smallest recent weekly volume to build a plan from (three 30-minute runs).
    public static let minimumRecentWeeklySeconds: Double = 90 * 60

    // MARK: Sessions

    /// Fewest training days a week.
    public static let minimumTrainingDays = 3
    /// Smallest usable `maxSessionSeconds`: a warm-up, a short quality set and a cool-down.
    public static let minimumSessionSeconds: Double = 40 * 60
    /// A week runs on about one day per this many seconds of volume (at least 3 days).
    public static let secondsPerRunDay: Double = 35 * 60
    /// Shortest easy run worth scheduling; shorter leftovers are merged or dropped.
    public static let minimumEasyRunSeconds: Double = 20 * 60
    /// Shortest quality main set.
    public static let minimumMainSetSeconds: Double = 10 * 60
    /// Shortest warm-up and cool-down a quality session gets, in seconds: a
    /// small week's (under 150 minutes). In a larger week a session whose
    /// main set the session cap (F2, or the spike rule, 3.5 rule 1) holds
    /// too short for the week's hard time gives up only as much of its 15
    /// and 10 minutes as its main set needs, down to these (#105, #113); the
    /// others keep 15 and 10. Heuristics: SPEC.md sets no warm-up or
    /// cool-down length.
    public static let shortWarmUpSeconds: Double = 10 * 60
    public static let shortCoolDownSeconds: Double = 5 * 60
    /// Long-run growth per week (F3), in seconds.
    public static let longRunStepSeconds: Double = 10 * 60

    /// Longest long run for the distance, in seconds. The 180 minutes of SPEC
    /// 3.5 rule 5 apply only at marathon distance (`isMarathonDistance`, from
    /// `RaceCategory.isMarathonDistance(meters:)`); a race from 30 km up to it
    /// gets rule 5's 150-minute default cap (#30).
    public static func longRunCap(_ c: RaceCategory, isMarathonDistance: Bool) -> Double {
        switch c {
        case .fiveK: return 90 * 60
        case .tenK: return 105 * 60
        case .half: return 135 * 60
        case .marathon: return (isMarathonDistance ? 180 : 150) * 60
        }
    }

    /// In a marathon plan, the long run may take more than its usual share
    /// of the week (up to the marathon ceiling of SPEC 3.5 rule 5, with
    /// margin) only to reach this length, in seconds: about 150 minutes, rule
    /// 5's default time cap. A heuristic and the conservative reading of rule
    /// 5, which makes a share above 35% a warning: a higher-volume runner
    /// whose usual share already gives this keeps the usual share.
    public static let marathonLongRunTargetSeconds: Double = 150 * 60

    /// Share of the week the long run aims for, by number of run days. Fewer
    /// days need a bigger long run; all stay under the 35% guardrail (a marathon
    /// plan may go further, `marathonLongRunTargetSeconds`).
    public static func longRunShare(runDays: Int) -> Double {
        switch runDays {
        case ...3: return 0.33
        case 4: return 0.31
        default: return 0.30
        }
    }

    /// Target share of the week's time above the aerobic threshold (3.1 allows 15 to 25%).
    public static func hardShare(_ phase: PlanPhase, recovery: Bool) -> Double {
        if recovery { return 0.17 }
        switch phase {
        case .base: return 0.17
        case .build: return 0.20
        case .peak: return 0.21
        case .taper: return 0.18
        }
    }

    /// The band the builder holds each training week's hard share to: inside
    /// 3.1's 15 to 25% with a point of margin each side.
    public static let hardShareBand: ClosedRange<Double> = 0.16...0.24

    /// Longest share of a long run that may be a steady finish.
    public static let longRunFinishShare = 0.25
}

/// Paces and heart rates for each intensity, from the runner's own data only.
struct TargetModel {
    let zones: HRZones
    let category: RaceCategory
    /// Seconds per km; nil when the input gives no basis.
    let easyPace: Double?
    let thresholdPace: Double?
    let vo2maxPace: Double?
    let racePace: Double?

    /// Pace for an all-out effort lasting `seconds`, from a race anchor by Riegel (3.9).
    static func riegelPace(anchor: RaceEquivalent, seconds: Double) -> Double? {
        let e = RacePredictor.defaultExponent
        guard anchor.distanceMeters > 0, anchor.seconds > 0, seconds > 0 else { return nil }
        let meters = anchor.distanceMeters * pow(seconds / anchor.seconds, 1 / e)
        let pace = seconds / meters * 1000
        return pace.isFinite && pace > 0 ? pace : nil
    }

    /// The same model with other easy, threshold and VO2max paces (the paces
    /// after a break, `ReturnPaceSchedule`); the race pace stays.
    func withPaces(easy: Double?, threshold: Double?, vo2max: Double?) -> TargetModel {
        TargetModel(zones: zones, category: category, easyPace: easy, thresholdPace: threshold, vo2maxPace: vo2max,
                    racePace: racePace)
    }

    func heartRate(_ intensity: WorkoutIntensity) -> HeartRateTarget {
        let z = zones
        func t(_ lo: HRZone, _ hi: HRZone, floor: HRZone?, ceiling: HRZone?) -> HeartRateTarget {
            HeartRateTarget(zones: lo...hi, floorBPM: floor.map { z.lowerBound($0) }, ceilingBPM: ceiling.map { z.lowerBound($0) })
        }
        switch intensity {
        case .recovery: return t(.z1, .z1, floor: nil, ceiling: .z2)
        case .easy, .repRecovery: return t(.z1, .z2, floor: nil, ceiling: .z3)
        case .steady: return t(.z3, .z3, floor: .z3, ceiling: .z4)
        case .threshold: return t(.z4, .z5a, floor: .z4, ceiling: .z5b)
        case .vo2max: return t(.z5b, .z5c, floor: .z5b, ceiling: nil)
        case .racePace, .race:
            switch category {
            case .fiveK: return t(.z5a, .z5b, floor: .z5a, ceiling: .z5c)
            case .tenK: return t(.z5a, .z5a, floor: .z5a, ceiling: .z5b)
            case .half: return t(.z4, .z4, floor: .z4, ceiling: .z5a)
            case .marathon: return t(.z3, .z3, floor: .z3, ceiling: .z4)
            }
        }
    }

    func pace(_ intensity: WorkoutIntensity) -> PaceTarget? {
        func range(_ base: Double?, _ fast: Double, _ slow: Double) -> PaceTarget? {
            base.map { PaceTarget(fastestSecondsPerKm: $0 * fast, slowestSecondsPerKm: $0 * slow) }
        }
        switch intensity {
        case .easy: return range(easyPace, 1.00, 1.12)
        case .recovery: return range(easyPace, 1.05, 1.20)
        case .repRecovery: return nil
        case .steady: return range(thresholdPace, 1.06, 1.12)
        case .threshold: return range(thresholdPace, 0.99, 1.02)
        case .vo2max: return range(vo2maxPace, 0.98, 1.01)
        case .racePace, .race: return range(racePace, 0.99, 1.01)
        }
    }

    func target(_ intensity: WorkoutIntensity) -> WorkoutTarget {
        let pace = pace(intensity)
        // Easy running is governed by heart rate (3.1); harder work by pace when known.
        let primary: WorkoutTarget.Primary
        switch intensity {
        case .recovery, .easy, .repRecovery, .steady: primary = .heartRate
        default: primary = pace == nil ? .heartRate : .pace
        }
        return WorkoutTarget(heartRate: heartRate(intensity), pace: pace, primary: primary)
    }
}
