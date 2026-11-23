import Foundation

/// One week of a generated plan.
public struct TrainingPlanWeek: Equatable, Sendable {
    /// 0 for the plan's first week.
    public let index: Int
    /// Monday 00:00 in the runner's time zone (`PlanCalendar`).
    public let weekStart: Date
    public let phase: PlanPhase
    /// True when the 3.5 checker counts this week as a recovery week (volume
    /// at most `recoveryWeekMaxRatio` of the week before).
    public let isRecoveryWeek: Bool
    public let isRaceWeek: Bool
    /// The week's sessions in date order, the race included in race week.
    public let workouts: [PlannedWorkout]

    public init(index: Int, weekStart: Date, phase: PlanPhase, isRecoveryWeek: Bool, isRaceWeek: Bool,
                workouts: [PlannedWorkout]) {
        self.index = index
        self.weekStart = weekStart
        self.phase = phase
        self.isRecoveryWeek = isRecoveryWeek
        self.isRaceWeek = isRaceWeek
        self.workouts = workouts.sorted { $0.date < $1.date }
    }

    /// Training time in seconds: every session but the race.
    public var trainingSeconds: Double {
        workouts.filter { $0.kind != .race }.reduce(0) { $0 + $1.durationSeconds }
    }

    /// Training time below the aerobic threshold (warm-ups, cool-downs, easy
    /// and long running), from the sessions' segments. A session without a
    /// prescription counts as not easy.
    public var easySeconds: Double {
        workouts.filter { $0.kind != .race }.reduce(0) { $0 + ($1.prescription?.easySeconds ?? 0) }
    }

    /// The share of training time that is easy (SPEC 3.1 asks for about 75 to
    /// 85%), or nil for a week with no training. The race is left out: it is
    /// not training, and a marathon would swamp its week.
    public var easyShare: Double? {
        let total = trainingSeconds
        return total > 0 ? easySeconds / total : nil
    }
}

/// A periodized plan to the goal race (SPEC.md F3).
public struct TrainingPlan: Equatable, Sendable {
    public let category: RaceCategory
    public let weeks: [TrainingPlanWeek]
    /// The duration planned for the race, in seconds: the slower of the goal
    /// and the prediction, or an easy-pace bound when neither is known.
    public let raceSeconds: Double
    /// The 3.5 checker's report on the plan with the history it was given.
    /// It always passes (a failing plan is returned as an issue instead);
    /// `notEvaluated` lists the checks the history was too short for, and
    /// `informationFlags` a race longer than the 30-day longest run (3.5
    /// rules 1 and 3) and, in a marathon plan, a long run above the usual
    /// share of the week (3.5 rule 5), which are shown but never block.
    public let guardrailReport: GuardrailReport
    /// Plain-English notes on what the plan could not use or had to limit.
    public let notes: [String]
    /// When the plan is **provisional**, the moment to rebuild it: the start
    /// of the plan's first Monday in the runner's time zone. Nil for a final
    /// plan.
    ///
    /// A plan is provisional when it was built after its start week had
    /// begun (a mid-week start, or a Monday after noon or after a logged
    /// run). That week is still open, so the plan is sized to keep SPEC 3.5
    /// however the week ends (#48), which keeps its first weeks, and through
    /// the 10% and rolling 4-week rules often its whole build, below what the
    /// finished week would allow. **The app must rebuild the plan on this
    /// date** (a fresh baseline and `PlanBuilder.build`, or
    /// `GoalPlanner.plan`, with that moment as the start): the start week is
    /// then closed history and the rebuilt plan is final.
    ///
    /// **A late rebuild must still pass `rebuildDate` as `today`** (the
    /// build's `startDate`), with the baseline and history as of that moment,
    /// not the moment the app gets to it. A plan starts in its start's own
    /// week only from a Monday at or before noon with nothing logged that day
    /// (`PlanBuilder.build`). Rebuilt from "now" after an early-Monday run,
    /// or after noon, the plan would start on the next Monday and leave this
    /// week open, so the rebuild would come back provisional again. From
    /// `rebuildDate` (00:00 Monday) the start week is closed and nothing in
    /// the new week is history yet; runs logged since then fall in the
    /// rebuilt plan's first week, like any run of a plan. This holds through
    /// the plan's first week; `ProvisionalRebuild.due` gives the `today` to
    /// pass (the latest Monday, after a whole week missed) and keeps the
    /// provisional plan, with a retry, when a rebuild is refused (#55).
    public let rebuildDate: Date?

    /// True when the plan must be rebuilt on `rebuildDate`.
    public var isProvisional: Bool { rebuildDate != nil }

    public init(category: RaceCategory, weeks: [TrainingPlanWeek], raceSeconds: Double,
                guardrailReport: GuardrailReport, notes: [String], rebuildDate: Date? = nil) {
        self.category = category
        self.weeks = weeks
        self.raceSeconds = raceSeconds
        self.guardrailReport = guardrailReport
        self.notes = notes
        self.rebuildDate = rebuildDate
    }

    /// Every session in date order.
    public var workouts: [PlannedWorkout] { weeks.flatMap(\.workouts) }
}

/// Why no plan was built. The builder never guesses past these.
public enum PlanBuildIssue: Equatable, Sendable {
    case unsupportedRaceDistance(meters: Double)
    case raceNotAfterStart
    case leadTimeTooShort(weeksAvailable: Int, minimumWeeks: Int)
    case leadTimeTooLong(weeksAvailable: Int, maximumWeeks: Int)
    /// No recent weekly volume: the baseline has too little history.
    case missingRecentVolume
    case recentVolumeTooLow(seconds: Double, minimumSeconds: Double)
    /// No LTHR yet: the app schedules a field test first (cold start, SPEC 2, 3.2).
    case missingHeartRateZones
    case tooFewTrainingDays(available: Int, minimum: Int)
    case longRunDayNotATrainingDay
    case maxSessionTooShort(seconds: Double, minimumSeconds: Double)
    /// A value is NaN, infinite, non-positive or implausible.
    case invalidValue(PlanInput.Field)
    /// No goal, prediction or easy pace, so the race's duration can't be
    /// bounded (the race session, and the recovery cadence of 3.5, which
    /// counts it, need one).
    case raceDurationUnknown
    /// The builder plans in time and needs room for at least one quality session.
    case unsupportedLimits(String)
    /// Even with no other running, the race week would break the guardrails:
    /// the cadence requires race week to be a recovery week (the 5K's race
    /// week, or after the most build weeks in a row 3.5 allows), which counts
    /// the race, and the race is longer than that recovery week may be. The
    /// weekly caps leave the race out (3.5 rule 3), so they never cause this.
    case volumeTooLowForRace(raceSeconds: Double, allowedRaceWeekSeconds: Double)
    /// `recentWeeklySeconds` is well above what the history shows for the last
    /// complete weeks (more than 1.5 times, and more than an hour above, the
    /// history's mean). The baseline and the history must describe the same
    /// running, or the guardrails computed from the history collapse the plan.
    case recentVolumeDisagreesWithHistory(recentWeeklySeconds: Double, historyWeeklySeconds: Double)
    /// The week before the plan rests on a week of unknown volume (a session
    /// with no valid duration) with nothing in it of known time (#40), so
    /// either the plan's first week would have to be a recovery week, which
    /// is measured against a known volume, because the history already has
    /// the most build weeks in a row that 3.5 allows; or its 10% reference
    /// may truly be almost nothing, so it is allowed no volume. Build the plan
    /// on `rebuildOn`, the Monday after the plan's first week: that week, once
    /// run, is a week of known volume to measure against.
    case historyVolumeUnknown(rebuildOn: Date)
    /// The start's week is still open (a mid-week start) and no first week is
    /// safe until it is over (#48, #40): nothing is logged in it yet and the
    /// week before has no known volume (no history, a week off, or a session
    /// with no valid duration), so any run still to come this week would be
    /// the first plan week's 10% reference, however short; or the week before
    /// it has unknown volume; or the start week itself holds a session with
    /// no valid duration and what it holds so far leaves no workable first
    /// week. Build the plan on `rebuildOn`, the start of the next Monday,
    /// once this week is done.
    case startWeekWithoutReference(rebuildOn: Date)
    /// The guardrails, applied to the history and the weeks before, leave
    /// less than a workable week for this week: under
    /// `PlanHeuristics.minimumWeekSeconds` for a training week, or under
    /// `PlanHeuristics.minimumRecoveryWeekSeconds` for a recovery week the
    /// build streak requires. Two usual causes:
    /// - Right after a break of 3 weeks or more, the rolling 4-week rule can
    ///   leave too little room; a later start lets that window move past the
    ///   break. After a short break (1 or 2 weeks, 3.5 rule 4) the rolling
    ///   rule counts the break weeks at the pre-break level instead, and the
    ///   return ramp sets the first weeks back.
    /// - A required recovery week after a very small week (80% of it is under
    ///   the recovery floor). A later race doesn't help; a fuller week, or a
    ///   recovery week already in the history, does.
    case noWorkableWeek(weekStart: Date, allowedSeconds: Double)
    /// No arrangement of this week's sessions keeps 75 to 85% of its time
    /// easy (3.1) within the schedule, for example with a short session cap.
    case intensityDistributionNotMet(weekStart: Date, easyShare: Double)
    /// The generated plan broke a guardrail with the history given. Not
    /// expected; it is a safety net, not a normal outcome.
    case failsGuardrails(GuardrailReport)
}

public enum PlanBuildResult: Equatable, Sendable {
    case plan(TrainingPlan)
    case cannotBuild([PlanBuildIssue])

    public var plan: TrainingPlan? {
        if case .plan(let p) = self { return p }
        return nil
    }

    public var issues: [PlanBuildIssue] {
        if case .cannotBuild(let i) = self { return i }
        return []
    }

    /// When the plan is provisional, the date the app must rebuild it on
    /// (`TrainingPlan.rebuildDate`); nil for a final plan or no plan. A late
    /// rebuild must still pass this date as the start, not the moment of the
    /// rebuild: from a later moment, an early-Monday run or the time of day
    /// would make the rebuilt plan provisional again
    /// (`TrainingPlan.rebuildDate`, `ProvisionalRebuild`).
    public var rebuildDate: Date? { plan?.rebuildDate }
}

/// Builds a periodized plan (base, build, peak, taper) from the baseline and
/// the goal (SPEC.md F3), following 3.1 (intensity distribution), 3.2 (zones)
/// and 3.5 (guardrails). All numbers it uses are in `PlanHeuristics`.
///
/// How a plan is made:
/// - **Weeks.** The plan starts on the Monday on or after `startDate` and ends
///   with the race week (the week holding `raceDate`). Phase lengths follow
///   `PlanHeuristics`: a fixed taper, then peak and build capped by distance,
///   with the base taking the rest.
/// - **Volume.** Weekly time starts at the recent level, grows about 8% a build
///   week toward a peak target (recent volume plus a distance-based margin),
///   and holds there. The race needs no room of its own: the weekly caps
///   leave it out (3.5 rule 3, #62). Recovery
///   weeks (75% of the week before) are placed so no more than
///   `maxConsecutiveBuildWeeks` build weeks run in a row, counting the history,
///   and so the taper's first week is one. Each week also stays under the 10%
///   (or, after a short break, return-ramp, 3.5 rule 4) and 4-week caps
///   computed exactly as the checker does from the realized
///   history and earlier plan weeks, and, after a mid-week start, under every
///   way the still-open start week can end (#48, see `build`).
/// - **Sessions.** A long run (about 30 to 33% of the week, growing at most 10
///   minutes a week; in a marathon plan up to the marathon ceiling of 3.5
///   rule 5 with margin, but only toward `PlanHeuristics.marathonLongRunTargetSeconds`),
///   up to two quality sessions on non-consecutive days away
///   from the long run, and easy runs for the rest. Quality main sets are sized
///   so 16 to 24% of the week is above the aerobic threshold (3.1); a steady
///   finish on the long run tops it up when the quality caps are reached.
///   When a session cap (F2, or the spike rule) still holds the main sets too
///   short, the warm-up and cool-down of each session the cap holds shrink as
///   far as its main set needs, to 10 and 5 minutes at most (#113), and a week
///   held to short sessions counts the run days the cap forces when it sets
///   its quality sessions (#105). The week is shortened only if even that is
///   not enough (a known gap: a recovery week's one quality session under a
///   tight spike cap). Whole-minute reps can
///   leave a small week's hard time a little short of what was asked; then
///   more is asked for before the week is shortened (`composeWeek`, #87).
///   Week 1 back after a short break is all easy (no quality session, no
///   steady finish) and week 2 holds at most one quality session (3.5 rule
///   4). No session is more than 10% longer than the longest run of the 30
///   days before it (the single-run spike rule, 3.5 rule 1), so long runs
///   grow by the smaller of 10 minutes and that. Each week is drafted as it
///   would be without the rule first and kept when every session keeps the
///   true 10% limit (`spikeHolds`, no margin); only a week with a session too
///   long for it is drafted again, under a cap of about 9% (`spikeCap`, with
///   `guardrailMargin`). So where the rule never binds the plan is unchanged
///   by it, and nothing else in the drafting depends on whether it bound
///   earlier (#87).
///   With no run of known time in the 30 days (no history yet), the first
///   week keeps its volume and is reshaped so each run is within that of the
///   longest earlier in the week, opening with an easy run rather than the
///   quality session when that keeps more of it (`holdTogether`); a recent
///   long run, when given, caps every session of that week at about 9% over it.
/// - **Targets.** Heart rate from the runner's zones for every segment; pace
///   (grade-adjusted) from the easy-pace sample, the fitness anchor (Riegel,
///   3.9) and the goal or prediction, only when given.
/// - **Check.** The finished plan runs through `GuardrailChecker` with the
///   history; a failure comes back as `PlanBuildIssue.failsGuardrails`.
public enum PlanBuilder {
    /// - Parameters:
    ///   - input: goal, schedule and baseline values.
    ///   - history: completed sessions; those before `startDate` set the
    ///     guardrail context (week-over-week reference, rolling 4 weeks, weeks
    ///     since the last recovery week) and are passed to the checker with the
    ///     plan. Later ones are ignored.
    ///
    ///     The plan's first week is the start's own week only when the start is
    ///     a Monday at or before that day's session time (noon) with nothing
    ///     logged that day. Otherwise, as for any mid-week start, the plan
    ///     begins on the next Monday and the start's week, its runs included,
    ///     is history.
    ///
    ///     That start week is still open: the runner may log more runs in it
    ///     after the plan is built, and the checker will then read the real
    ///     week with the plan (#48). So the builder does not take its volume
    ///     so far as final. It sizes the plan for the worst way the week can
    ///     still end (`PlanBuilder.ledgers`), so that the history plus the plan
    ///     keeps SPEC 3.5:
    ///     - **for any runs added**, for the recovery-week cadence and the 10%
    ///       rule: the week is counted as a build week, and the plan's first
    ///       week is held to 10% over the smallest reference the finished
    ///       week can give;
    ///     - **for any runs that keep the week itself within 3.5**, for the
    ///       rolling 4-week rule (a heuristic bound): the week is counted at
    ///       the most 3.5 allows it after the weeks before or, when those
    ///       weeks set no limit, at `recentWeeklySeconds` plus the weekly
    ///       limit. No plan is safe against an unbounded week, and a week past
    ///       3.5 is the runner's own break of it, which F4 adapts to.
    ///     This holds with no history at all too: the start week is then an
    ///     empty open week (`PlanBuildIssue.startWeekWithoutReference`).
    ///
    ///     Such a plan is **provisional** (`TrainingPlan.rebuildDate`): the
    ///     app must rebuild it at the start of its first Monday, when the start
    ///     week is closed history and the guardrails no longer have to cover
    ///     every way it could end.
    ///   - timeZone: the runner's time zone, for weeks and days.
    ///   - limits: guardrail limits; volume must be measured in time.
    public static func build(_ input: PlanInput,
                             history: [PlannedWorkout] = [],
                             timeZone: TimeZone,
                             limits: GuardrailLimits = .default) -> PlanBuildResult {
        // No diagnostics in production: they draft each week once more (#113).
        buildDiagnosed(input, history: history, timeZone: timeZone, limits: limits, diagnose: false).result
    }

    /// What the builder asked of one training week and what it drafted, for
    /// tests (#105): the week's volume after the guardrail caps (`desired`),
    /// the volume drafted, and whether the single-run spike rule (3.5 rule 1)
    /// bound the week's sessions.
    struct WeekVolumeDiagnostic: Equatable {
        let index: Int
        /// Weekly volume asked for after the weekly caps (3.5 rule 2, the
        /// return ramp, recovery weeks), seconds.
        let desired: Double
        /// Training time drafted, seconds.
        let realized: Double
        let recovery: Bool
        /// True when the week was drafted again under the spike cap (`spikeHolds`).
        let spikeBound: Bool
        /// Longest any session of the week may be: the max session length
        /// (F2) and, when `spikeBound`, the spike cap.
        let sessionCap: Double
        let dayCount: Int
        /// Most quality sessions the week may hold.
        let maxQuality: Int
        /// The most the week's sessions hold when drafted at `desired` with
        /// every main set and steady finish at its most, seconds: under
        /// `desired` when the session caps (F2, the spike rule) and the long
        /// run's limits (3.5 rule 5, F3) leave its days too little room.
        let capacity: Double
        /// True when the week's sessions, at the desired volume and under
        /// their caps (the session cap and each quality session's main-set
        /// cap), can hold the bottom of the 3.1 band of hard time, with the
        /// warm-ups and cool-downs at their shortest and every quality
        /// session and steady finish at its most. When false, the week can
        /// only reach the band shorter than `desired` (#105).
        let bandReachable: Bool
    }

    /// `build`, with each training week's `WeekVolumeDiagnostic` (empty when
    /// no week was drafted, or when `diagnose` is false, as in `build`).
    /// `shortenWarmUps: false` (tests only) keeps every quality session of a
    /// week of 150 minutes or more at the usual 15-min warm-up and 10-min
    /// cool-down, to compare against (#113).
    static func buildDiagnosed(_ input: PlanInput, history: [PlannedWorkout] = [], timeZone: TimeZone,
                               limits: GuardrailLimits = .default, diagnose: Bool = true,
                               shortenWarmUps: Bool = true)
        -> (result: PlanBuildResult, weeks: [WeekVolumeDiagnostic]) {
        let validated: Validated
        // Everything done before the start counts, including runs earlier on
        // the start day; sessions dated later are not history yet.
        let past = history.filter { $0.date < input.startDate }
        switch validate(input, history: past, timeZone: timeZone, limits: limits) {
        case .failure(let issues): return (.cannotBuild(issues.list), [])
        case .success(let v): validated = v
        }
        var builder = Builder(input: input, v: validated, timeZone: timeZone, limits: limits, history: past)
        builder.diagnose = diagnose
        builder.shortenWarmUps = shortenWarmUps
        // An open start week with a session of unknown time (#40) is only known
        // to hold what was logged so far, which can leave no workable first
        // week. Once it is over, all of its other runs count: build then.
        let openUnknown = builder.startWeekOpen && builder.ledger.lastUnknown
        let result = builder.run()
        if openUnknown, case .cannotBuild(let issues) = result,
           issues.contains(where: { issue in
               if case .noWorkableWeek(let week, _) = issue { return week == validated.firstMonday }
               return false
           }) {
            return (.cannotBuild([.startWeekWithoutReference(rebuildOn: validated.firstMonday)]), builder.diagnostics)
        }
        return (result, builder.diagnostics)
    }

    // MARK: - Validation

    struct IssueList: Error { var list: [PlanBuildIssue] }

    struct Validated {
        let category: RaceCategory
        let firstMonday: Date
        let weekStarts: [Date]
        let zones: HRZones
        let recentWeekly: Double
        let raceSeconds: Double
        let targets: TargetModel
        let notes: [String]
    }

    static func positive(_ x: Double?) -> Bool { x.map { $0.isFinite && $0 > 0 } ?? true }

    static func validate(_ input: PlanInput, history: [PlannedWorkout], timeZone: TimeZone,
                         limits: GuardrailLimits) -> Result<Validated, IssueList> {
        var issues: [PlanBuildIssue] = []
        var notes: [String] = []

        if limits.measure != .time {
            issues.append(.unsupportedLimits("the plan builder plans weekly volume in time; distances are not planned"))
        }
        if limits.maxQualitySessionsPerWeek < 1 {
            issues.append(.unsupportedLimits("the limits allow no quality session, so SPEC 3.1's threshold and VO2max share can't be planned"))
        }

        let category = RaceCategory(meters: input.raceDistanceMeters)
        if category == nil {
            issues.append(input.raceDistanceMeters.isFinite && input.raceDistanceMeters > 0
                          ? .unsupportedRaceDistance(meters: input.raceDistanceMeters)
                          : .invalidValue(.raceDistanceMeters))
        }
        // A goal or prediction must be a positive time at a plausible average
        // speed for the distance (BlendedPredictor.plausibleSpeed, 1 to 7.5 m/s).
        func plausibleTime(_ t: Double?) -> Bool {
            guard let t else { return true }
            guard t.isFinite, t > 0 else { return false }
            // Speed is only judged for a supported distance; another one is already refused.
            guard category != nil else { return true }
            return BlendedPredictor.plausibleSpeed.contains(input.raceDistanceMeters / t)
        }
        if !plausibleTime(input.goalSeconds) { issues.append(.invalidValue(.goalSeconds)) }
        if !plausibleTime(input.predictedRaceSeconds) { issues.append(.invalidValue(.predictedRaceSeconds)) }
        if !positive(input.recentLongRunSeconds) { issues.append(.invalidValue(.recentLongRunSeconds)) }
        if let m = input.maxSessionSeconds {
            if !(m.isFinite && m > 0) {
                issues.append(.invalidValue(.maxSessionSeconds))
            } else if m < PlanHeuristics.minimumSessionSeconds {
                issues.append(.maxSessionTooShort(seconds: m, minimumSeconds: PlanHeuristics.minimumSessionSeconds))
            }
        }
        if let e = input.easyPace {
            // Plausible ranges: 2:00 to 20:00 per km, 50 to 220 bpm.
            let okPace = e.secondsPerKm.isFinite && (120.0...1200.0).contains(e.secondsPerKm)
            let okHR = e.heartRate.isFinite && (50.0...220.0).contains(e.heartRate)
            if !(okPace && okHR) { issues.append(.invalidValue(.easyPace)) }
        }
        if let a = input.fitnessAnchor {
            let okDistance = a.distanceMeters.isFinite && BlendedPredictor.riegelEffortMeters.contains(a.distanceMeters)
            let okTime = a.seconds.isFinite && a.seconds > 0
            let okSpeed = okDistance && okTime && BlendedPredictor.plausibleSpeed.contains(a.distanceMeters / a.seconds)
            if !okSpeed { issues.append(.invalidValue(.fitnessAnchor)) }
        }

        // Volume (F1 baseline).
        var recentWeekly = 0.0
        if let r = input.recentWeeklySeconds {
            if !(r.isFinite && r >= 0) {
                issues.append(.invalidValue(.recentWeeklySeconds))
            } else if r < PlanHeuristics.minimumRecentWeeklySeconds {
                issues.append(.recentVolumeTooLow(seconds: r, minimumSeconds: PlanHeuristics.minimumRecentWeeklySeconds))
            } else {
                recentWeekly = r
            }
        } else {
            issues.append(.missingRecentVolume)
        }
        if input.heartRateZones == nil { issues.append(.missingHeartRateZones) }

        // Schedule (F2).
        if input.trainingDays.count < PlanHeuristics.minimumTrainingDays {
            issues.append(.tooFewTrainingDays(available: input.trainingDays.count, minimum: PlanHeuristics.minimumTrainingDays))
        }
        if !input.trainingDays.contains(input.longRunDay) { issues.append(.longRunDayNotATrainingDay) }

        // Weeks.
        let cal = PlanCalendar.calendar(timeZone: timeZone)
        let startWeek = PlanCalendar.weekStart(containing: input.startDate, timeZone: timeZone)
        // A Monday start keeps its week only while Monday is still open: no
        // later than its session time (noon) and nothing logged that day.
        let mondayNoon = cal.date(bySettingHour: 12, minute: 0, second: 0, of: startWeek) ?? startWeek.addingTimeInterval(12 * 3600)
        let mondayOpen = cal.startOfDay(for: input.startDate) == startWeek && input.startDate <= mondayNoon
            && !history.contains { $0.date >= startWeek }
        let firstMonday = mondayOpen ? startWeek : PlanCalendar.nextWeekStart(after: startWeek, timeZone: timeZone)
        var weekStarts: [Date] = []
        if !(input.raceDate > input.startDate) {
            issues.append(.raceNotAfterStart)
        } else {
            let raceWeek = PlanCalendar.weekStart(containing: input.raceDate, timeZone: timeZone)
            var w = firstMonday
            while w <= raceWeek && weekStarts.count <= PlanHeuristics.maximumWeeks {
                weekStarts.append(w)
                w = PlanCalendar.nextWeekStart(after: w, timeZone: timeZone)
            }
            if let c = category {
                if weekStarts.count > PlanHeuristics.maximumWeeks {
                    issues.append(.leadTimeTooLong(weeksAvailable: weekStarts.count, maximumWeeks: PlanHeuristics.maximumWeeks))
                } else if weekStarts.count < PlanHeuristics.minimumWeeks(c) {
                    issues.append(.leadTimeTooShort(weeksAvailable: weekStarts.count, minimumWeeks: PlanHeuristics.minimumWeeks(c)))
                }
            }
        }

        guard issues.isEmpty, let c = category, let zones = input.heartRateZones else {
            return .failure(IssueList(list: issues))
        }

        // Paces, from the runner's data only.
        var easyPace = input.easyPace?.secondsPerKm
        if let e = input.easyPace, e.heartRate >= zones.easyCeiling {
            easyPace = nil
            notes.append("Your easy-pace sample was run at \(Int(e.heartRate.rounded())) bpm, above zone 2 (from \(Int(zones.easyCeiling.rounded())) bpm), so easy runs have heart-rate targets only until easier runs give a true easy pace (SPEC 2, 3.1).")
        }
        let anchor = input.fitnessAnchor
        let thresholdPace = anchor.flatMap { TargetModel.riegelPace(anchor: $0, seconds: 3600) }
        let vo2Pace = anchor.flatMap { TargetModel.riegelPace(anchor: $0, seconds: 720) }
        if anchor == nil {
            notes.append("No recent race or prediction to anchor training paces, so threshold and VO2max sessions use heart-rate targets until a race or field test gives one (SPEC 3.2, 3.9).")
        }
        let distance = input.raceDistanceMeters
        var predicted = input.predictedRaceSeconds
        // Only a pace bound for the goal, never the race's planned duration.
        var optimisticBound: Double?
        if predicted == nil, let a = anchor {
            if distance <= BlendedPredictor.shortTargetLimit {
                predicted = RacePredictor.riegel(knownMeters: a.distanceMeters, knownSeconds: a.seconds, targetMeters: distance)
            } else {
                let isMarathon = RaceCategory.isMarathonDistance(meters: distance)
                // Marathon (3.9; Vickers-Vertosick predicts a marathon time, so only
                // at marathon distance, #30): Vickers-Vertosick from the anchor and weekly miles,
                // the miles estimated from weekly time at easy pace. Easy pace is
                // slower than average training pace, so this underestimates miles
                // and errs slow.
                if isMarathon, let e = easyPace {
                    let miles = recentWeekly / e / Distance.mile * 1000
                    predicted = VickersVertosick.marathonSeconds(raceMeters: a.distanceMeters, raceSeconds: a.seconds,
                                                                weeklyMiles: miles)
                }
                if predicted == nil {
                    // Plain Riegel flatters marathons (3.9), so it is used only to
                    // bound the goal pace, which makes the 3% cap lenient, not strict.
                    optimisticBound = RacePredictor.riegel(knownMeters: a.distanceMeters, knownSeconds: a.seconds,
                                                           targetMeters: distance)
                    notes.append(isMarathon ? "No marathon prediction could be made (it needs predictedRaceSeconds, or an anchor from 5K to the half marathon and an easy pace), so race pace is only held back from a goal far faster than plain Riegel suggests."
                                 : "No race-time prediction is made for this distance (predictions cover up to the half marathon and the marathon), so race pace is only held back from a goal far faster than plain Riegel suggests.")
                }
            }
        }
        let goalPace = input.goalSeconds.map { $0 / distance * 1000 }
        let predictedPace = (predicted ?? optimisticBound).map { $0 / distance * 1000 }
        var racePace: Double?
        switch (goalPace, predictedPace) {
        case let (g?, p?):
            // Heuristic: train at most 3% faster than current fitness; F4 moves
            // paces as fitness changes.
            racePace = max(g, p * 0.97)
            if g < p * 0.97 {
                notes.append("Your goal pace is more than 3% faster than your current predicted pace, so race-pace sessions start 3% faster than the prediction and move as your fitness does (F4).")
            }
        case let (g?, nil): racePace = g
        case let (nil, p?): racePace = p
        case (nil, nil): racePace = nil
        }

        // Race duration: the slower of goal and prediction.
        let raceSeconds: Double
        if let r = [input.goalSeconds, predicted].compactMap({ $0 }).max() {
            raceSeconds = r
        } else if let e = input.easyPace?.secondsPerKm {
            // Upper bound: a race is never slower than easy pace.
            raceSeconds = e * distance / 1000
            notes.append("With no goal time or prediction, the race is planned at its easy-pace duration, an upper bound.")
        } else {
            return .failure(IssueList(list: [.raceDurationUnknown]))
        }

        if firstMonday > input.startDate {
            notes.append("The plan starts on Monday \(PlanFormatting.day(firstMonday, timeZone: timeZone)) so its first week is a whole week.")
        }

        let targets = TargetModel(zones: zones, category: c, easyPace: easyPace, thresholdPace: thresholdPace,
                                  vo2maxPace: vo2Pace, racePace: racePace)
        return .success(Validated(category: c, firstMonday: firstMonday, weekStarts: weekStarts, zones: zones,
                                  recentWeekly: recentWeekly, raceSeconds: raceSeconds, targets: targets, notes: notes))
    }

    // MARK: - Guardrail mirror

    /// Weekly volumes of the timeline so far, read exactly as `GuardrailChecker`
    /// reads them, so each new week can be held under its caps.
    ///
    /// Two series (SPEC 3.5 rule 3, #62): `volumes` is each week's whole
    /// volume, which the recovery-week cadence counts; `outside` is its volume
    /// outside races, which the weekly caps measure (the 10% rule, the rolling
    /// 4 weeks and the return ramp after a short break, 3.5 rule 4). They
    /// differ only in a week with a race. Breaks are found in `outside` as
    /// the checker finds them (`GuardrailChecker.breaks`).
    struct LoadLedger {
        var volumes: [Double?]
        let limits: GuardrailLimits
        /// A week counted as a build week whatever its volume, in the recovery
        /// cadence. It stands for any volume just above `volumes[buildWeek]`.
        /// Used for the open start week (`PlanBuilder.ledgers`).
        var buildWeek: Int?
        /// Known part of each week's volume (`PlanWeek.knownVolume`): a lower
        /// bound of the true volume where `volumes` is nil (#40).
        var lows: [Double]
        /// Each week's volume outside races and its known part (3.5 rule 3).
        var outside: [Double?]
        var outsideLows: [Double]
        /// Weeks holding a race (never a break week, 3.5 rule 4).
        var raceWeeks: Set<Int>
        /// As `buildWeek`, for the 10% rule's step back past a recovery week
        /// over `outside`: a 10% reference of 0 there allows nothing (an
        /// arbitrarily small week may stand there), not everything.
        var outsideBuildWeek: Int?
        /// A week counted as no break week whatever its volume: the open start
        /// week just over the break line (`PlanBuilder.ledgers`).
        var notBreakWeek: Int?

        /// `outside` defaults to `volumes` (no races), and then
        /// `outsideBuildWeek` to `buildWeek`. Missing `lows` entries count as
        /// the week's volume, or 0 when it is unknown.
        init(volumes: [Double?], limits: GuardrailLimits, buildWeek: Int? = nil, lows: [Double] = [],
             outside: [Double?]? = nil, outsideLows: [Double]? = nil, raceWeeks: Set<Int> = [],
             outsideBuildWeek: Int? = nil, notBreakWeek: Int? = nil) {
            func padded(_ l: [Double], _ v: [Double?]) -> [Double] {
                Array(l.prefix(v.count)) + v.dropFirst(min(l.count, v.count)).map { $0 ?? 0 }
            }
            self.volumes = volumes
            self.limits = limits
            self.buildWeek = buildWeek
            self.lows = padded(lows, volumes)
            let out = outside ?? volumes
            self.outside = out
            self.outsideLows = padded(outsideLows ?? (outside == nil ? lows : []), out)
            self.raceWeeks = raceWeeks
            self.outsideBuildWeek = outsideBuildWeek ?? (outside == nil ? buildWeek : nil)
            self.notBreakWeek = notBreakWeek
        }

        var last: Double? { volumes.last.flatMap { $0 } }

        /// Week `j`'s volume, or its known lower bound when unknown.
        func low(_ j: Int) -> Double { volumes[j] ?? (j < lows.count ? max(0, lows[j]) : 0) }
        /// Week `j`'s volume outside races, or its known lower bound.
        func outsideLow(_ j: Int) -> Double { outside[j] ?? (j < outsideLows.count ? max(0, outsideLows[j]) : 0) }
        /// The last week's volume or lower bound.
        var lastLow: Double? { volumes.isEmpty ? nil : low(volumes.count - 1) }

        /// The checker's breaks (3.5 rule 4).
        var breaks: [LoadBreak] {
            GuardrailChecker.breaks(volumes: outside, lows: outsideLows, raceWeeks: raceWeeks, notBreak: notBreakWeek,
                                    limits: limits)
        }

        /// The checker's recovery-week test. Unlike the checker it has **no
        /// floating-point tolerance, on purpose**: a week this calls a recovery
        /// week the checker does too, so the builder's view is never looser.
        func isRecovery(_ j: Int) -> Bool {
            guard j >= 0, j < volumes.count, let v = volumes[j] else { return false }
            if j == buildWeek { return false }
            if v == 0 { return true }
            // After an unknown week, only a week that is a recovery week for
            // every volume it may truly have held (#40).
            guard j >= 1 else { return false }
            let prev = low(j - 1)
            guard prev > 0 else { return false }
            return v <= limits.recoveryWeekMaxRatio * prev
        }

        /// `isRecovery` over the volume outside races, for the 10% rule's step back.
        func isOutsideRecovery(_ j: Int) -> Bool {
            guard j >= 0, j < outside.count, let v = outside[j] else { return false }
            if j == outsideBuildWeek { return false }
            if v == 0 { return true }
            guard j >= 1 else { return false }
            let prev = outsideLow(j - 1)
            guard prev > 0 else { return false }
            return v <= limits.recoveryWeekMaxRatio * prev
        }

        /// Non-recovery weeks in a row at the end. An unknown week counts as a
        /// build week, as the checker counts it (#40).
        var streak: Int {
            var s = 0
            for j in volumes.indices {
                s = isRecovery(j) ? 0 : s + 1
            }
            return s
        }

        /// The return-ramp cap on the next week, when it is a week of the ramp
        /// after a short break (3.5 rule 4); it replaces the 10% reference.
        var nextReturnRamp: ReturnRamp? {
            GuardrailChecker.returnRamp(volumes.count, volumes: outside, lows: outsideLows, breaks: breaks, limits: limits)
        }

        /// Most quality sessions the next week may hold when it is week 1 or
        /// 2 of the return ramp after a short break (3.5 rule 4); where an
        /// unknown week may hide such a break (#40), the least that break
        /// could allow, as `nextCap` reads the hidden-break floor. Nil when
        /// neither sets a limit.
        var nextReturnRampMaxQuality: Int? {
            if let ramp = nextReturnRamp { return limits.returnRampMaxQuality(step: ramp.step) }
            return GuardrailChecker.hiddenBreakMaxQuality(volumes.count, volumes: outside, lows: outsideLows, raceWeeks: raceWeeks,
                                                          unbounded: false, limits: limits)
        }

        /// The next week's 10% reference, read as the checker reads it.
        var nextReference: (value: Double, index: Int, source: GuardrailChecker.ReferenceSource)? {
            GuardrailChecker.reference(before: volumes.count, volumes: outside, lows: outsideLows,
                                       recoveryRatio: limits.recoveryWeekMaxRatio, isRecovery: isOutsideRecovery)
        }

        /// True when the next week's 10% reference is 0 because it rests on an
        /// unknown week with no session of known time (#40): `nextCap` is then
        /// 0, and only a week of known volume run first gives a reference.
        var nextReferenceIsUnknownZero: Bool {
            guard nextReturnRamp == nil, let ref = nextReference else { return false }
            return ref.value <= 0 && ref.index != outsideBuildWeek
                && (ref.source == .unknownWeekBound || outside[ref.index] == nil)
        }

        /// True when the next week's 10% reference is 0 and rests on
        /// `outsideBuildWeek`, an open week that may end arbitrarily small.
        var nextReferenceIsOpenZero: Bool {
            guard nextReturnRamp == nil, let ref = nextReference else { return false }
            return ref.value <= 0 && ref.index == outsideBuildWeek
        }

        /// Week `k` as the earlier 4 weeks of the rolling check count it.
        func rollingPrior(_ k: Int, _ brks: [LoadBreak]) -> Double {
            GuardrailChecker.rollingPriorVolume(k, volumes: outside, lows: outsideLows, breaks: brks, limits: limits)
        }

        /// Most volume outside races the next week may have under the weekly,
        /// return-ramp and 4-week rules.
        var nextCap: Double {
            let i = volumes.count
            var cap = Double.infinity
            var plain: Double?
            if let ref = nextReference {
                // The checker's reference (`GuardrailChecker.reference`): over an
                // unknown week, the least it can have been as a build week (#40).
                if ref.value > 0 {
                    plain = ref.value * (1 + limits.maxWeeklyIncrease)
                } else if ref.index == outsideBuildWeek || outside[ref.index] == nil || ref.source == .unknownWeekBound {
                    // An arbitrarily small week may stand there.
                    plain = 0
                }
            }
            if let ramp = nextReturnRamp {
                cap = ramp.allowed
            } else if let plain {
                cap = plain
            }
            // A week of unknown volume nearby may hide a short break (#40):
            // the least return-ramp cap it could set.
            if nextReturnRamp == nil,
               let floor = GuardrailChecker.hiddenBreakFloor(i, volumes: outside, lows: outsideLows, raceWeeks: raceWeeks, unbounded: false,
                                                             limits: limits) {
                cap = min(cap, floor)
            }
            if i >= 7 {
                // Unknown weeks at their lower bound, as the checker reads them:
                // exact in the earlier 4 weeks, the least they can be in the recent 3.
                // A short break counts at the pre-break level among the earlier 4.
                let brks = breaks
                let prior = ((i - 7)...(i - 4)).reduce(0) { $0 + rollingPrior($1, brks) }
                let recent3 = ((i - 3)...(i - 1)).reduce(0) { $0 + outsideLow($1) }
                if prior > 0 { cap = min(cap, prior * (1 + limits.maxFourWeekIncrease) - recent3) }
            }
            return cap
        }

        /// Most volume the next week may have so that each rolling 4-week
        /// window ending in the next four weeks leaves at least as much for
        /// each later week in it. Sizing weeks greedily against `nextCap`
        /// alone can spend a window's whole budget on its first week (after a
        /// break, for example) and leave nothing for the weeks after.
        var spreadCap: Double {
            let i = volumes.count
            var cap = Double.infinity
            let brks = breaks
            for j in i...(i + 3) where j >= 7 {
                let priorSum = ((j - 7)...(j - 4)).reduce(0) { $0 + rollingPrior($1, brks) }
                guard priorSum > 0 else { continue }
                let known = ((j - 3)..<i).reduce(0) { $0 + outsideLow($1) }
                let budget = priorSum * (1 + limits.maxFourWeekIncrease) - known
                cap = min(cap, budget / Double(j - i + 1))
            }
            return cap
        }

        /// Appends a week of `volume` in all, `race` of it a race.
        mutating func append(_ volume: Double?, race: Double = 0) {
            volumes.append(volume)
            lows.append(volume ?? 0)
            let o = volume.map { max(0, $0 - race) }
            outside.append(o)
            outsideLows.append(o ?? 0)
            if race > 0 { raceWeeks.insert(volumes.count - 1) }
        }
    }

    /// The ledger under each way the history's last week may still end (#48).
    /// Every scenario gets the same plan weeks appended; caps are the
    /// smallest over the scenarios and the build streak the longest, so a plan
    /// sized against the set passes the checker in every scenario.
    struct LedgerSet {
        /// `scenarios[0]` is the history exactly as given (the timeline the
        /// builder's final check and the recovery-week labels use).
        var scenarios: [LoadLedger]
        /// True when the last week is open with no volume yet and the week
        /// before has no known volume: no 10% reference for the next week is
        /// safe (`PlanBuildIssue.startWeekWithoutReference`).
        var openWithoutReference = false

        var exact: LoadLedger { scenarios[0] }
        var count: Int { exact.volumes.count }
        var nextCap: Double { scenarios.map(\.nextCap).min() ?? .infinity }
        var nextReferenceIsUnknownZero: Bool { scenarios.contains(where: \.nextReferenceIsUnknownZero) }
        var spreadCap: Double { scenarios.map(\.spreadCap).min() ?? .infinity }
        var streak: Int { scenarios.map(\.streak).max() ?? 0 }
        /// `LoadLedger.nextReturnRampMaxQuality`, the least over the scenarios.
        var nextReturnRampMaxQuality: Int? { scenarios.compactMap(\.nextReturnRampMaxQuality).min() }
        /// True when the last week has unknown volume (in every scenario alike).
        var lastUnknown: Bool { !exact.volumes.isEmpty && exact.last == nil }

        /// The week-before volume a recovery week next must be measured
        /// against: the smallest over the scenarios in which that week is not
        /// a recovery week itself (where it is one, the build streak is already
        /// reset, so the next week needs no recovery there). For an unknown
        /// week it is the known lower bound: a week at most 80% of that is a
        /// recovery week whatever the unknown week held (#40). Nil when there
        /// is no week before.
        var recoveryBase: Double? {
            let j = count - 1
            let needing = scenarios.filter { !$0.isRecovery(j) }
            let pool = needing.isEmpty ? scenarios : needing
            return pool.compactMap(\.lastLow).min()
        }

        func isRecovery(_ j: Int) -> Bool { exact.isRecovery(j) }

        /// Appends a week of `volume` in all, `race` of it a race, everywhere.
        mutating func append(_ volume: Double?, race: Double = 0) {
            for k in scenarios.indices { scenarios[k].append(volume, race: race) }
        }
    }

    /// The guardrail ledger for the history's weekly volumes (`volumes`, the
    /// last entry being the start's week when `lastWeekOpen`), with the volumes
    /// outside races (`outside`, default `volumes`) and the weeks with a race.
    ///
    /// An open last week (#48) holds volume `low` so far and may still gain
    /// runs; it can only grow, in both series alike. These scenarios bound
    /// every way it can end:
    /// - **as given** (`low`, no more runs);
    /// - **just over the recovery line**: counted as a build week at
    ///   `max(low, recoveryWeekMaxRatio × the week before)`. A finished week
    ///   above that line is a build week whose 10% reference for the next
    ///   week is itself, so this is the smallest reference it can give, and
    ///   the smallest volume a recovery week next must be measured against.
    ///   At or below the line it is a recovery week, which resets the streak
    ///   and refers the next week back to the week before: the as-given
    ///   scenario covers that. The line is read in each series (the cadence
    ///   counts races, the 10% rule doesn't), one scenario each where they
    ///   differ (3.5 rule 3);
    /// - **just over the break line**, when the week as given is a break week
    ///   (3.5 rule 4): counted as no break week at `breakWeekMaxRatio` × the
    ///   pre-break level. Above that line it is a return week, whose next week
    ///   is held to the ramp's rise over it, smallest at the line; at or below
    ///   it the break goes on, which the as-given scenario covers;
    /// - **as large as 3.5 lets it be** after the weeks before (the weekly,
    ///   ramp and rolling caps, as `nextCap` reads them). When those weeks set
    ///   no cap, `recentWeekly × (1 + maxWeeklyIncrease)` stands in
    ///   (heuristic: the runner's recent level plus the weekly limit). A
    ///   larger week only adds to rolling 4-week totals, so this bounds them.
    /// Why these suffice: between the lines, each rule depends on the week's
    /// final volume in one direction (the 10% reference, the ramp's rise and
    /// the next week's recovery test rise with it; the rolling totals it ends
    /// rise with it; the totals it starts lower them, or don't depend on it
    /// while it is a break week), so the ends of each stretch are the worst
    /// cases. An unknown or closed last week has one scenario, the history as given.
    ///
    /// When the week before an open start week has unknown volume (#40), the
    /// open week can be a recovery week only against that week's lower bound
    /// and a build week's reference may be as small as what it ends at, so no
    /// next week is safe yet: `openWithoutReference` is set and the plan waits
    /// for the start week to close (`startWeekWithoutReference`). So it is
    /// when a scenario leaves the next week a 10% reference of 0 resting on
    /// the open week (nothing run yet and nothing the week before, outside a
    /// return ramp).
    static func ledgers(volumes: [Double?], lows: [Double] = [], outside: [Double?]? = nil, outsideLows: [Double]? = nil,
                        raceWeeks: Set<Int> = [], lastWeekOpen: Bool, recentWeekly: Double,
                        limits: GuardrailLimits) -> LedgerSet {
        let exact = LoadLedger(volumes: volumes, limits: limits, lows: lows, outside: outside, outsideLows: outsideLows,
                               raceWeeks: raceWeeks)
        let p = volumes.count - 1
        guard lastWeekOpen, p >= 0, let n = exact.outside[p], n.isFinite else {
            return LedgerSet(scenarios: [exact])
        }
        let total = exact.volumes[p]
        let before = LoadLedger(volumes: Array(exact.volumes.prefix(p)), limits: limits, lows: Array(exact.lows.prefix(p)),
                                outside: Array(exact.outside.prefix(p)), outsideLows: Array(exact.outsideLows.prefix(p)),
                                raceWeeks: raceWeeks.filter { $0 < p })
        let beforeUnknown = p >= 1 && (exact.volumes[p - 1] == nil || exact.outside[p - 1] == nil)
        func weekBefore(_ series: [Double?]) -> Double { p >= 1 ? max(0, series[p - 1] ?? 0) : 0 }

        enum Line { case cadence, outside, breakLine }
        var lines: [(delta: Double, kinds: Set<Line>)] = []
        func add(_ delta: Double, _ kind: Line) {
            let d = max(0, delta)
            if let k = lines.firstIndex(where: { abs($0.delta - d) <= 1e-9 * max(1, d) }) {
                lines[k].kinds.insert(kind)
            } else {
                lines.append((d, [kind]))
            }
        }
        if let t = total { add(limits.recoveryWeekMaxRatio * weekBefore(exact.volumes) - t, .cadence) }
        add(limits.recoveryWeekMaxRatio * weekBefore(exact.outside) - n, .outside)
        if let b = exact.breaks.first(where: { p >= $0.first && p < $0.end }) {
            add(limits.breakWeekMaxRatio * b.level - n, .breakLine)
        }

        func shifted(_ delta: Double) -> LoadLedger {
            var s = exact
            if let t = total { s.volumes[p] = t + delta }
            s.lows[p] += delta
            s.outside[p] = n + delta
            s.outsideLows[p] = n + delta
            return s
        }
        var scenarios = [exact]
        for line in lines {
            var s = shifted(line.delta)
            if line.kinds.contains(.cadence) { s.buildWeek = p }
            if line.kinds.contains(.outside) { s.outsideBuildWeek = p }
            if line.kinds.contains(.breakLine) { s.notBreakWeek = p }
            scenarios.append(s)
        }
        let capped = before.nextCap
        let fallback = recentWeekly * (1 + limits.maxWeeklyIncrease)
        let high = max(n, capped.isFinite ? capped : (fallback.isFinite ? fallback : n))
        scenarios.append(shifted(high - n))
        let zeroReference = scenarios.contains { $0.nextReferenceIsOpenZero }
        return LedgerSet(scenarios: scenarios, openWithoutReference: zeroReference || beforeUnknown)
    }

    // MARK: - Day helpers

    static func circularDistance(_ a: Int, _ b: Int) -> Int {
        let d = abs(a - b) % 7
        return min(d, 7 - d)
    }

    /// Picks up to `count` quality days from `candidates`: never on consecutive
    /// days (F4), as far as possible from `anchors` (the long run or race) and each other.
    /// Days in `excluded` are never picked (a hard day next door in another week).
    static func pickQualityDays(_ candidates: [Int], count: Int, anchors: [Int], excluded: Set<Int> = []) -> [Int] {
        var chosen: [Int] = []
        while chosen.count < count {
            let options = candidates.filter { c in
                !excluded.contains(c) && !chosen.contains(c) && chosen.allSatisfy { circularDistance(c, $0) >= 2 }
            }
            func score(_ c: Int) -> Int { (anchors + chosen).map { circularDistance(c, $0) }.min() ?? 7 }
            guard let best = options.max(by: { score($0) != score($1) ? score($0) < score($1) : $0 > $1 }) else { break }
            chosen.append(best)
        }
        return chosen.sorted()
    }

    /// Picks `count` easy days from `candidates`, spread away from `taken`.
    static func pickEasyDays(_ candidates: [Int], count: Int, taken: [Int]) -> [Int] {
        var chosen: [Int] = []
        while chosen.count < count {
            let options = candidates.filter { !chosen.contains($0) }
            func score(_ c: Int) -> Int { (taken + chosen).map { circularDistance(c, $0) }.min() ?? 7 }
            guard let best = options.max(by: { score($0) != score($1) ? score($0) < score($1) : $0 > $1 }) else { break }
            chosen.append(best)
        }
        return chosen.sorted()
    }

    static func floorMinute(_ s: Double) -> Double { s.isFinite ? max(0, (s / 60).rounded(.down) * 60) : 0 }

    /// Longest the long run may be, in whole minutes, next to `rest` seconds
    /// of other running, so it stays within its share of the week (3.5 rule
    /// 5) with a point of margin. In a marathon plan it may go above the usual
    /// share only up to `PlanHeuristics.marathonLongRunTargetSeconds`, the
    /// bound `longRunRoom` uses, and never above the marathon ceiling.
    static func longRunFit(rest: Double, marathon: Bool, limits: GuardrailLimits) -> Double {
        func fit(_ share: Double) -> Double {
            let s = share - 0.01
            return floorMinute(s * rest / (1 - s))
        }
        let usual = fit(limits.maxLongRunShare)
        guard marathon else { return usual }
        return max(usual, min(fit(limits.marathonLongRunCeiling), PlanHeuristics.marathonLongRunTargetSeconds))
    }
}

extension PlanBuilder {
    /// Why a week left easy time out with no run of its own (#79), so its
    /// note gives only a reason that holds (#106).
    enum LeftOutReason: Equatable {
        /// Under the easy-run floor (`PlanHeuristics.minimumEasyRunSeconds`):
        /// too little for a run of its own.
        case tooShort
        /// At least the floor, and no training day was free for another run.
        case noFreeDay
        /// At least the floor, with a free day, but the week's session cap
        /// (F2's max session length or the spike rule, 3.5 rule 1) is under
        /// the floor, so no easy run fits.
        case sessionCap

        /// The reason for `seconds` of easy time left with no run of its own;
        /// `freeDay`: a training day was free for an easy run. In the builder,
        /// at least the floor left over with a free day happens only when the
        /// session cap is under the floor (`draftWeek`, `composeRaceWeek`).
        /// Nil for time that isn't finite and positive.
        static func of(seconds: Double, freeDay: Bool) -> LeftOutReason? {
            guard seconds.isFinite, seconds > 0 else { return nil }
            if seconds < PlanHeuristics.minimumEasyRunSeconds { return .tooShort }
            return freeDay ? .sessionCap : .noFreeDay
        }
    }

    /// Marks a week the easy-run limit (F3, #23) held below its volume. The
    /// builder first writes `easyLimitToken` on the week's first session and
    /// `Builder.run` replaces it with `easyRunLimitNote`, which can state the
    /// week against the volume it was asked for, or removes it when the week
    /// kept its volume.
    static let easyLimitToken = "{easy-limit}"
    /// The words every such note holds.
    static let easyRunLimitMarker = "so that no easy run is longer than the long run"

    /// Plain wording, no easy run longer than the long run (F3, #23): the
    /// week as planned against the volume the plan was aiming for.
    static func easyRunLimitNote(planned: Double, asked: Double, days: Int) -> String {
        "This week is \(Int(planned / 60)) of \(Int(asked / 60)) minutes \(easyRunLimitMarker) (or past the long-run cap or "
            + "your max session length) on \(days) running days; its easy share still stays within 75 to 85% (SPEC 3.1, F3)."
    }

    /// The note a week carries for `seconds` of easy time it leaves out, with
    /// the reason that holds (#79, #106), or nil for under a whole minute (or
    /// time that isn't finite). Only easy time with no run of its own counts:
    /// minutes the long run gives up to stay within its share (3.5 rule 5)
    /// are long-run time and are not stated here (#106).
    static func leftOutNote(seconds: Double, freeDay: Bool) -> String? {
        guard seconds.isFinite, seconds >= 60, let reason = LeftOutReason.of(seconds: seconds, freeDay: freeDay) else {
            return nil
        }
        let floor = Int(PlanHeuristics.minimumEasyRunSeconds / 60)
        let because: String
        switch reason {
        case .tooShort: because = "too little for a run of at least \(floor) min, the shortest run the plan schedules."
        case .noFreeDay: because = "no training day is free for another run."
        case .sessionCap:
            because = "this week's longest session (the max session length or the single-run spike rule, SPEC 3.5) "
                + "is under \(floor) min, the shortest run the plan schedules."
        }
        return "This week leaves out \(Int(seconds / 60)) min of easy running: " + because
    }
}

// MARK: - Plan generation

private struct SessionDraft {
    let day: Int
    let kind: PlannedWorkout.Kind
    let segments: [WorkoutSegment]
    let purpose: String
    let rules: [PlanRule]

    var duration: Double { segments.reduce(0) { $0 + $1.durationSeconds } }
    var hardSeconds: Double { segments.filter { !$0.intensity.isBelowAerobicThreshold }.reduce(0) { $0 + $1.durationSeconds } }
}

private struct WeekContext {
    let phase: PlanPhase
    let recovery: Bool
    let taper: Bool
    /// The smallest workable week (lower for a required recovery week).
    let floor: Double
    let longTarget: Double
    let qualityKinds: [PlannedWorkout.QualityKind]
    var maxQuality: Int
    /// Days (0 = Monday) the week may use.
    let days: [Int]
    /// The long run's day this week, or nil for none.
    let longDay: Int?
    /// Days a quality session may not go on: next to a hard day in the week before or after.
    var excludedQualityDays: Set<Int>
    /// Longest any session this week may be: the runner's max session length
    /// (F2) and the single-run spike rule (3.5 rule 1, `Builder.spikeCap`).
    var sessionCap: Double
    /// Longest the long run may become when it is raised to the easy-run
    /// floor or takes easy time too short for a run of its own (#79): the
    /// F3 10-minute step over the last build week's long run and the spike
    /// rule's allowance (3.5 rule 1, `Builder.spikeCap`), whichever is lower.
    var longRaiseCap: Double = .infinity
    /// Week 1 back after a short break (3.5 rule 4, "no hard sessions"): the
    /// week is all easy running, with no quality session and no steady
    /// long-run finish, so it is exempt from the 3.1 band (heuristic, the
    /// conservative reading of rule 4).
    var allEasy = false

    func with(maxQuality q: Int) -> WeekContext { var c = self; c.maxQuality = q; return c }
    func with(excludedQualityDays e: Set<Int>) -> WeekContext { var c = self; c.excludedQualityDays = e; return c }
    func with(sessionCap cap: Double) -> WeekContext { var c = self; c.sessionCap = cap; return c }
}

private struct Builder {
    typealias H = PlanHeuristics
    let input: PlanInput
    let v: PlanBuilder.Validated
    let timeZone: TimeZone
    let limits: GuardrailLimits
    let history: [PlannedWorkout]
    let available: [Int]
    let longDay: Int
    let maxSession: Double
    let raceDay: Int
    var ledger: PlanBuilder.LedgerSet
    /// The start's week is history but not over (#48): the plan is provisional.
    let startWeekOpen: Bool
    /// Mean weekly volume of the last (up to 4) complete history weeks before the start week, if any.
    let historyMean: Double?
    /// Hard days (quality and races), counted in days from the plan's first Monday.
    var hardDays: [Int]
    /// Each training week's asked and drafted volume (`PlanBuilder.buildDiagnosed`).
    var diagnostics: [PlanBuilder.WeekVolumeDiagnostic] = []
    /// Collect `diagnostics` (tests only; it drafts each week once more).
    var diagnose = false
    /// Let a quality session's warm-up and cool-down shrink under a session
    /// cap (#105, #113); false only in tests, to compare against.
    var shortenWarmUps = true

    init(input: PlanInput, v: PlanBuilder.Validated, timeZone: TimeZone, limits: GuardrailLimits, history: [PlannedWorkout]) {
        self.input = input
        self.v = v
        self.timeZone = timeZone
        self.limits = limits
        self.history = history
        self.available = input.trainingDays.map(\.rawValue).sorted()
        self.longDay = input.longRunDay.rawValue
        // No training run goes past the long-run time cap that applies to it
        // (3.5 rule 5) or the runner's max session length (F2); F3, #23.
        self.maxSession = min(input.maxSessionSeconds ?? .infinity,
                              PlanHeuristics.longRunCap(v.category, isMarathonDistance: RaceCategory.isMarathonDistance(meters: input.raceDistanceMeters)))
        self.raceDay = PlanWeekday(of: input.raceDate, timeZone: timeZone).rawValue
        let before = history.filter { $0.date < v.firstMonday }
        var weeks: [PlanWeek] = []
        let startWeek = PlanCalendar.weekStart(containing: input.startDate, timeZone: timeZone)
        // A start week that is history (a mid-week start) is still open: runs
        // logged after the build will land in it (#48). It is in the ledger
        // even with no history before it, as an empty week so far.
        let open = startWeek < v.firstMonday
        if let first = before.map(\.date).min() ?? (open ? startWeek : nil) {
            weeks = PlanWeek.weeks(from: before, firstWeekContaining: first,
                                   lastWeekContaining: v.firstMonday.addingTimeInterval(-1), timeZone: timeZone)
        }
        self.startWeekOpen = open
        self.ledger = PlanBuilder.ledgers(volumes: weeks.map { $0.volume(.time) }, lows: weeks.map { $0.knownVolume(.time) },
                                          outside: weeks.map { $0.volumeOutsideRaces(.time) },
                                          outsideLows: weeks.map { $0.knownVolumeOutsideRaces(.time) },
                                          raceWeeks: Set(weeks.indices.filter { weeks[$0].hasRace }),
                                          lastWeekOpen: open,
                                          recentWeekly: v.recentWeekly, limits: limits)
        let complete = weeks.filter { $0.weekStart < startWeek }.suffix(4).compactMap { $0.volume(.time) }
        self.historyMean = complete.isEmpty ? nil : complete.reduce(0, +) / Double(complete.count)
        let cal = PlanCalendar.calendar(timeZone: timeZone)
        self.hardDays = history.filter { $0.kind.isQuality || $0.kind == .race }.compactMap {
            cal.dateComponents([.day], from: v.firstMonday, to: cal.startOfDay(for: $0.date)).day
        }
    }

    var c: RaceCategory { v.category }
    /// Whether the race is of marathon distance (3.5 rule 5, #30), which the
    /// marathon long-run allowances need; category `.marathon` alone starts at 30 km.
    var isMarathonRace: Bool { RaceCategory.isMarathonDistance(meters: input.raceDistanceMeters) }
    /// Longest long run for this race (3.5 rule 5: 180 minutes at marathon distance, else the category's).
    var longRunCap: Double { H.longRunCap(c, isMarathonDistance: isMarathonRace) }
    var growth: Double { min(H.weeklyGrowth, limits.maxWeeklyIncrease * 0.8) }
    var recoveryRatio: Double { min(H.recoveryWeekRatio, limits.recoveryWeekMaxRatio - 0.05) }
    var margin: Double { H.guardrailMargin }
    var maxBuildRun: Int { max(0, limits.maxConsecutiveBuildWeeks) }

    /// The long-run share the checker allows this plan (3.5 rule 5): the
    /// marathon ceiling in a marathon plan (the race session has the goal
    /// distance, so every plan week is in or before it), else the usual one.
    var longRunShareLimit: Double {
        isMarathonRace ? limits.marathonLongRunCeiling : limits.maxLongRunShare
    }

    /// Most of a week of `total` seconds the long run may take, in seconds,
    /// when it would usually take `usualShare`. In a marathon plan it may take
    /// more, up to the marathon ceiling with margin, but only to bring it up
    /// to `PlanHeuristics.marathonLongRunTargetSeconds` (heuristic, the
    /// conservative reading of 3.5 rule 5: above the usual share is a warning,
    /// so it is used only where a low weekly volume would hold the long run
    /// short). The long run still grows at most 10 minutes a week and keeps
    /// the spike rule and the time caps.
    func longRunRoom(total: Double, usualShare: Double) -> Double {
        let usual = usualShare * total
        guard isMarathonRace else { return usual }
        let extended = min((longRunShareLimit - 0.02) * total, H.marathonLongRunTargetSeconds)
        return max(usual, extended)
    }

    func longRunFit(rest: Double) -> Double {
        PlanBuilder.longRunFit(rest: rest, marathon: isMarathonRace, limits: limits)
    }

    // MARK: Phases and recovery weeks

    func phases(count n: Int) -> [PlanPhase] {
        let taper = H.taperWeeks(c)
        let m = n - taper
        let peak = min(H.maximumPeakWeeks(c), max(1, m / 4))
        let build = min(H.maximumBuildWeeks(c), max(1, (m - peak) / 2))
        let base = max(0, m - peak - build)
        return Array(repeating: .base, count: base) + Array(repeating: .build, count: build)
            + Array(repeating: .peak, count: m - base - build) + Array(repeating: .taper, count: taper)
    }

    /// Recovery weeks up to and including `anchor` (the taper's first week):
    /// fewest recovery weeks with no more than `maxConsecutiveBuildWeeks` build
    /// weeks in a row (history included), avoiding a recovery week right before
    /// the anchor, which would lower the race week's guardrail reference. Nil
    /// when no arrangement works (week 0 can't be a recovery week and must be).
    /// `from` > 0 re-plans the weeks from there on, `startStreak` being the
    /// streak before week `from`.
    func recoveryWeeks(anchor: Int, startStreak: Int, firstCanRecover: Bool, from: Int = 0) -> Set<Int>? {
        let maxC = maxBuildRun
        var memo: [Int: (cost: Int, recover: Bool)] = [:]
        let impossible = Int.max / 4
        func cost(_ i: Int) -> Int {
            if i == 0 && !firstCanRecover { return impossible }
            return 10 + (i == anchor - 1 ? 30 : 0)
        }
        func solve(_ i: Int, _ s: Int) -> Int {
            if i == anchor { return cost(i) }
            let key = i * 1000 + s
            if let m = memo[key] { return m.cost }
            var best = impossible
            var recover = true
            if s + 1 <= maxC { best = solve(i + 1, s + 1); recover = false }
            let r = min(impossible, cost(i) + solve(i + 1, 0))
            if r < best { best = r; recover = true }
            memo[key] = (best, recover)
            return best
        }
        var s = min(startStreak, maxC)
        guard from <= anchor, solve(from, s) < impossible else { return nil }
        var result: Set<Int> = [anchor]
        for i in from..<anchor {
            if memo[i * 1000 + s]?.recover ?? true { result.insert(i); s = 0 } else { s += 1 }
        }
        return result
    }

    // MARK: Days

    /// Days week `i` may use. The first week starts on an open Monday (see
    /// `PlanBuilder.build`), so every day is open; the filter only guards that.
    func days(week i: Int) -> [Int] {
        guard i == 0 else { return available }
        return available.filter { sessionDate(week: 0, day: $0) >= input.startDate }
    }

    /// The long run's day in week `i`: the runner's long-run day, except in
    /// the week before the race when that day is within 2 days of the race;
    /// then the latest day at least 3 days before it (or none).
    func longDay(week i: Int, raceWeek: Int, days: [Int]) -> Int? {
        if i == raceWeek - 1 {
            let gap = { (d: Int) in 7 + self.raceDay - d }
            if gap(longDay) >= 3 { return days.contains(longDay) ? longDay : nil }
            return days.filter { gap($0) >= 3 }.max()
        }
        return days.contains(longDay) ? longDay : nil
    }

    /// Days of week `i` within one day of a known hard day (F4: never two hard days in a row).
    func excludedQualityDays(week i: Int, extraHard: [Int]) -> Set<Int> {
        Set((0..<7).filter { d in (hardDays + extraHard).contains { abs(i * 7 + d - $0) < 2 } })
    }

    func sessionDate(week i: Int, day d: Int) -> Date {
        let cal = PlanCalendar.calendar(timeZone: timeZone)
        let start = v.weekStarts[i]
        let day = cal.date(byAdding: .day, value: d, to: start) ?? start.addingTimeInterval(Double(d) * 86_400)
        // The day matters; noon is a placeholder time of day, clear of DST changes.
        return cal.date(bySettingHour: 12, minute: 0, second: 0, of: day) ?? day.addingTimeInterval(12 * 3600)
    }

    /// The single-run spike rule's limit on week `i`'s sessions (SPEC 3.5
    /// rule 1, `spikeCap(week:days:earlier:)`).
    struct SpikeCap {
        /// Longest any session in the week may be, as far as runs before the week tell.
        var cap: Double
        /// True when some day of the week has no run of known time from before
        /// the week in its window (no history yet, or only runs with no valid
        /// duration, #40). The checker then measures that day's session
        /// against the sessions earlier in the same week alone, so the week
        /// must hold together on its own (`holdTogether`).
        var unanchored: Bool
        /// For each day that has one, the longest run of known time before the
        /// week in that day's window (seconds).
        var references: [Int: Double] = [:]
    }

    /// The spike rule's limit on sessions in week `i`, on any of `days`, with
    /// `guardrailMargin` under the limit (about 9% longer than the 30-day
    /// longest at the default 10%, inside SPEC 3.5's 5 to 10% target). It
    /// applies only to a week drafted again because the rule binds
    /// (`spikeHolds`); a week it doesn't bind is held to the true limit.
    ///
    /// It reads `GuardrailChecker.spikeReference` exactly as the checker does,
    /// over the history and the plan weeks already made (`earlier`, all before
    /// week `i`), and takes the smallest over the week's days: a later day's
    /// window has dropped more of the oldest runs. Sessions earlier in the
    /// same week can only raise a reference, so a session under this cap
    /// passes the checker on every day that has a reference from before the week.
    ///
    /// A day with none is `unanchored`: the checker invents no reference
    /// there, and measures the session against the week's earlier sessions
    /// only. For it the builder also holds sessions to the runner's typical
    /// recent long run (`PlanInput.recentLongRunSeconds`, at most the true
    /// longest) plus the limit, when the baseline gives one (heuristic, the
    /// runner's own data); from the next week on the plan's own runs are the reference.
    func spikeCap(week i: Int, days: [Int], earlier: [PlannedWorkout]) -> SpikeCap {
        let rise = limits.maxSingleRunIncrease
        guard rise.isFinite, rise >= 0 else { return SpikeCap(cap: .infinity, unanchored: false) }
        var cap = Double.infinity
        var unanchored = false
        var references: [Int: Double] = [:]
        for d in days {
            let date = sessionDate(week: i, day: d)
            if let ref = GuardrailChecker.spikeReference(before: date, measure: .time, sessions: earlier,
                                                         timeZone: timeZone, limits: limits) {
                cap = min(cap, ref.allowed * margin)
                references[d] = ref.value
            } else {
                unanchored = true
                if let r = input.recentLongRunSeconds { cap = min(cap, r * (1 + rise) * margin) }
            }
        }
        return SpikeCap(cap: cap, unanchored: unanchored, references: references)
    }

    /// True when no session of the drafted week is too long for the spike
    /// rule (3.5 rule 1): each is within the limit of the longest run before
    /// it, from before the week (`spike.references`) or earlier in the week,
    /// and, on a day with nothing from before the week, of the runner's recent
    /// long run when given. Then the rule doesn't bind and the week stays
    /// exactly as drafted without it; only a week it binds is drafted under
    /// the cap (with `guardrailMargin`). This test has no margin: it is the
    /// true limit (10% by default), so a session of a week kept this way may
    /// be up to 10% over its reference, still inside SPEC 3.5's 5 to 10% target.
    func spikeHolds(_ drafts: [SessionDraft], week i: Int, spike: SpikeCap) -> Bool {
        let rise = limits.maxSingleRunIncrease
        guard rise.isFinite, rise >= 0 else { return true }
        var longest = 0.0
        for d in drafts.sorted(by: { $0.day < $1.day }) {
            let reference = spike.references[d.day]
            let base = max(reference ?? 0, longest)
            if base > 0 && d.duration > base * (1 + rise) { return false }
            if reference == nil, let r = input.recentLongRunSeconds, d.duration > r * (1 + rise) { return false }
            longest = max(longest, d.duration)
        }
        return true
    }

    /// The week's sessions, held together under the spike rule when the week
    /// is `unanchored` (no history yet, or none of known time in the window).
    ///
    /// The checker then measures each session against the longest of the
    /// week's earlier sessions (and any reference from before the week), and
    /// the week's first session against nothing. So the week is drafted at
    /// its full volume first, under the usual caps, and then reshaped in date
    /// order (`reshapeChain`). For example, 120 minutes over Monday easy,
    /// Wednesday quality (35), Friday easy and Sunday long becomes about
    /// 33/35/20/32 instead of a week cut in half.
    ///
    /// When the week opens with a quality session, nothing can grow before
    /// it, so the chain builds up from its drafted length and can hold less
    /// than the week asks (Tuesday quality 67 min, Thursday, Saturday: about
    /// 67 + 73 + 79). The week is then also drafted with no quality session
    /// on its first day, so it opens with an easy run, keeping the usual
    /// spacing of hard days; whichever reshaped week keeps more time (and as
    /// many quality sessions) is used. No quality session is ever shortened
    /// for the chain.
    ///
    /// No easy run may be longer than the week's long run (F3, #23), so a
    /// reshape that needs one to carry the chain fails. Then, in this order
    /// (all heuristics, SPEC sets neither): the quality session takes the
    /// opening easy run's day (`swappedOpener`: nothing before it, so no chain
    /// limit on it, and the easy runs after it grow toward it without passing
    /// the long run); else the week is drafted again 1.5% smaller at a time,
    /// up to 40 steps, until a reshape holds (the week's note then says it is
    /// shorter than the volume aimed for).
    ///
    /// This is a heuristic: SPEC 3.5 says nothing of a runner with no
    /// recorded past, and only such a week is shaped this way (later weeks
    /// have the plan's own runs as their reference). If no reshape meets the
    /// chain, the draft is returned as it is and the plan's final check refuses it.
    func holdTogether(target: Double, ctx: WeekContext, spike: SpikeCap) -> [SessionDraft] {
        let drafts = composeWeek(target: target, ctx: ctx)
        guard spike.unanchored, limits.maxSingleRunIncrease.isFinite else { return drafts }
        let factor = (1 + limits.maxSingleRunIncrease) * margin
        func total(_ d: [SessionDraft]) -> Double { d.reduce(0) { $0 + $1.duration } }
        func qualityCount(_ d: [SessionDraft]) -> Int { d.filter { $0.kind.isQuality }.count }
        var best = reshapeChain(drafts, ctx: ctx, references: spike.references, factor: factor)
        if let opening = drafts.min(by: { $0.day < $1.day }), opening.kind.isQuality {
            let later = ctx.with(excludedQualityDays: ctx.excludedQualityDays.union([opening.day]))
            let moved = composeWeek(target: target, ctx: later)
            if qualityCount(moved) >= qualityCount(drafts),
               let shaped = reshapeChain(moved, ctx: later, references: spike.references, factor: factor),
               shaped.first?.kind.isQuality == false, total(shaped) > (best.map(total) ?? 0) + 60 {
                best = shaped
            }
        }
        // Heuristic: the quality session first, in the opening easy run's
        // place (see the doc comment). It keeps the two-day spacing of quality
        // sessions that `pickQualityDays` aims for: the opener's day must not
        // be next to another quality day. (The long run's day is not a hard
        // constraint in `pickQualityDays`, only a distance it maximises, so it
        // isn't one here.)
        func swappedOpener(_ d: [SessionDraft]) -> [SessionDraft]? {
            let byDay = d.sorted { $0.day < $1.day }
            guard let first = byDay.first, first.kind == .easy,
                  let q = byDay.first(where: { $0.kind.isQuality }), !ctx.excludedQualityDays.contains(first.day),
                  byDay.filter({ $0.kind.isQuality && $0.day != q.day })
                      .allSatisfy({ PlanBuilder.circularDistance($0.day, first.day) >= 2 }) else { return nil }
            return byDay.map { x in
                if x.day == first.day { return SessionDraft(day: first.day, kind: q.kind, segments: q.segments, purpose: q.purpose, rules: q.rules) }
                if x.day == q.day { return SessionDraft(day: q.day, kind: first.kind, segments: first.segments, purpose: first.purpose, rules: first.rules) }
                return x
            }
        }
        if best == nil, let swapped = swappedOpener(drafts),
           let shaped = reshapeChain(swapped, ctx: ctx, references: spike.references, factor: factor) {
            return shaped
        }
        if let best { return best }
        // No reshape keeps both the spike chain and F3's easy-run limit (no
        // easy run longer than the long run, #23): the week is planned
        // smaller instead, the first size at which one does, with a note.
        let full = total(drafts)
        var size = target
        for _ in 0..<40 {
            size *= 0.985
            guard size >= ctx.floor else { break }
            let smaller = composeWeek(target: size, ctx: ctx)
            if let shaped = reshapeChain(smaller, ctx: ctx, references: spike.references, factor: factor) {
                return PlanBuilder.floorMinute(full - total(shaped)) >= 60 ? Self.tagEasyRunLimit(shaped) : shaped
            }
        }
        return drafts
    }

    /// Reshapes a week's sessions so each is at most `factor` × the longest
    /// before it in the week (or before the week, `references`). Nil when it
    /// can't: then nothing is changed.
    ///
    /// - A session too long for the chain gives the extra time to the longest
    ///   earlier easy run (the long run when there is none), so the session
    ///   before it grows and the allowance with it.
    /// - A quality session too long for the chain is never cut (its hard time
    ///   holds the week's 3.1 balance): the longest earlier easy run grows to
    ///   carry it, or, with only quality sessions before it, the longest of
    ///   those gets a longer easy cool-down. The time comes from later easy
    ///   runs and then a later long run, none below the easy floor.
    /// - When nothing earlier can grow, a session too long gives its extra
    ///   time to the shortest later easy run or long run with room for it; an
    ///   easy run splits in two over a free later day; what is left is
    ///   dropped. So a week that opens with a quality session builds up from
    ///   it and can end shorter than drafted.
    /// - No session grows past `ctx.sessionCap`, and the long run not past
    ///   its target, its cap or its share of the week (3.5).
    /// - Last, where the chain and its share allow, later easy runs give time
    ///   to the long run so it is at least as long as the longest easy run
    ///   before it. An easy run at the floor gives nothing, so the long run can
    ///   still end shorter (heuristic; from the next week on it grows from the
    ///   week's longest run).
    /// It stops after a fixed number of rounds; a week it could not reshape is
    /// returned as nil.
    func reshapeChain(_ week: [SessionDraft], ctx: WeekContext, references: [Int: Double],
                      factor: Double) -> [SessionDraft]? {
        var drafts = week.sorted { $0.day < $1.day }
        guard !drafts.isEmpty else { return drafts }
        let total = drafts.reduce(0) { $0 + $1.duration }
        let minEasy = H.minimumEasyRunSeconds
        let longMax = min(ctx.longTarget, longRunCap,
                          PlanBuilder.floorMinute(longRunRoom(total: total, usualShare: limits.maxLongRunShare - 0.02)),
                          ctx.sessionCap)
        func isEasy(_ k: Int) -> Bool { drafts[k].kind == .easy }
        func isLong(_ k: Int) -> Bool { drafts[k].kind == .long }
        func isQuality(_ k: Int) -> Bool { drafts[k].kind.isQuality }
        func finish(_ k: Int) -> Double { drafts[k].segments.filter { $0.role == .finish }.reduce(0) { $0 + $1.durationSeconds } }
        func ceilMinute(_ s: Double) -> Double { (s / 60).rounded(.up) * 60 }
        func resize(_ k: Int, _ seconds: Double) {
            let d = drafts[k]
            if isEasy(k) {
                drafts[k] = easySession(day: d.day, seconds: seconds, ctx: ctx)
            } else if isLong(k) {
                let f = min(finish(k), PlanBuilder.floorMinute(H.longRunFinishShare * seconds))
                drafts[k] = longSession(day: d.day, seconds: seconds, finish: f, ctx: ctx)
            } else if isQuality(k), let c = d.segments.lastIndex(where: { $0.role == .coolDown }), seconds > d.duration {
                // A quality session only ever grows, by easy running in its cool-down.
                var segments = d.segments
                let cool = segments[c]
                segments[c] = segment(.coolDown, cool.intensity, cool.durationSeconds + seconds - d.duration)
                drafts[k] = SessionDraft(day: d.day, kind: d.kind, segments: segments, purpose: d.purpose, rules: d.rules)
            }
        }
        func roomToGrow(_ k: Int) -> Double {
            if isEasy(k) || isQuality(k) { return max(0, ctx.sessionCap - drafts[k].duration) }
            if isLong(k) { return max(0, longMax - drafts[k].duration) }
            return 0
        }
        /// The first session over its allowance: its index and the allowance.
        func firstBreak() -> (Int, Double)? {
            var longest = 0.0
            for k in drafts.indices {
                let base = max(references[drafts[k].day] ?? 0, longest)
                if base > 0 && drafts[k].duration > factor * base + 1 { return (k, factor * base) }
                longest = max(longest, drafts[k].duration)
            }
            return nil
        }
        /// The earlier session that best carries the allowance: an easy run
        /// with room, longest first, then the long run.
        func recipient(before k: Int) -> Int? {
            let open = (0..<k).filter { roomToGrow($0) >= 60 }
            return open.filter(isEasy).max { drafts[$0].duration < drafts[$1].duration }
                ?? open.first(where: isLong)
        }
        /// Takes up to `need` from later easy runs, then a later long run, none below the floor.
        func fund(_ need: Double, after k: Int) -> Double {
            var need = need, moved = 0.0
            let donors = drafts.indices.filter { $0 > k && isEasy($0) }.sorted { drafts[$0].duration > drafts[$1].duration }
                + drafts.indices.filter { $0 > k && isLong($0) }
            for dnr in donors where need >= 60 {
                let take = min(PlanBuilder.floorMinute(drafts[dnr].duration - minEasy), need)
                guard take >= 60 else { continue }
                resize(dnr, drafts[dnr].duration - take)
                moved += take
                need -= take
            }
            return moved
        }
        /// Moves time from k to an earlier recipient: x − δ ≤ factor × max(longest before, xr + δ).
        func moveEarlier(_ k: Int, allowed: Double) -> Bool {
            guard let r = recipient(before: k) else { return false }
            let x = drafts[k].duration, xr = drafts[r].duration
            let longestBefore = (0..<k).map { drafts[$0].duration }.max() ?? 0
            var delta = ceilMinute(x - allowed)
            if xr + delta > longestBefore { delta = ceilMinute((x - factor * xr) / (1 + factor)) }
            delta = min(delta, roomToGrow(r), x - (isEasy(k) ? minEasy : 60))
            guard delta >= 60 else { return false }
            resize(k, x - delta)
            resize(r, xr + delta)
            return true
        }
        /// Nothing earlier can grow: a later run takes the extra time, an easy
        /// run splits over a free later day, or the time is dropped.
        func cutDown(_ k: Int, allowed: Double) -> Bool {
            let x = drafts[k].duration
            let delta = ceilMinute(x - allowed)
            guard x - delta >= (isEasy(k) ? minEasy : 60) else { return false }
            let later = drafts.indices.filter { $0 > k && !isQuality($0) && roomToGrow($0) >= 60 }
                .min(by: { drafts[$0].duration < drafts[$1].duration })
            let used = Set(drafts.map(\.day))
            if let to = later, roomToGrow(to) >= delta {
                resize(k, x - delta)
                resize(to, drafts[to].duration + delta)
            } else if isEasy(k), x / 2 >= minEasy,
                      let free = ctx.days.first(where: { !used.contains($0) && $0 > drafts[0].day }) {
                let half = PlanBuilder.floorMinute(x / 2)
                resize(k, x - half)
                drafts.append(easySession(day: free, seconds: half, ctx: ctx))
                drafts.sort { $0.day < $1.day }
            } else {
                resize(k, x - delta)
                if let to = later { resize(to, drafts[to].duration + PlanBuilder.floorMinute(min(delta, roomToGrow(to)))) }
            }
            return true
        }
        /// A quality session over its allowance: an earlier easy run, or else
        /// the longest earlier quality session, grows to carry it.
        func carry(_ k: Int) -> Bool {
            let x = drafts[k].duration
            let r = recipient(before: k).flatMap { isEasy($0) ? $0 : nil }
                ?? (0..<k).filter { isQuality($0) && roomToGrow($0) >= 60 }.max { drafts[$0].duration < drafts[$1].duration }
            guard let r else { return false }
            let need = min(ceilMinute(x / factor - drafts[r].duration), roomToGrow(r))
            guard need >= 60 else { return false }
            let moved = fund(need, after: k)
            guard moved >= 60 else { return false }
            resize(r, drafts[r].duration + moved)
            return true
        }
        /// Later easy runs give time to the long run, up to the longest easy run before it.
        func lengthenLong() {
            guard let l = drafts.indices.first(where: isLong) else { return }
            let opener = (0..<l).filter(isEasy).map { drafts[$0].duration }.max() ?? 0
            let longest = (0..<l).map { drafts[$0].duration }.max() ?? 0
            let cap = min(longMax, longest > 0 ? PlanBuilder.floorMinute(factor * longest) : longMax)
            let need = min(opener, cap) - drafts[l].duration
            guard need >= 60 else { return }
            let donors = drafts.indices.filter { $0 != l && isEasy($0) && drafts[$0].duration < opener }
            var left = PlanBuilder.floorMinute(need)
            for dnr in donors.sorted(by: { drafts[$0].duration > drafts[$1].duration }) where left >= 60 {
                let take = min(PlanBuilder.floorMinute(drafts[dnr].duration - minEasy), left)
                guard take >= 60 else { continue }
                resize(dnr, drafts[dnr].duration - take)
                resize(l, drafts[l].duration + take)
                left -= take
            }
        }
        // A week that already holds together is left exactly as drafted.
        var polished = firstBreak() == nil
        for _ in 0..<96 {
            guard let (k, allowed) = firstBreak() else {
                // Time dropped above can leave the long run over its share (3.5): trim it and look again.
                let now = drafts.reduce(0) { $0 + $1.duration }
                if let l = drafts.indices.first(where: isLong) {
                    let fit = longRunFit(rest: now - drafts[l].duration)
                    if drafts[l].duration > fit {
                        guard fit >= minEasy else { return nil }
                        resize(l, fit)
                        continue
                    }
                }
                if !polished {
                    polished = true
                    let before = drafts
                    lengthenLong()
                    if firstBreak() != nil { drafts = before }
                    continue
                }
                // No easy run is longer than the week's long run (F3, #23): one
                // over it is cut to it, its time dropped like any time this
                // reshape can't place, and the loop looks again.
                if let l = drafts.indices.first(where: isLong) {
                    let to = PlanBuilder.floorMinute(drafts[l].duration)
                    let over = drafts.indices.filter { isEasy($0) && drafts[$0].duration > to + 1 }
                    if !over.isEmpty, to >= minEasy {
                        // The time over the limit goes to an easy run on a free
                        // day when it makes one of at least the floor (as
                        // `cutDown` splits a run); else it is dropped.
                        for k in over {
                            let excess = PlanBuilder.floorMinute(drafts[k].duration - to)
                            let used = Set(drafts.map(\.day))
                            let free = ctx.days.first { !used.contains($0) && $0 > drafts[0].day }
                                ?? ctx.days.first { !used.contains($0) }
                            resize(k, to)
                            if excess >= minEasy, let day = free {
                                drafts.append(easySession(day: day, seconds: min(excess, to), ctx: ctx))
                            }
                        }
                        drafts.sort { $0.day < $1.day }
                        continue
                    }
                }
                let easyOK = drafts.indices.allSatisfy { !isEasy($0) || drafts[$0].duration >= minEasy - 1 }
                let kept = drafts.reduce(0) { $0 + $1.duration } <= total + 1
                let underLong = drafts.indices.first(where: isLong).map { l in
                    drafts.indices.allSatisfy { !isEasy($0) || drafts[$0].duration <= drafts[l].duration + 1 }
                } ?? true
                // A shorter long run can shorten its steady finish: keep the 3.1 band.
                let band = Self.holdsBand(drafts, allEasy: ctx.allEasy)
                return easyOK && kept && band && underLong ? drafts : nil
            }
            if isQuality(k) {
                guard carry(k) else { return nil }
            } else if !moveEarlier(k, allowed: allowed) {
                guard cutDown(k, allowed: allowed) else { return nil }
            }
        }
        return nil
    }

    /// The race week's sharpener day, at least 3 days before the race, when the limits leave room for it.
    var sharpenerDay: Int? {
        let room = limits.maxQualitySessionsPerWeek - (limits.racesCountAsQuality ? 1 : 0)
        guard room >= 1 else { return nil }
        return PlanBuilder.pickQualityDays(available.filter { raceDay - $0 >= 3 }, count: 1, anchors: [raceDay]).first
    }

    // MARK: Run

    mutating func run() -> PlanBuildResult {
        let n = v.weekStarts.count
        let phases = phases(count: n)
        let raceWeek = n - 1
        let anchor = H.taperWeeks(c) == 1 ? raceWeek : raceWeek - 1

        if let mean = historyMean, v.recentWeekly > max(1.5 * mean, mean + 3600) {
            return .cannotBuild([.recentVolumeDisagreesWithHistory(recentWeeklySeconds: v.recentWeekly, historyWeeklySeconds: mean)])
        }
        if ledger.openWithoutReference {
            return .cannotBuild([.startWeekWithoutReference(rebuildOn: v.firstMonday)])
        }
        // Week 0 can be a recovery week only against a known week before; an
        // open start week with nothing above zero to measure against can't give one.
        // After an unknown week (#40), only against its known lower bound.
        let firstCanRecover = (ledger.scenarios.count == 1 && !ledger.lastUnknown) || (ledger.recoveryBase ?? 0) > 0
        guard var plannedRecovery = recoveryWeeks(anchor: anchor, startStreak: ledger.streak, firstCanRecover: firstCanRecover) else {
            return .cannotBuild([.historyVolumeUnknown(
                rebuildOn: PlanCalendar.nextWeekStart(after: v.firstMonday, timeZone: timeZone))])
        }

        let raceShare = H.raceWeekTrainingShare(c)
        // The race needs no room under the weekly caps (3.5 rule 3, #62), so
        // the peak is set by the recent level alone.
        let peakTarget = v.recentWeekly * (1 + H.peakGrowth(c))
        let sharpener = sharpenerDay
        var raceHard: [Int] = [raceWeek * 7 + raceDay]
        if let d = sharpener { raceHard.append(raceWeek * 7 + d) }

        var weeks: [TrainingPlanWeek] = []
        var notes = v.notes
        var level = v.recentWeekly
        var leveled = false
        var prevLong = input.recentLongRunSeconds ?? v.recentWeekly / Double(max(3, available.count))
        var peakReached = 0.0
        let minWeek = H.minimumWeekSeconds

        let openStartWeek = ledger.scenarios.count > 1
        var firstWeekRecovery = false
        var allEasyWeeks: Set<Int> = []
        var keptSmaller: [Int] = []
        for i in 0..<raceWeek {
            if i == 1 && openStartWeek, let later = recoveryWeeks(anchor: anchor, startStreak: ledger.streak,
                                                                  firstCanRecover: true, from: 1) {
                // Week 0 may reset the streak in some ways the start week can
                // end and not in others (#48): place the rest from the longest.
                plannedRecovery = later.union(plannedRecovery.filter { $0 == 0 })
            }
            let isTaper = phases[i] == .taper
            let cap = min(ledger.nextCap, ledger.spreadCap) * margin
            let forced = ledger.streak >= maxBuildRun
            // A recovery week is 75% of the week before, rising toward the
            // checker's 80% (with margin) when 75% would fall under the floor.
            // After an open start week (#48) the week before is the lowest it
            // can end, already lighter than the likely week, so week 0 takes
            // the full 80% (with margin).
            let recoveryTarget = ledger.recoveryBase.flatMap { last -> Double? in
                guard last > 0 else { return nil }
                if i == 0 && openStartWeek { return limits.recoveryWeekMaxRatio * last * margin }
                return max(recoveryRatio * last, min(minWeek, limits.recoveryWeekMaxRatio * last * margin))
            }
            var recovery = plannedRecovery.contains(i) || forced
            // A planned (not forced) recovery week that can't be workable is skipped.
            if recovery && !forced && min(recoveryTarget ?? 0, cap) < minWeek { recovery = false }
            let floor = recovery ? H.minimumRecoveryWeekSeconds : minWeek

            let intended = leveled ? min(level * (1 + growth), peakTarget) : min(level, peakTarget)
            let desired = recovery ? min(recoveryTarget ?? recoveryRatio * level, cap) : min(intended, cap)
            guard desired >= floor else {
                if ledger.nextReferenceIsUnknownZero {
                    // The week before has unknown volume and nothing of known
                    // time: wait for a week of known volume (#40).
                    return .cannotBuild([.historyVolumeUnknown(
                        rebuildOn: PlanCalendar.nextWeekStart(after: v.weekStarts[i], timeZone: timeZone))])
                }
                return .cannotBuild([.noWorkableWeek(weekStart: v.weekStarts[i], allowedSeconds: max(0, desired))])
            }

            let weekDays = days(week: i)
            let long = longDay(week: i, raceWeek: raceWeek, days: weekDays)
            let spike = spikeCap(week: i, days: weekDays, earlier: history + weeks.flatMap(\.workouts))
            let sessionCap = min(maxSession, spike.cap)
            // Week 1 back after a short break holds no quality session and
            // week 2 at most one (3.5 rule 4); the long run's steady finish
            // then carries the week's harder running.
            let rampQuality = ledger.nextReturnRampMaxQuality ?? Int.max
            func context(sessionCap cap: Double) -> WeekContext {
                let longTarget: Double
                if isTaper { longTarget = 0.7 * prevLong } else if recovery { longTarget = 0.8 * prevLong } else {
                    // At most 10 minutes a week (F3) and within the spike rule (3.5 rule 1).
                    longTarget = min(prevLong + H.longRunStepSeconds, longRunCap, cap)
                }
                return WeekContext(phase: phases[i], recovery: recovery, taper: isTaper, floor: floor,
                                   longTarget: longTarget,
                                   qualityKinds: qualityKinds(phases[i], recovery: recovery, taper: isTaper),
                                   maxQuality: min(maxQuality(phases[i], recovery: recovery, volume: desired, sessionCap: cap),
                                                  rampQuality),
                                   days: weekDays, longDay: long,
                                   excludedQualityDays: excludedQualityDays(week: i, extraHard: i == raceWeek - 1 ? raceHard : [Int]()),
                                   sessionCap: cap, longRaiseCap: min(prevLong + H.longRunStepSeconds, spike.cap),
                                   allEasy: rampQuality == 0)
            }
            // The week as it would be without the spike rule; only when one of
            // its sessions is too long for the rule is it drafted under the cap.
            var drafts = composeWeek(target: desired, ctx: context(sessionCap: maxSession))
            var spikeBound = false
            if !spikeHolds(drafts, week: i, spike: spike) {
                spikeBound = true
                drafts = holdTogether(target: desired, ctx: context(sessionCap: sessionCap), spike: spike)
            }
            // A recovery week at 75% of a small week can leave an easy run
            // under the floor; it may then take up to the recovery limit (with
            // margin) instead, when that leaves none under it and keeps the 3.1
            // band (heuristic). Every plan alike, whether or not the spike rule
            // has bound (#87).
            func shortEasy(_ d: [SessionDraft]) -> Bool { d.contains { $0.kind == .easy && $0.duration < H.minimumEasyRunSeconds } }
            // Since #79 no draft leaves an easy run under the floor; such a
            // week instead skips its long run or leaves easy time out, so the
            // retry also fires then and is kept when it holds more (heuristic).
            func total(_ d: [SessionDraft]) -> Double { d.reduce(0) { $0 + $1.duration } }
            func shortOfRoom(_ d: [SessionDraft]) -> Bool {
                total(d) < desired - 60 || (long != nil && !d.contains { $0.kind == .long })
            }
            if recovery, shortEasy(drafts) || shortOfRoom(drafts), let last = ledger.recoveryBase, last > 0 {
                let roomier = min(cap, limits.recoveryWeekMaxRatio * last * margin)
                if roomier > desired + 60 {
                    var retry = composeWeek(target: roomier, ctx: context(sessionCap: maxSession))
                    var retryBound = false
                    if !spikeHolds(retry, week: i, spike: spike) {
                        retryBound = true
                        retry = holdTogether(target: roomier, ctx: context(sessionCap: sessionCap), spike: spike)
                    }
                    if !shortEasy(retry), Self.holdsBand(retry, allEasy: rampQuality == 0),
                       shortEasy(drafts) || total(retry) > total(drafts) + 60 { drafts = retry; spikeBound = retryBound }
                }
            }
            drafts = Self.wordEasyRunLimit(drafts, asked: desired, days: weekDays.count)
            let training: Double = drafts.reduce(0.0) { $0 + $1.duration }
            let hard: Double = drafts.reduce(0.0) { $0 + $1.hardSeconds }
            guard training > 0 else {
                return .cannotBuild([.noWorkableWeek(weekStart: v.weekStarts[i], allowedSeconds: desired)])
            }
            let easyShare = 1 - hard / training
            if rampQuality == 0 { allEasyWeeks.insert(i) }
            guard (0.75...0.85).contains(easyShare) || (rampQuality == 0 && hard == 0) else {
                return .cannotBuild([.intensityDistributionNotMet(weekStart: v.weekStarts[i], easyShare: easyShare)])
            }
            let realized = training
            if diagnose {
                // The most hard time the week's sessions can hold at the
                // desired volume: every main set and steady finish asked for
                // far more than the band needs.
                let probeCtx = context(sessionCap: spikeBound ? sessionCap : maxSession)
                let probe = draftWeek(volume: desired, ctx: probeCtx, hardScale: 10)
                let reachable = rampQuality == 0 || (Self.hardShare(probe) ?? 0) >= H.hardShareBand.lowerBound
                diagnostics.append(.init(index: i, desired: desired, realized: realized, recovery: recovery,
                                         spikeBound: spikeBound, sessionCap: probeCtx.sessionCap,
                                         dayCount: weekDays.count, maxQuality: probeCtx.maxQuality,
                                         capacity: probe.reduce(0) { $0 + $1.duration }, bandReachable: reachable))
            }
            if !recovery && !isTaper {
                // The level only moves on when the week reached it; a week held
                // down by the guardrails (after a break) or the schedule keeps it.
                if realized >= 0.95 * intended { level = intended }
                leveled = true
                peakReached = max(peakReached, realized)
                // A week that skipped its long run (#79) leaves `prevLong` as it
                // was, so the next long run grows from the last one drafted.
                // That isn't the conservative choice (#106): when that older
                // run is longer than the skipped one would have been, the next
                // long run grows from the older, longer run. It still stays
                // within F3's 10-minute step over the last long run drafted.
                if let l = drafts.first(where: { $0.kind == .long }) { prevLong = l.duration }
            }
            hardDays += drafts.filter { $0.kind.isQuality }.map { i * 7 + $0.day }
            ledger.append(realized)
            if drafts.contains(where: { $0.purpose.contains(PlanBuilder.easyRunLimitMarker) }) {
                keptSmaller.append(i + 1)
            }
            weeks.append(week(i, phase: phases[i], drafts: drafts, race: nil))
            if i == 0 { firstWeekRecovery = recovery }
        }

        // Race week. The weekly caps measure its running outside the race
        // (3.5 rule 3, #62); only a recovery week the cadence requires (the
        // 5K's race week, or a long build streak) counts the race, as the
        // checker's recovery cadence does.
        var allowedTraining = ledger.nextCap * margin
        let forced = anchor == raceWeek || ledger.streak >= maxBuildRun
        if forced, let last = ledger.recoveryBase, last > 0 {
            let allowedTotal = recoveryRatio * last
            if allowedTotal < v.raceSeconds {
                return .cannotBuild([.volumeTooLowForRace(raceSeconds: v.raceSeconds, allowedRaceWeekSeconds: allowedTotal / margin)])
            }
            allowedTraining = min(allowedTraining, allowedTotal - v.raceSeconds)
        }
        allowedTraining = max(0, allowedTraining)
        let desiredTraining = raceShare * max(peakReached, level)
        if allowedTraining < desiredTraining * 0.5 {
            notes.append("Race week has little running besides the race: the load guardrails hold it below the usual taper (SPEC 3.5).")
        }
        let raceWeekDays = available.filter { $0 < raceDay }
        let raceSpike = spikeCap(week: raceWeek, days: raceWeekDays, earlier: history + weeks.flatMap(\.workouts))
        func raceWeekDrafts(_ cap: Double) -> [SessionDraft] {
            composeRaceWeek(training: min(desiredTraining, allowedTraining), sharpener: sharpener,
                            excluded: excludedQualityDays(week: raceWeek, extraHard: []), sessionCap: cap)
        }
        var raceDrafts = raceWeekDrafts(maxSession)
        if !spikeHolds(raceDrafts, week: raceWeek, spike: raceSpike) { raceDrafts = raceWeekDrafts(min(maxSession, raceSpike.cap)) }
        ledger.append(raceDrafts.reduce(0) { $0 + $1.duration } + v.raceSeconds, race: v.raceSeconds)
        weeks.append(week(raceWeek, phase: phases[raceWeek], drafts: raceDrafts, race: raceWorkout()))

        let planned = weeks.flatMap(\.workouts)
        // The plan's own easy-run limits (F3, #23) are checked with the rest.
        var checkLimits = limits
        checkLimits.maxTrainingRunSeconds = min(limits.maxTrainingRunSeconds, maxSession)
        checkLimits.easyRunsWithinLongRun = true
        let report = GuardrailChecker.check(history: history, planned: planned, timeZone: timeZone, limits: checkLimits)
        guard report.passed else { return .cannotBuild([.failsGuardrails(report)]) }

        // Label recovery weeks the way the checker reads them.
        let offset = ledger.count - weeks.count
        let labelled = weeks.map { w in
            TrainingPlanWeek(index: w.index, weekStart: w.weekStart, phase: w.phase,
                             isRecoveryWeek: ledger.isRecovery(offset + w.index), isRaceWeek: w.isRaceWeek, workouts: w.workouts)
        }
        // Final check: every training week has training and holds the 3.1 band.
        for w in labelled where !w.isRaceWeek && !allEasyWeeks.contains(w.index) {
            guard let share = w.easyShare else {
                return .cannotBuild([.noWorkableWeek(weekStart: w.weekStart, allowedSeconds: 0)])
            }
            guard (0.75...0.85).contains(share) else {
                return .cannotBuild([.intensityDistributionNotMet(weekStart: w.weekStart, easyShare: share)])
            }
        }
        if !keptSmaller.isEmpty {
            let list = keptSmaller.map(String.init).joined(separator: ", ")
            notes.append("Week\(keptSmaller.count == 1 ? "" : "s") \(list) \(keptSmaller.count == 1 ? "is" : "are") planned shorter than the volume the plan was aiming for, \(PlanBuilder.easyRunLimitMarker) (or past the long-run cap or your max session length) on your running days. Adding a running day would fit more (SPEC F3).")
        }
        var rebuildDate: Date?
        if startWeekOpen {
            rebuildDate = v.firstMonday
            let day = PlanFormatting.day(v.firstMonday, timeZone: timeZone)
            var note = "This week isn't over yet, so this plan is provisional: it keeps within the load guardrails however the rest of this week goes, which holds its first weeks back. It is rebuilt on Monday \(day) from the finished week (SPEC 3.5)."
            if firstWeekRecovery && !labelled[0].isRecoveryWeek {
                note += " Its first week is sized as a recovery week, in case this week ends as another build week."
            }
            notes.append(note)
        }
        return .plan(TrainingPlan(category: c, weeks: labelled, raceSeconds: v.raceSeconds, guardrailReport: report,
                                  notes: notes, rebuildDate: rebuildDate))
    }

    // MARK: Week content

    func qualityKinds(_ phase: PlanPhase, recovery: Bool, taper: Bool) -> [PlannedWorkout.QualityKind] {
        if recovery && !taper { return [.fartlek] }
        if taper { return c == .marathon || c == .fiveK ? [.racePace, .threshold] : [.racePace, .intervals] }
        switch (phase, c) {
        case (.base, _): return [.threshold, .fartlek]
        case (.build, .fiveK), (.build, .tenK): return [.intervals, .threshold]
        case (.build, _): return [.threshold, .racePace]
        case (.peak, .fiveK): return [.racePace, .threshold]
        case (.peak, .tenK), (.peak, .half): return [.racePace, .intervals]
        case (.peak, .marathon): return [.racePace, .threshold]
        case (.taper, _): return [.racePace]
        }
    }

    /// `sessionCap` is the longest a session may be this week (F2, and the
    /// spike rule, 3.5 rule 1, when it binds): a week whose sessions are held
    /// short runs on at least as many days as it takes to hold its volume
    /// under the cap, so the hard time can go on a second quality day rather
    /// than not fit (#105, heuristic, like `secondsPerRunDay`).
    func maxQuality(_ phase: PlanPhase, recovery: Bool, volume: Double, sessionCap: Double = .infinity) -> Int {
        var days = min(available.count, max(3, Int(volume / H.secondsPerRunDay)))
        if sessionCap.isFinite, sessionCap > 0, volume.isFinite {
            days = min(available.count, max(days, Int((volume / sessionCap).rounded(.up))))
        }
        var q: Int
        switch phase {
        case _ where recovery && phase != .taper: q = 1
        case .base: q = days >= 5 ? 2 : 1
        // The taper keeps two short sessions rather than one long one.
        case .build, .peak, .taper: q = days >= 4 ? 2 : 1
        }
        return max(0, min(q, limits.maxQualitySessionsPerWeek, available.count - 2))
    }

    func mainCap(_ kind: PlannedWorkout.QualityKind) -> Double {
        switch kind {
        case .threshold, .tempo: return 45 * 60
        case .intervals: return 32 * 60
        case .fartlek: return 36 * 60
        case .hills: return 20 * 60
        case .racePace:
            switch c {
            case .fiveK: return 28 * 60
            case .tenK: return 36 * 60
            case .half: return 50 * 60
            case .marathon: return 70 * 60
            }
        }
    }

    /// (rep, jog) in minutes and the intensity of the reps.
    func structure(_ kind: PlannedWorkout.QualityKind, phase: PlanPhase) -> (rep: Double, jog: Double, intensity: WorkoutIntensity) {
        switch kind {
        case .threshold, .tempo: return (phase == .base ? 8 : 10, 2, .threshold)
        case .intervals, .hills: return (3, 2, .vo2max)
        case .fartlek: return (2, 2, .steady)
        case .racePace:
            switch c {
            case .fiveK: return (4, 2, .racePace)
            case .tenK: return (6, 2, .racePace)
            case .half: return (12, 3, .racePace)
            case .marathon: return (20, 3, .racePace)
            }
        }
    }

    func segment(_ role: WorkoutSegment.Role, _ intensity: WorkoutIntensity, _ seconds: Double) -> WorkoutSegment {
        WorkoutSegment(role: role, intensity: intensity, durationSeconds: seconds, target: v.targets.target(intensity))
    }

    /// The race named by its own distance, not its category (#89): "10-mile race", "15K", or "race".
    var raceName: String { PlanFormatting.raceName(meters: input.raceDistanceMeters) ?? "race" }

    func bpm(_ x: Double?) -> String { x.map { "\(Int($0.rounded())) bpm" } ?? "" }

    /// A quality session with a main block of at most `main` seconds.
    func qualitySession(day: Int, kind: PlannedWorkout.QualityKind, main: Double, ctx: WeekContext,
                        warmUp: Double, coolDown: Double, sharpener: Bool = false) -> SessionDraft {
        let s = structure(kind, phase: ctx.phase)
        let rep = s.rep * 60, jog = s.jog * 60
        let reps = max(1, Int(((main + jog) / (rep + jog)).rounded(.down)))
        var segments = [segment(.warmUp, .easy, warmUp)]
        let work: Double
        if reps == 1 {
            work = PlanBuilder.floorMinute(main)
            segments.append(segment(.main, s.intensity, work))
        } else {
            work = PlanBuilder.floorMinute((main - Double(reps - 1) * jog) / Double(reps))
            for r in 0..<reps {
                segments.append(segment(.work, s.intensity, work))
                if r < reps - 1 { segments.append(segment(.jog, .repRecovery, jog)) }
            }
        }
        segments.append(segment(.coolDown, .easy, coolDown))
        let minutes = Int(work / 60)
        let set = reps == 1 ? "\(minutes) min" : "\(reps) × \(minutes) min with \(Int(s.jog)) min jogs"
        let purpose: String
        switch kind {
        case .threshold, .tempo:
            purpose = "Threshold: \(set) around lactate threshold, to raise the pace you can hold for an hour."
        case .intervals, .hills:
            purpose = "VO2max intervals: \(set), to raise aerobic capacity."
        case .fartlek:
            let surges = reps == 1 ? "\(minutes) min steady" : "\(reps) × \(minutes) min steady with \(Int(s.jog)) min easy"
            purpose = ctx.recovery
                ? "Fartlek: \(surges), to keep some rhythm in a lighter week."
                : "Fartlek: \(surges), to add faster running gently on top of the aerobic base."
        case .racePace:
            purpose = sharpener
                ? "Race-week sharpener: \(set) at race pace, to stay sharp without tiring."
                : "Race pace: \(set) at your \(raceName) pace, to rehearse the race effort."
        }
        var rules: [PlanRule] = sharpener || ctx.taper ? [.taper, .intensityDistribution, .qualityLimit]
            : [.intensityDistribution, .periodization, .qualityLimit]
        if ctx.recovery { rules.append(.recoveryWeek) }
        return SessionDraft(day: day, kind: .quality(kind), segments: segments, purpose: purpose, rules: rules)
    }

    func easySession(day: Int, seconds: Double, ctx: WeekContext) -> SessionDraft {
        let cap = v.targets.heartRate(.easy).ceilingBPM
        var rules: [PlanRule] = [.easyByHeartRate, .intensityDistribution, .weeklyProgression]
        if ctx.recovery { rules.append(.recoveryWeek) }
        if ctx.taper { rules.append(.taper) }
        return SessionDraft(day: day, kind: .easy, segments: [segment(.main, .easy, seconds)],
                            purpose: "Easy run: aerobic volume with little fatigue. Keep heart rate below \(bpm(cap)).",
                            rules: rules)
    }

    func longSession(day: Int, seconds: Double, finish: Double, ctx: WeekContext) -> SessionDraft {
        var segments = [segment(.main, .easy, seconds - finish)]
        if finish > 0 { segments.append(segment(.finish, .steady, finish)) }
        let tail = finish > 0 ? ", with the last \(Int(finish / 60)) min steady" : ""
        var rules: [PlanRule] = [.longRunShare, .singleRunSpike, .easyByHeartRate]
        if finish > 0 { rules.append(.intensityDistribution) }
        if ctx.recovery { rules.append(.recoveryWeek) }
        if ctx.taper { rules.append(.taper) }
        return SessionDraft(day: day, kind: .long, segments: segments,
                            purpose: "Long run: endurance for the \(raceName), easy by heart rate\(tail).", rules: rules)
    }

    static func hardShare(_ drafts: [SessionDraft]) -> Double? {
        let total = drafts.reduce(0) { $0 + $1.duration }
        guard total > 0 else { return nil }
        return drafts.reduce(0) { $0 + $1.hardSeconds } / total
    }

    /// True when the week's hard share is in the 3.1 band, or, for week 1
    /// back after a short break (`WeekContext.allEasy`), when it has no hard
    /// running at all.
    static func holdsBand(_ drafts: [SessionDraft], allEasy: Bool) -> Bool {
        guard let share = hardShare(drafts) else { return false }
        return allEasy ? share == 0 : H.hardShareBand.contains(share)
    }

    /// The week's sessions for a target training time, with 16 to 24% of the
    /// time above the aerobic threshold. The result may be shorter than
    /// `target` (rounding, session caps, or a week shortened to keep the hard
    /// share in band), never longer. When nothing fits the band it returns
    /// its closest attempt, and the caller refuses the plan.
    func composeWeek(target: Double, ctx: WeekContext) -> [SessionDraft] {
        // Week 1 back after a short break is all easy (3.5 rule 4).
        if ctx.allEasy { return draftWeek(volume: target, ctx: ctx.with(maxQuality: 0), hardScale: 0) }
        // A small week can't fit a quality session's smallest main set inside
        // the band; then fewer quality sessions (down to none, with the long
        // run's steady finish as the week's harder running) are tried.
        let first = composeWeek(target: target, ctx: ctx, quality: ctx.maxQuality)
        if let share = Self.hardShare(first), !H.hardShareBand.contains(share) {
            for q in stride(from: ctx.maxQuality - 1, through: 0, by: -1) {
                let d = composeWeek(target: target, ctx: ctx, quality: q)
                if let s = Self.hardShare(d), H.hardShareBand.contains(s) { return d }
            }
        }
        return first
    }

    /// The most shortening or hard-share steps `composeWeek` takes before
    /// its coarse fallback search.
    static let composeSteps = 12

    /// The loop cap of `composeWeek`, derived from the step count (#99).
    /// Raises of `hardScale` (whole-minute rounding under the band, #87)
    /// don't count as steps but do count here. Each raise multiplies
    /// `hardScale` by more than (lower bound + 0.01) / lower bound, about
    /// 1.0625, up to 1.5, so a run of raises from a scale of 1 has at most
    /// ceil(log 1.5 / log 1.0625) = 7 of them; the cap allows that many
    /// before every step: 12 × 8 = 96. A run that starts lower (after a step
    /// down for a share over the band) may need one or two more, so a build
    /// can in principle still reach the cap; it then falls through to the
    /// coarse search below, which is safe, only coarser. On a grid of 6,528
    /// plan inputs and the whole test suite, no week used more than 24
    /// iterations or 7 raises in a row, and the plans are the same under a
    /// cap of 48, 96 or 1,000 (heuristic bound, not a proof).
    static let composeIterationCap: Int = {
        let lower = H.hardShareBand.lowerBound
        let raises = Int((log(1.5) / log((lower + 0.01) / lower)).rounded(.up))
        return composeSteps * (raises + 1)
    }()

    private func composeWeek(target: Double, ctx full: WeekContext, quality: Int) -> [SessionDraft] {
        let ctx = full.with(maxQuality: quality)
        var volume = target
        var hardScale = 1.0
        var drafts: [SessionDraft] = []
        // The draft before the first raise of `hardScale` in a row, to fall back on.
        var beforeRaise: (drafts: [SessionDraft], hard: Double, scale: Double)?
        var steps = 0
        for _ in 0..<Self.composeIterationCap where steps < Self.composeSteps {
            drafts = draftWeek(volume: volume, ctx: ctx, hardScale: hardScale)
            guard let share = Self.hardShare(drafts) else { return drafts }
            var hard = drafts.reduce(0) { $0 + $1.hardSeconds }
            if share < H.hardShareBand.lowerBound && hardScale < 1.5 {
                // Whole-minute reps (and a steady finish only from a whole
                // minute short) can round a small week's hard time under the
                // band, which would shrink the week to about hard / 0.165
                // (#87): ask for a little more hard time before shortening it
                // (heuristic). These raises don't count as steps.
                if beforeRaise == nil { beforeRaise = (drafts, hard, hardScale) }
                hardScale = min(1.5, hardScale * (H.hardShareBand.lowerBound + 0.01) / share)
                continue
            }
            steps += 1
            if share < H.hardShareBand.lowerBound {
                // The quality caps can't carry enough hard time: shorten the week.
                if let b = beforeRaise, hard <= b.hard {
                    // Asking for more added no hard time (the caps and the
                    // steady finish are full): shorten from the draft before
                    // the raises, as if they had never been tried.
                    drafts = b.drafts
                    hard = b.hard
                    hardScale = b.scale
                }
                beforeRaise = nil
                volume = min(volume - 60, hard / (H.hardShareBand.lowerBound + 0.005))
            } else if share > H.hardShareBand.upperBound {
                beforeRaise = nil
                hardScale *= (H.hardShareBand.upperBound - 0.01) / share
            } else {
                return drafts
            }
            if volume < ctx.floor { break }
        }
        // Fallback: a coarse search over shorter weeks and other hard shares,
        // longest week first.
        for factor in stride(from: 1.0, through: 0.5, by: -0.05) {
            for scale in [1.0, 0.9, 1.1, 0.8, 1.2, 0.7, 0.6, 0.5] {
                let d = draftWeek(volume: target * factor, ctx: ctx, hardScale: scale)
                if let share = Self.hardShare(d), H.hardShareBand.contains(share) { return d }
            }
        }
        return drafts
    }

    /// `skipLong` drafts the week without a long run, its time going to easy
    /// running (#79); `draftWeek` sets it itself when the long run would end
    /// under the easy-run floor.
    func draftWeek(volume target: Double, ctx: WeekContext, hardScale: Double, skipLong: Bool = false) -> [SessionDraft] {
        // No week asks for more than its sessions can hold.
        let maxSession = ctx.sessionCap
        let volume = min(target, Double(ctx.days.count) * maxSession)
        // Too little room for a long run and a quality session: leave the week empty.
        guard volume >= ctx.floor, !ctx.days.isEmpty else { return [] }
        let small = volume < 150 * 60
        let warmUp: Double = small ? H.shortWarmUpSeconds : 15 * 60
        let coolDown: Double = small ? H.shortCoolDownSeconds : 10 * 60
        let estDays = min(ctx.days.count, max(3, Int(volume / H.secondsPerRunDay)))

        // Long run.
        let share = min(H.longRunShare(runDays: estDays), limits.maxLongRunShare - 0.02)
        var long = ctx.longDay == nil ? 0
            : PlanBuilder.floorMinute(min(ctx.longTarget, longRunRoom(total: volume, usualShare: share), longRunCap,
                                          maxSession))
        let longDays = long > 0 ? [ctx.longDay!] : []

        // Quality days and main sets.
        var hard = H.hardShare(ctx.phase, recovery: ctx.recovery) * volume * hardScale
        var q = min(ctx.maxQuality, ctx.qualityKinds.count, max(0, ctx.days.count - 2))
        while q > 1 && hard < Double(q) * H.minimumMainSetSeconds { q -= 1 }
        // A quality day needs room for the warm-up, the smallest main set and
        // the cool-down, at their shortest (`PlanHeuristics.shortWarmUpSeconds`).
        let shortest = shortenWarmUps ? H.shortWarmUpSeconds + H.shortCoolDownSeconds : warmUp + coolDown
        let candidates = ctx.days.filter { !longDays.contains($0) }
            .filter { _ in maxSession - shortest >= H.minimumMainSetSeconds }
        var qDays = PlanBuilder.pickQualityDays(candidates, count: q, anchors: longDays, excluded: ctx.excludedQualityDays)
        // The long run's steady finish can carry this much of the hard time.
        let finishRoom = long >= 40 * 60 && !ctx.taper ? PlanBuilder.floorMinute(H.longRunFinishShare * long) : 0
        // A session cap too short for the smallest main set with the usual
        // warm-up and cool-down leaves the hard time to the steady finish when
        // it can carry all of it, as before #105.
        if maxSession - warmUp - coolDown < H.minimumMainSetSeconds && hard <= finishRoom { qDays = [] }
        q = qDays.count
        if q > 0 { hard = max(hard, H.minimumMainSetSeconds) }
        func fill(overhead: Double) -> (mains: [Double], left: Double) {
            let caps = (0..<q).map { min(mainCap(ctx.qualityKinds[$0]), maxSession - overhead) }
            var mains = [Double](repeating: 0, count: q)
            var left = hard
            for _ in 0..<3 where left > 1 {
                let open = (0..<q).filter { mains[$0] < caps[$0] }
                guard !open.isEmpty else { break }
                let each = left / Double(open.count)
                for k in open {
                    let add = min(each, max(0, caps[k] - mains[k]))
                    mains[k] += add
                    left -= add
                }
            }
            return (mains, left)
        }
        var (mains, left) = fill(overhead: warmUp + coolDown)
        var warmUps = [Double](repeating: warmUp, count: q)
        var coolDowns = [Double](repeating: coolDown, count: q)
        // When the session cap (the max session length, F2, or the spike
        // rule, 3.5 rule 1) leaves the main sets too little room for the
        // week's hard time, and the long run's steady finish can't carry the
        // rest, the main sets may use the room of a shorter warm-up and
        // cool-down (down to a small week's) so the hard time fits inside the
        // cap and the week reaches the 3.1 band at its volume rather than
        // being shortened to it (#105, heuristic; SPEC sets no warm-up length).
        if q > 0, warmUp + coolDown > shortest {
            let tight = fill(overhead: shortest)
            let mainTooShort = maxSession - warmUp - coolDown < H.minimumMainSetSeconds
            if mainTooShort || (left > finishRoom + 60 && tight.left < left - 60) {
                (mains, left) = tight
                // Decided per session (#113): a session gives up only the
                // warm-up and cool-down time its own main set needs under the
                // cap. One whose main set is held by its kind's main-set cap
                // (`mainCap`), or by the week's hard time, keeps 15 and 10
                // minutes, so it is no shorter than before and adds no hard
                // time; one the cap holds is cut only as far as its main set
                // reaches, at most to 10 and 5, and stays at the cap. The cut
                // is shared evenly, the warm-up keeping the odd minute.
                let usual = warmUp + coolDown
                for k in 0..<q {
                    let held = qualitySession(day: qDays[k], kind: ctx.qualityKinds[k], main: mains[k], ctx: ctx,
                                              warmUp: 0, coolDown: 0).duration
                    let room = maxSession.isFinite ? PlanBuilder.floorMinute(max(0, maxSession - held)) : usual
                    let cut = usual - min(usual, max(shortest, room))
                    let warmCut = PlanBuilder.floorMinute(cut / 2)
                    warmUps[k] = warmUp - warmCut
                    coolDowns[k] = coolDown - (cut - warmCut)
                }
            }
        }
        let quality = (0..<q).map {
            qualitySession(day: qDays[$0], kind: ctx.qualityKinds[$0], main: mains[$0], ctx: ctx,
                           warmUp: warmUps[$0], coolDown: coolDowns[$0])
        }
        let qualityHard = quality.reduce(0) { $0 + $1.hardSeconds }
        // A marathon long run above its usual length (3.5 rule 5) never leaves
        // the easy time under the easy floor: it gives back up to its extra
        // time first (heuristic; the usual share would have left that room).
        let usualLong = ctx.longDay == nil ? 0
            : PlanBuilder.floorMinute(min(ctx.longTarget, share * volume, longRunCap, maxSession))
        let easyLeft = volume - long - quality.reduce(0) { $0 + $1.duration }
        if usualLong > 0, long > usualLong, easyLeft > 0, easyLeft < H.minimumEasyRunSeconds,
           ctx.days.contains(where: { !longDays.contains($0) && !qDays.contains($0) }) {
            long -= min(long - usualLong, ((H.minimumEasyRunSeconds - easyLeft) / 60).rounded(.up) * 60)
        }
        // No drafted run is shorter than the easy-run floor (#79). A long run
        // that would be (a small recovery or taper week, a short recent long
        // run, a tight session cap) is raised to the floor, taking the time
        // from easy running, when the floor fits every long-run limit: its
        // share of the week (3.5 rule 5), the spike allowance (3.5 rule 1),
        // the F3 10-minute step (`ctx.longRaiseCap`) and the session cap.
        // Otherwise it is skipped this week and its time goes to easy
        // running; its day stays free of quality sessions and takes an easy
        // run that says why. Heuristic: SPEC 3.5 rule 5 sets no shortest long run.
        let qualityTime = quality.reduce(0) { $0 + $1.duration }
        var skippedLong = skipLong && long > 0
        if skippedLong {
            long = 0
        } else if long > 0 && long < H.minimumEasyRunSeconds {
            let room = min(PlanBuilder.floorMinute(longRunRoom(total: volume, usualShare: limits.maxLongRunShare - 0.02)),
                           ctx.longRaiseCap, maxSession, longRunCap, volume - qualityTime)
            if room >= H.minimumEasyRunSeconds {
                long = H.minimumEasyRunSeconds
            } else {
                long = 0
                skippedLong = true
            }
        }
        // Easy time under the floor that the first quality session's cool-down
        // can't take would be left out (and can push the long run over its
        // share): the long run gives back the few minutes that make it an easy
        // run at the floor, when the long run stays at the floor itself (#79,
        // heuristic).
        let easyShort = volume - long - qualityTime
        let coolRoom = q > 0 ? maxSession - quality[0].duration : 0
        if long > 0, easyShort > 60, easyShort < H.minimumEasyRunSeconds, coolRoom < easyShort,
           ctx.days.contains(where: { !longDays.contains($0) && !qDays.contains($0) }) {
            let need = ((H.minimumEasyRunSeconds - easyShort) / 60).rounded(.up) * 60
            if long - need >= H.minimumEasyRunSeconds { long -= need }
        }
        // Top up with a steady long-run finish when the quality caps run out.
        var finish = 0.0
        let shortfall = hard - qualityHard
        if shortfall > 60 && long >= 40 * 60 && !ctx.taper {
            finish = PlanBuilder.floorMinute(min(max(shortfall, 5 * 60), H.longRunFinishShare * long))
        }

        // Easy runs fill the rest. Easy time too short for a run of its own
        // (under the easy-run floor, a small week) lengthens the first quality
        // session's cool-down, then the long run (below), and what is still
        // left is left out with a note on the week.
        var drafts = quality
        if long > 0 { drafts.append(longSession(day: ctx.longDay!, seconds: long, finish: finish, ctx: ctx)) }
        var easyTotal = volume - long - quality.reduce(0) { $0 + $1.duration }
        if easyTotal > 60 && easyTotal < H.minimumEasyRunSeconds, q > 0 {
            let extra = PlanBuilder.floorMinute(min(easyTotal, maxSession - quality[0].duration))
            if extra > 0 {
                coolDowns[0] += extra
                drafts[0] = qualitySession(day: qDays[0], kind: ctx.qualityKinds[0], main: mains[0], ctx: ctx,
                                           warmUp: warmUps[0], coolDown: coolDowns[0])
                easyTotal -= extra
            }
        }
        let open = ctx.days.filter { !longDays.contains($0) && !qDays.contains($0) }
        // A skipped long run's day takes the first easy run.
        let free = skippedLong ? longDays + open : open
        // No easy run is longer than the week's long run, or than the session
        // cap (max session length and long-run cap, `maxSession`) in a week
        // with none (F3, #23).
        let easyCap = long > 0 ? min(maxSession, long) : maxSession
        var cutByLimit = 0.0
        if easyTotal >= H.minimumEasyRunSeconds && !free.isEmpty {
            var count = max(1, min(free.count, Int(easyTotal / H.secondsPerRunDay)))
            while count > 1 && easyTotal / Double(count) < H.minimumEasyRunSeconds { count -= 1 }
            // More, shorter runs when they would be too long, never one under the easy floor.
            while count < free.count && easyTotal / Double(count) > min(easyCap, max(long, 45 * 60))
                && easyTotal / Double(count + 1) >= H.minimumEasyRunSeconds { count += 1 }
            let each = PlanBuilder.floorMinute(min(easyTotal / Double(count), easyCap))
            let days = skippedLong ? longDays + PlanBuilder.pickEasyDays(open, count: count - 1, taken: qDays + longDays)
                : PlanBuilder.pickEasyDays(open, count: count, taken: qDays + longDays)
            if each >= H.minimumEasyRunSeconds {
                drafts += days.map { easySession(day: $0, seconds: each, ctx: ctx) }
                // Easy time the limit above holds back is not piled on one
                // run: the quality sessions' cool-down takes it, then the week
                // is planned smaller (below).
                easyTotal = easyTotal / Double(count) > easyCap ? easyTotal - each * Double(count) : 0
                if easyTotal > 0 { cutByLimit = easyTotal }
            }
        }
        // Time the easy-run limit holds back goes, after other easy runs and free
        // days (the count loop above), to the quality sessions' easy cool-down,
        // so the hard minutes stay as planned: each quality session may grow up
        // to the week's long run, the long-run cap and the max session length
        // (`easyCap`). Only what still doesn't fit shrinks the week. A
        // heuristic ordering: SPEC F3 says only that the week plans smaller
        // when its volume doesn't fit (F3, #23). It never goes to the long
        // run, which would only raise the limit it was held to.
        let heldBack = cutByLimit
        if cutByLimit >= 60 {
            for j in 0..<q where cutByLimit >= 60 {
                let room = PlanBuilder.floorMinute(min(cutByLimit, easyCap - drafts[j].duration))
                guard room >= 60 else { continue }
                coolDowns[j] += room
                drafts[j] = qualitySession(day: qDays[j], kind: ctx.qualityKinds[j], main: mains[j], ctx: ctx,
                                           warmUp: warmUps[j], coolDown: coolDowns[j])
                cutByLimit -= room
            }
        }
        // Easy time left with no run of its own lengthens the long run within
        // its limits (share, spike allowance, F3 step, session cap); what
        // still doesn't fit is left out, and the week says so (#79).
        easyTotal -= heldBack
        if easyTotal >= 60, let li = drafts.firstIndex(where: { $0.kind == .long }) {
            let rest = drafts.reduce(0) { $0 + $1.duration } - drafts[li].duration
            let limit = min(longRunFit(rest: rest), ctx.longRaiseCap, maxSession, longRunCap)
            let extra = PlanBuilder.floorMinute(min(easyTotal, limit - drafts[li].duration))
            if extra >= 60 {
                drafts[li] = longSession(day: drafts[li].day, seconds: drafts[li].duration + extra, finish: finish, ctx: ctx)
                easyTotal -= extra
            }
        }
        // Only easy time actually dropped is stated (#106). The minutes the
        // long run loses to its share trim below are long-run time, not easy
        // running too short for a run, so the note doesn't count them.
        let leftOut = easyTotal >= 60 ? PlanBuilder.floorMinute(easyTotal) : 0
        var limitOut = cutByLimit >= 60 ? PlanBuilder.floorMinute(cutByLimit) : 0
        // If easy time was dropped, the long run could exceed its share of what
        // is left: shorten it to fit (3.5).
        // A shorter long run lowers the limit on the week's easy runs (F3,
        // #23): an easy run over it is cut to it, its time kept out of the
        // week, which shrinks the rest and can shorten the long run again.
        for _ in 0..<24 {
            var changed = false
            if let i = drafts.firstIndex(where: { $0.kind == .long }) {
                let rest = drafts.reduce(0) { $0 + $1.duration } - drafts[i].duration
                let fit = longRunFit(rest: rest)
                if drafts[i].duration > fit {
                    if fit < H.minimumEasyRunSeconds {
                        // Too short to keep (#79): the week goes without a long
                        // run, drafted again with its time as easy running.
                        guard skipLong else { return draftWeek(volume: target, ctx: ctx, hardScale: hardScale, skipLong: true) }
                        drafts.remove(at: i)
                    } else {
                        let f = min(finish, PlanBuilder.floorMinute(H.longRunFinishShare * fit))
                        drafts[i] = longSession(day: ctx.longDay!, seconds: fit, finish: f, ctx: ctx)
                    }
                    changed = true
                }
            }
            let limit = drafts.first(where: { $0.kind == .long })?.duration ?? maxSession
            for k in drafts.indices where drafts[k].kind == .easy && drafts[k].duration > limit + 1 {
                let to = PlanBuilder.floorMinute(limit)
                limitOut += PlanBuilder.floorMinute(drafts[k].duration - to)
                drafts[k] = easySession(day: drafts[k].day, seconds: to, ctx: ctx)
                changed = true
            }
            if !changed { break }
        }
        drafts.sort { $0.day < $1.day }
        if skippedLong, let day = ctx.longDay { drafts = Self.noteSkippedLongRun(drafts, longDay: day) }
        if limitOut >= 60 || heldBack >= 60 { drafts = Self.tagEasyRunLimit(drafts) }
        if leftOut > 0 { drafts = Self.noteLeftOut(drafts, seconds: leftOut, freeDay: !free.isEmpty) }
        return drafts
    }

    /// Tags the week's first session as held below its volume by the
    /// easy-run limit (F3, #23); `Builder.run` words the note.
    static func tagEasyRunLimit(_ drafts: [SessionDraft]) -> [SessionDraft] {
        guard let d = drafts.first, !d.purpose.contains(PlanBuilder.easyLimitToken) else { return drafts }
        var out = drafts
        out[0] = SessionDraft(day: d.day, kind: d.kind, segments: d.segments, purpose: d.purpose + " " + PlanBuilder.easyLimitToken,
                              rules: d.rules)
        return out
    }

    /// Replaces the token with the note stating the week against `asked`, or
    /// removes it when the week is within a minute of it (F3, #23).
    static func wordEasyRunLimit(_ drafts: [SessionDraft], asked: Double, days: Int) -> [SessionDraft] {
        guard let k = drafts.firstIndex(where: { $0.purpose.contains(PlanBuilder.easyLimitToken) }) else { return drafts }
        let planned = drafts.reduce(0) { $0 + $1.duration }
        let d = drafts[k]
        let text = planned < asked - 60
            ? PlanBuilder.easyRunLimitNote(planned: planned, asked: asked, days: days) : ""
        var out = drafts
        out[k] = SessionDraft(day: d.day, kind: d.kind, segments: d.segments,
                              purpose: d.purpose.replacingOccurrences(of: " " + PlanBuilder.easyLimitToken, with: text.isEmpty ? "" : " " + text),
                              rules: d.rules)
        return out
    }

    /// Says on the week's first session how much easy time was left out
    /// (#79), and why (#106), so the shortfall isn't silent.
    static func noteLeftOut(_ drafts: [SessionDraft], seconds: Double, freeDay: Bool) -> [SessionDraft] {
        guard let d = drafts.first, let why = PlanBuilder.leftOutNote(seconds: seconds, freeDay: freeDay) else { return drafts }
        var out = drafts
        out[0] = SessionDraft(day: d.day, kind: d.kind, segments: d.segments, purpose: d.purpose + " " + why, rules: d.rules)
        return out
    }

    /// Says why a week has no long run (#79): on the easy run on the long
    /// run's day when there is one, or else on the week's first session.
    static func noteSkippedLongRun(_ drafts: [SessionDraft], longDay: Int) -> [SessionDraft] {
        let floor = Int(H.minimumEasyRunSeconds / 60)
        let why = "this week's long run would be under \(floor) min, the shortest run the plan schedules."
        guard !drafts.isEmpty else { return drafts }
        let k = drafts.firstIndex { $0.day == longDay && $0.kind == .easy } ?? 0
        let d = drafts[k]
        let purpose = d.day == longDay && d.kind == .easy
            ? "Easy run in place of the long run: \(why) " + d.purpose
            : d.purpose + " No long run this week: " + why
        var out = drafts
        out[k] = SessionDraft(day: d.day, kind: d.kind, segments: d.segments, purpose: purpose, rules: d.rules)
        return out
    }

    func composeRaceWeek(training: Double, sharpener: Int?, excluded: Set<Int>, sessionCap: Double) -> [SessionDraft] {
        let maxSession = sessionCap
        let ctx = WeekContext(phase: .taper, recovery: false, taper: true, floor: H.minimumWeekSeconds, longTarget: 0,
                              qualityKinds: [.racePace], maxQuality: 1, days: available, longDay: nil,
                              excludedQualityDays: excluded, sessionCap: sessionCap)
        let days = available.filter { $0 < raceDay }
        guard training >= 15 * 60, !days.isEmpty else { return [] }
        var drafts: [SessionDraft] = []
        var left = training
        // One short sharpener at least 3 days out, never next to the week before's last hard day.
        if let day = sharpener, !excluded.contains(day), training >= 45 * 60, maxSession - 15 * 60 >= H.minimumMainSetSeconds {
            let main = PlanBuilder.floorMinute(min(max(H.minimumMainSetSeconds, 0.2 * training), 20 * 60,
                                                   maxSession - 15 * 60))
            let s = qualitySession(day: day, kind: .racePace, main: main, ctx: ctx, warmUp: 10 * 60, coolDown: 5 * 60,
                                   sharpener: true)
            if s.duration <= left { drafts.append(s); left -= s.duration }
        }
        let free = days.filter { d in !drafts.contains { $0.day == d } }
        // No easy run under the easy-run floor (#79): shorter leftovers are left out.
        if left >= H.minimumEasyRunSeconds && !free.isEmpty {
            var count = max(1, min(free.count, Int(left / (30 * 60))))
            while count > 1 && left / Double(count) < H.minimumEasyRunSeconds { count -= 1 }
            let each = PlanBuilder.floorMinute(min(left / Double(count), maxSession))
            let chosen = PlanBuilder.pickEasyDays(free, count: count, taken: drafts.map(\.day) + [raceDay])
            if each >= H.minimumEasyRunSeconds {
                drafts += chosen.map { easySession(day: $0, seconds: each, ctx: ctx) }
                left = 0
            }
        }
        drafts.sort { $0.day < $1.day }
        let leftOut = left >= 60 ? PlanBuilder.floorMinute(left) : 0
        return Self.noteLeftOut(drafts, seconds: leftOut, freeDay: !free.isEmpty)
    }

    func raceWorkout() -> PlannedWorkout {
        let seg = segment(.main, .race, v.raceSeconds)
        let meters = input.raceDistanceMeters
        let p = WorkoutPrescription(purpose: PlanFormatting.raceDayPurpose(meters: meters), phase: .taper,
                                    segments: [seg], rules: [.goalRace], raceDistanceMeters: meters)
        return PlannedWorkout(id: "plan-race", date: input.raceDate, kind: .race, durationSeconds: v.raceSeconds,
                              distanceMeters: input.raceDistanceMeters, prescription: p)
    }

    func week(_ i: Int, phase: PlanPhase, drafts: [SessionDraft], race: PlannedWorkout?) -> TrainingPlanWeek {
        var workouts = drafts.map { d -> PlannedWorkout in
            let tag: String
            switch d.kind {
            case .long: tag = "long"
            case .quality(let k): tag = k.rawValue
            default: tag = "easy"
            }
            let p = WorkoutPrescription(purpose: d.purpose, phase: phase, segments: d.segments, rules: d.rules)
            return PlannedWorkout(id: "plan-w\(i)-d\(d.day)-\(tag)", date: sessionDate(week: i, day: d.day), kind: d.kind,
                                  durationSeconds: d.duration, distanceMeters: nil, prescription: p)
        }
        if let race { workouts.append(race) }
        return TrainingPlanWeek(index: i, weekStart: v.weekStarts[i], phase: phase, isRecoveryWeek: false,
                                isRaceWeek: race != nil, workouts: workouts)
    }
}
