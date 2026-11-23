import Foundation

/// A plan built from the goal settings and the baseline (F2, F3).
public struct GoalPlan: Equatable, Sendable {
    public let settings: GoalSettings
    /// The merged input the plan was built from.
    public let input: PlanInput
    public let plan: TrainingPlan
    /// The runner's completed runs the plan was checked against.
    public let history: [PlannedWorkout]
    /// The 3.5 checker's report on the plan, run again here with the history
    /// and any pain freezes in force (`PainCheckInRule`), after the builder's
    /// own check. It always passes; a failure is returned as an issue instead.
    public let guardrailReport: GuardrailReport

    /// True when the pain check-in applies (SPEC 3.5).
    public var tracksPain: Bool { settings.painHistory.tracksPain }

    /// When the plan is provisional (planned after its start week began),
    /// the moment the app must re-plan: the start of the plan's first Monday
    /// in the runner's time zone. Call `plan` (or `replan`) again then, with
    /// a baseline built as of that moment, so the finished start week is
    /// history (`TrainingPlan.rebuildDate`, #48). Nil for a final plan.
    ///
    /// A late re-plan must still pass this date as `today`, with the
    /// baseline built as of this date too (`BaselineOptions.asOf`), not the
    /// moment the app gets to it. From a later moment, a run logged early
    /// that Monday, or a time past noon, would start the plan on the next
    /// Monday and leave this week open, so the re-plan would be provisional
    /// again. `ProvisionalRebuild.due` gives the `today` to pass (#55).
    public var rebuildDate: Date? { plan.rebuildDate }
}

/// Why no plan was made. The previous plan, if any, stays in place.
public enum GoalPlanIssue: Equatable, Sendable {
    /// The settings fail the interview's checks as of today.
    case invalidSettings([GoalProblem])
    /// The baseline is dated after today.
    case baselineAfterToday(asOf: Date)
    /// The baseline is from an earlier day than today (in its time zone), or
    /// more than `GoalHeuristics.maximumBaselineAgeSeconds` before today.
    /// Runs logged since then are missing: the builder would read those days
    /// as empty and could plan far below the runner's load, or break 3.5
    /// against the real history. Rebuild the baseline as of now before every
    /// plan or re-plan.
    case baselineOutOfDate(asOf: Date, today: Date)
    /// The plan builder refused; the issues say why (for example no LTHR yet).
    case cannotBuild([PlanBuildIssue])
    /// The built plan broke a guardrail in the independent check (for example
    /// growth inside a pain freeze, which the builder doesn't see).
    ///
    /// Known limit: `PlanBuilder` takes no freezes, so while a freeze is in
    /// force, any plan or goal edit that grows a frozen week is refused with
    /// this issue (safe, but it blocks edits until the freeze ends, at most a
    /// week). The previous plan stays, and the adaptation engine (F4) holds
    /// its volume through the freeze.
    case failsGuardrails(GuardrailReport)
}

public enum GoalPlanResult: Equatable, Sendable {
    case plan(GoalPlan)
    case cannotPlan([GoalPlanIssue])

    public var plan: GoalPlan? {
        if case .plan(let p) = self { return p }
        return nil
    }

    public var issues: [GoalPlanIssue] {
        if case .cannotPlan(let i) = self { return i }
        return []
    }
}

/// One change a goal edit made (F2: "with the changes explained").
public enum GoalChange: Equatable, Sendable {
    case raceName(from: String, to: String)
    case raceDate(from: Date, to: Date)
    case raceDistance(fromMeters: Double, toMeters: Double)
    case goalTime(from: GoalTime, to: GoalTime)
    case trainingDays(from: Set<PlanWeekday>, to: Set<PlanWeekday>)
    case longRunDay(from: PlanWeekday, to: PlanWeekday)
    case maxSession(from: SessionLimit, to: SessionLimit)
    case treadmillAccess(from: Bool, to: Bool)
    case painHistory(from: PainHistory, to: PainHistory)
}

/// How the new plan differs from the one it replaces.
public struct PlanChangeSummary: Equatable, Sendable {
    public let previousWeeks: Int
    public let newWeeks: Int
    /// Largest weekly training time (race excluded), in seconds.
    public let previousPeakWeekSeconds: Double
    public let newPeakWeekSeconds: Double
    public let previousRaceSeconds: Double
    public let newRaceSeconds: Double
}

/// The outcome of a goal edit: what changed, the new plan or why there is
/// none, and plain-English sentences the LLM layer can word for the runner
/// (it explains; it never changes a number).
///
/// The new plan starts on the Monday after today (or today, on a Monday no
/// later than noon with nothing logged), like every `PlanBuilder` plan. The
/// rest of the current week is not re-planned. The previous plan's sessions
/// from today up to the new plan's first week are kept only when the whole
/// timeline (history, kept sessions and the new plan) passes the 3.5
/// checker; otherwise they are dropped and listed in `droppedThisWeek`.
public struct GoalReplan: Equatable, Sendable {
    public let changes: [GoalChange]
    public let result: GoalPlanResult
    /// Nil when there was no previous plan or no new one.
    public let planChanges: PlanChangeSummary?
    /// The previous plan's sessions for the rest of the current week that
    /// stay: checked with the history and the new plan. Empty when there is
    /// no new plan.
    public let keptThisWeek: [PlannedWorkout]
    /// The previous plan's sessions for the rest of the current week that
    /// were dropped: on a day that is no longer a training day, or because
    /// with them the new plan would break a guardrail.
    public let droppedThisWeek: [PlannedWorkout]
    public let explanation: [String]
}

/// Builds and re-builds the plan from the goal (SPEC.md F2, F3, F9).
///
/// Every plan goes through `PlanBuilder.build` with the baseline mapped by
/// `BaselinePlanMapping`, then through `GuardrailChecker.check` again with
/// the same history and any pain freezes in force. A goal edit re-plans the
/// remaining weeks from today: completed runs are history, never re-planned.
public enum GoalPlanner {
    /// - Parameters:
    ///   - settings: from the goal interview or a later edit.
    ///   - baseline: the F1 report, built on the same calendar day as `today`
    ///     in its time zone (build it as of now; otherwise
    ///     `GoalPlanIssue.baselineOutOfDate`). Its runs are the history, so a
    ///     run logged after `baseline.asOf` is not seen.
    ///   - today: the plan starts from here (`PlanInput.startDate`).
    ///   - freezes: pain freezes in force (`PainResponse.freeze`, SPEC 3.5).
    ///     See `GoalPlanIssue.failsGuardrails` for how they limit a new plan.
    public static func plan(settings: GoalSettings,
                            baseline: BaselineReport,
                            today: Date,
                            limits: GuardrailLimits = .default,
                            freezes: [DateInterval] = []) -> GoalPlanResult {
        var issues: [GoalPlanIssue] = []
        let problems = settings.problems(today: today, timeZone: baseline.timeZone)
        if !problems.isEmpty { issues.append(.invalidSettings(problems)) }
        let cal = PlanCalendar.calendar(timeZone: baseline.timeZone)
        // A non-finite today is already refused by the race-date check above.
        if today.timeIntervalSinceReferenceDate.isFinite {
            if baseline.asOf > today {
                issues.append(.baselineAfterToday(asOf: baseline.asOf))
            } else if today.timeIntervalSince(baseline.asOf) > GoalHeuristics.maximumBaselineAgeSeconds
                        || !cal.isDate(baseline.asOf, inSameDayAs: today) {
                issues.append(.baselineOutOfDate(asOf: baseline.asOf, today: today))
            }
        }
        guard issues.isEmpty else { return .cannotPlan(issues) }

        let input = BaselinePlanMapping.planInput(settings: settings, baseline: baseline, startDate: today)
        let history = BaselinePlanMapping.planHistory(from: baseline).filter { $0.date < today }
        switch PlanBuilder.build(input, history: history, timeZone: baseline.timeZone, limits: limits) {
        case .cannotBuild(let buildIssues):
            return .cannotPlan([.cannotBuild(buildIssues)])
        case .plan(let plan):
            let report = GuardrailChecker.check(history: history, planned: plan.workouts,
                                                timeZone: baseline.timeZone, limits: limits, freezes: freezes)
            guard report.passed else { return .cannotPlan([.failsGuardrails(report)]) }
            return .plan(GoalPlan(settings: settings, input: input, plan: plan, history: history,
                                  guardrailReport: report))
        }
    }

    /// A goal edit: re-plans from today with the new settings and explains
    /// what changed. When no plan can be made, the result says why and the
    /// app keeps the previous plan. `units` sets how a race distance reads in
    /// the explanation (km or miles); the plan itself is the same in both.
    public static func replan(from previous: GoalSettings,
                              previousPlan: TrainingPlan?,
                              to settings: GoalSettings,
                              baseline: BaselineReport,
                              today: Date,
                              limits: GuardrailLimits = .default,
                              freezes: [DateInterval] = [],
                              units: UnitPreference = .metric) -> GoalReplan {
        let changes = self.changes(from: previous, to: settings)
        let result = plan(settings: settings, baseline: baseline, today: today, limits: limits, freezes: freezes)
        var summary: PlanChangeSummary?
        if let old = previousPlan, let new = result.plan?.plan {
            summary = PlanChangeSummary(previousWeeks: old.weeks.count, newWeeks: new.weeks.count,
                                        previousPeakWeekSeconds: peak(old), newPeakWeekSeconds: peak(new),
                                        previousRaceSeconds: old.raceSeconds, newRaceSeconds: new.raceSeconds)
        }
        let tz = baseline.timeZone
        var lines = changes.map { describe($0, timeZone: tz, units: units) }
        if changes.isEmpty { lines.append("No goal settings changed; the plan was rebuilt from today.") }
        var kept: [PlannedWorkout] = []
        var dropped: [PlannedWorkout] = []
        switch result {
        case .plan(let p):
            if let old = previousPlan, let firstWeek = p.plan.weeks.first?.weekStart {
                let rest = old.workouts.filter { $0.date >= today && $0.date < firstWeek && $0.kind != .race }
                let onDays = rest.filter { settings.schedule.trainingDays.contains(PlanWeekday(of: $0.date, timeZone: tz)) }
                let offDays = rest.filter { !onDays.contains($0) }
                if !offDays.isEmpty {
                    dropped += offDays
                    lines.append("\(count(offDays.count)) left this week from the previous plan fell on days you no longer train, so they were dropped.")
                }
                if !onDays.isEmpty {
                    // The new plan already passed without them (`plan`); keep them only if it still passes with them.
                    let report = GuardrailChecker.check(history: p.history, planned: onDays + p.plan.workouts,
                                                        timeZone: tz, limits: limits, freezes: freezes)
                    if report.passed {
                        kept = onDays
                        lines.append("\(count(onDays.count)) left this week from the previous plan stay as planned.")
                    } else {
                        dropped += onDays
                        lines.append("\(count(onDays.count)) left this week from the previous plan were dropped: with them, the new plan would break the load guardrails (SPEC 3.5).")
                    }
                }
            }
            if let s = summary {
                lines.append("The plan now runs \(s.newWeeks) weeks to race day (was \(s.previousWeeks)), "
                             + "peaking at \(PlanFormatting.volume(s.newPeakWeekSeconds, .time)) a week "
                             + "(was \(PlanFormatting.volume(s.previousPeakWeekSeconds, .time))).")
            } else {
                lines.append("The plan runs \(p.plan.weeks.count) weeks to race day, peaking at "
                             + "\(PlanFormatting.volume(peak(p.plan), .time)) a week.")
            }
            lines.append("Every week passes the load guardrails (SPEC 3.5).")
        case .cannotPlan:
            lines.append("No new plan could be built from these settings, so the previous plan stays in place.")
        }
        return GoalReplan(changes: changes, result: result, planChanges: summary,
                          keptThisWeek: kept, droppedThisWeek: dropped.sorted { $0.date < $1.date }, explanation: lines)
    }

    static func count(_ n: Int) -> String { n == 1 ? "The 1 session" : "The \(n) sessions" }

    /// The settings that differ, in interview order.
    public static func changes(from a: GoalSettings, to b: GoalSettings) -> [GoalChange] {
        var out: [GoalChange] = []
        if a.race.name != b.race.name { out.append(.raceName(from: a.race.name, to: b.race.name)) }
        if a.race.date != b.race.date { out.append(.raceDate(from: a.race.date, to: b.race.date)) }
        if a.race.distanceMeters != b.race.distanceMeters {
            out.append(.raceDistance(fromMeters: a.race.distanceMeters, toMeters: b.race.distanceMeters))
        }
        if a.race.time != b.race.time { out.append(.goalTime(from: a.race.time, to: b.race.time)) }
        if a.schedule.trainingDays != b.schedule.trainingDays {
            out.append(.trainingDays(from: a.schedule.trainingDays, to: b.schedule.trainingDays))
        }
        if a.schedule.longRunDay != b.schedule.longRunDay {
            out.append(.longRunDay(from: a.schedule.longRunDay, to: b.schedule.longRunDay))
        }
        if a.schedule.maxSession != b.schedule.maxSession {
            out.append(.maxSession(from: a.schedule.maxSession, to: b.schedule.maxSession))
        }
        if a.hasTreadmillAccess != b.hasTreadmillAccess {
            out.append(.treadmillAccess(from: a.hasTreadmillAccess, to: b.hasTreadmillAccess))
        }
        if a.painHistory != b.painHistory { out.append(.painHistory(from: a.painHistory, to: b.painHistory)) }
        return out
    }

    static func peak(_ plan: TrainingPlan) -> Double {
        plan.weeks.map(\.trainingSeconds).max() ?? 0
    }

    // MARK: Explanations (locale-free, like PlanFormatting)

    static func describe(_ change: GoalChange, timeZone tz: TimeZone, units: UnitPreference = .metric) -> String {
        switch change {
        case .raceName(let a, let b):
            return "Race renamed from \(a) to \(b)."
        case .raceDate(let a, let b):
            return "Race date moved from \(PlanFormatting.day(a, timeZone: tz)) to \(PlanFormatting.day(b, timeZone: tz))."
        case .raceDistance(let a, let b):
            return "Race distance changed from \(distance(a, units)) to \(distance(b, units))."
        case .goalTime(let a, let b):
            return "Goal changed from \(goal(a)) to \(goal(b))."
        case .trainingDays(let a, let b):
            return "Training days changed from \(days(a)) to \(days(b))."
        case .longRunDay(let a, let b):
            return "Long run moved from \(dayName(a)) to \(dayName(b))."
        case .maxSession(let a, let b):
            return "Longest session changed from \(limit(a)) to \(limit(b))."
        case .treadmillAccess(_, let b):
            return b ? "Treadmill access added." : "Treadmill access removed."
        case .painHistory(_, let b):
            switch b {
            case .none: return "No recurring pain reported now, so pain check-ins stop."
            case .recurring(let areas):
                return "Recurring pain reported (\(areas.joined(separator: ", "))): a pain check-in follows every long run and quality session."
            }
        }
    }

    /// "21.1 km" or "13.1 mi".
    static func distance(_ meters: Double, _ units: UnitPreference = .metric) -> String { UnitFormatting.distance(meters, units) }

    /// A goal time as "1:45:00", to the nearest second. "-" (the placeholder
    /// `PlanFormatting.volume` shows) for a time that isn't a finite number
    /// or is too large to count in whole seconds, rather than trapping; a
    /// large time that can be counted prints in full, with `%ld` (#157).
    static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, let s = Int(exactly: seconds.rounded()) else { return PlanFormatting.placeholder }
        return String(format: "%ld:%02ld:%02ld", s / 3600, (s % 3600) / 60, s % 60)
    }

    static func goal(_ t: GoalTime) -> String {
        switch t {
        case .bestPossible: return "best possible"
        case .seconds(let s): return clock(s)
        }
    }

    static func limit(_ l: SessionLimit) -> String {
        switch l {
        case .noLimit: return "no limit"
        case .seconds(let s): return PlanFormatting.volume(s, .time)
        }
    }

    static func days(_ set: Set<PlanWeekday>) -> String {
        set.sorted().map(dayName).joined(separator: ", ")
    }

    static func dayName(_ day: PlanWeekday) -> String {
        switch day {
        case .monday: return "Monday"
        case .tuesday: return "Tuesday"
        case .wednesday: return "Wednesday"
        case .thursday: return "Thursday"
        case .friday: return "Friday"
        case .saturday: return "Saturday"
        case .sunday: return "Sunday"
        }
    }
}
