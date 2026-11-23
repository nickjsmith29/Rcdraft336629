import Foundation

/// When and how to rebuild a **provisional** plan (`TrainingPlan.rebuildDate`,
/// #48, #55), as pure logic the app calls: it builds nothing itself.
///
/// A plan made after its start week began is sized to keep SPEC 3.5 however
/// that open week ends, so it is safe but light until it is rebuilt from the
/// finished week. The app:
/// 1. calls `due` (on launch, when it comes to the foreground, on a
///    background refresh, or when a run is logged) with the plan, any
///    `retryAt` it stored and the current time;
/// 2. on `.rebuild(today:)`, builds a fresh baseline **as of `today`**
///    (`BaselineOptions.asOf`) and calls `GoalPlanner.plan` (or
///    `PlanBuilder.build`) with that `today`, not with now: see
///    `TrainingPlan.rebuildDate` for why;
/// 3. passes the result to `resolve`, uses the plan it returns, and stores
///    its `retryAt` for the next `due` call (replacing the plan's watch
///    workouts, `WatchSyncReconciler`, is the app's part);
/// 4. clears the stored `retryAt` **whenever it replaces the plan**: after a
///    rebuild, a goal edit (F2) or any new plan. A `retryAt` belongs to the
///    plan whose rebuild was refused; left in place, a stale one pushes back
///    the next plan's own rebuild (`due` waits for the later of the two).
///
/// `run` and `CurrentPlan` (ProvisionalRebuild+Run.swift) do these steps in
/// order; the app supplies the stored plan, the baseline and its logging.
///
/// **Refused rebuild (a heuristic default).** In fuzzing on #55, about 6 to 7%
/// of rebuilds were refused (`noWorkableWeek` or `recentVolumeTooLow`, mostly
/// after a start week with no runs or a very big one). SPEC 3.5 and F3 say a
/// plan must pass the guardrails, and the provisional plan does with the
/// finished start week (it was sized for every way that week could end), but
/// SPEC says nothing about refused rebuilds. So by default, and for every
/// refusal: the provisional plan stays in place, its note says so, and the
/// rebuild is tried again from the next local Monday, when one more closed
/// week may give a workable plan (a rolling 4-week window moving past a
/// break, for example). No retry is set once the race week has begun; the
/// provisional plan then runs to the race. This is a product choice, not a
/// research finding, and can change once SPEC covers it.
///
/// Times are compared as instants; weeks are Monday 00:00 in `timeZone`
/// (`PlanCalendar`), so daylight-saving weeks of 167 or 169 hours and a
/// runner who changed time zone since the plan was built are handled: the
/// stored dates are moved to the nearest Monday 00:00 in `timeZone`.
public enum ProvisionalRebuild {
    /// What `due` says to do now.
    public enum Due: Equatable, Sendable {
        /// The plan is final: nothing to rebuild.
        case notNeeded
        /// Not yet: call `due` again at or after this moment (Monday 00:00
        /// in the time zone given).
        case notYet(at: Date)
        /// Rebuild now, from `today`: Monday 00:00 of the current local week.
        /// Pass it as `GoalPlanner.plan(today:)` (or `PlanInput.startDate`) and
        /// build the baseline as of it. It is the plan's rebuild date during
        /// the plan's first week, and the latest Monday after a whole week or
        /// more without a rebuild, so closed weeks are always history.
        case rebuild(today: Date)
        /// The race week has begun (or the next try would fall in it): the
        /// provisional plan stays to the race and no rebuild is tried.
        case raceWeekReached
        /// `now`, the rebuild date, `retryAt` or the race week's start is NaN
        /// or infinite. Nothing can be scheduled from it, so no rebuild is
        /// tried: the app **keeps the plan in use** as it is (it already
        /// passed the guardrails, SPEC 3.5) and calls `due` again with valid
        /// dates. This only comes from a bug or corrupt stored data, never from
        /// the runner's own runs, so the app should log it rather than show it.
        /// `resolve` treats the same dates the same way: a refusal with a
        /// non-finite `now` or race-week start keeps the plan with no retry.
        case invalidDate
    }

    /// The plan to use after a rebuild attempt.
    public struct Outcome<Plan: Equatable & Sendable>: Equatable, Sendable {
        /// The rebuilt plan, or the provisional plan kept after a refusal.
        public let plan: Plan
        /// True when `plan` is the rebuilt one: replace the stored plan and
        /// its watch workouts.
        public let isRebuilt: Bool
        /// After a refusal, when to try again (pass it to `due`): the next
        /// local Monday 00:00 after `now`, or a later date a refusal names
        /// (`PlanBuildIssue.historyVolumeUnknown`, `.startWeekWithoutReference`).
        /// Nil after a rebuild (a rebuilt plan carries its own `rebuildDate`
        /// if it is somehow provisional again), once the next try would fall
        /// in the race week, or when `now` or the race week's start is not
        /// finite (as `Due.invalidDate`).
        ///
        /// It belongs to `plan` only. The app stores it with the plan and
        /// **clears it whenever it replaces the plan** (this rebuild, a goal
        /// edit or any new plan), or the stale date pushes back the new
        /// plan's rebuild.
        public let retryAt: Date?
        /// After a refusal, a plain-English note for the app to show in place
        /// of the plan's own provisional note (which names the past rebuild
        /// day, and is always the last of `TrainingPlan.notes` while the plan
        /// is provisional). Nil after a rebuild.
        public let note: String?
        /// True when the refusal is (or includes) one that can only come
        /// from a bug in the app's wiring, not from the runner's data: the
        /// baseline was not built as of the `today` that `due` gave
        /// (`GoalPlanIssue.baselineAfterToday`, `.baselineOutOfDate`). Other
        /// issues may come with it. These should never happen when the app
        /// follows the steps above. The plan is still kept and the retry
        /// still set, as for any refusal, but the same bug would refuse every
        /// weekly retry until the race without anyone noticing, so the app
        /// should log or report it (an `assertionFailure` in debug builds,
        /// for example). The runner's note is unchanged. Always false after a
        /// rebuild and for `PlanBuilder` refusals.
        public let isWiringError: Bool

        init(plan: Plan, isRebuilt: Bool, retryAt: Date?, note: String?, isWiringError: Bool = false) {
            self.plan = plan
            self.isRebuilt = isRebuilt
            self.retryAt = retryAt
            self.note = note
            self.isWiringError = isWiringError
        }
    }

    // MARK: - Due

    /// Whether `plan` is due to be rebuilt at `now`, and the `today` to pass.
    /// - Parameters:
    ///   - retryAt: the `Outcome.retryAt` stored after a refused rebuild of
    ///     **this** plan, if any. The app clears it whenever it replaces the
    ///     plan; a stale one would push back the new plan's rebuild.
    ///   - timeZone: the runner's current time zone.
    public static func due(plan: TrainingPlan, retryAt: Date? = nil, now: Date,
                           timeZone: TimeZone) -> Due {
        due(rebuildDate: plan.rebuildDate, raceWeekStart: raceWeekStart(plan), retryAt: retryAt,
            now: now, timeZone: timeZone)
    }

    /// `due` for a plan from `GoalPlanner`.
    public static func due(plan: GoalPlan, retryAt: Date? = nil, now: Date, timeZone: TimeZone) -> Due {
        due(plan: plan.plan, retryAt: retryAt, now: now, timeZone: timeZone)
    }

    static func due(rebuildDate: Date?, raceWeekStart: Date?, retryAt: Date?, now: Date,
                    timeZone: TimeZone) -> Due {
        guard let rebuildDate else { return .notNeeded }
        guard finite(now), finite(rebuildDate), retryAt.map(finite) ?? true,
              raceWeekStart.map(finite) ?? true else { return .invalidDate }
        var dueAt = nearestWeekStart(rebuildDate, timeZone: timeZone)
        if let retryAt { dueAt = max(dueAt, nearestWeekStart(retryAt, timeZone: timeZone)) }
        let race = raceWeekStart.map { nearestWeekStart($0, timeZone: timeZone) }
        if let race, dueAt >= race { return .raceWeekReached }
        guard now >= dueAt else { return .notYet(at: dueAt) }
        // now >= dueAt, a local Monday 00:00, so this Monday is never before it.
        let today = PlanCalendar.weekStart(containing: now, timeZone: timeZone)
        if let race, today >= race { return .raceWeekReached }
        return .rebuild(today: today)
    }

    // MARK: - Resolve

    /// The plan to use after a rebuild attempt through `PlanBuilder.build`.
    /// - Parameters:
    ///   - provisional: the plan in use (kept after a refusal).
    ///   - attempt: the rebuild's result.
    ///   - now: the current time, for the retry.
    public static func resolve(provisional: TrainingPlan, attempt: PlanBuildResult, now: Date,
                               timeZone: TimeZone) -> Outcome<TrainingPlan> {
        switch attempt {
        case .plan(let rebuilt):
            return Outcome(plan: rebuilt, isRebuilt: true, retryAt: nil, note: nil)
        case .cannotBuild(let issues):
            return kept(provisional, raceWeekStart: raceWeekStart(provisional),
                        named: issues.compactMap(rebuildOn), now: now, timeZone: timeZone)
        }
    }

    /// The plan to use after a rebuild attempt through `GoalPlanner.plan`.
    public static func resolve(provisional: GoalPlan, attempt: GoalPlanResult, now: Date,
                               timeZone: TimeZone) -> Outcome<GoalPlan> {
        switch attempt {
        case .plan(let rebuilt):
            return Outcome(plan: rebuilt, isRebuilt: true, retryAt: nil, note: nil)
        case .cannotPlan(let issues):
            let named = issues.flatMap { issue -> [Date] in
                if case .cannotBuild(let b) = issue { return b.compactMap(rebuildOn) }
                return []
            }
            return kept(provisional, raceWeekStart: raceWeekStart(provisional.plan), named: named,
                        now: now, timeZone: timeZone, isWiringError: issues.contains(where: isWiringError))
        }
    }

    static func kept<Plan>(_ plan: Plan, raceWeekStart: Date?, named: [Date], now: Date,
                           timeZone: TimeZone, isWiringError: Bool = false) -> Outcome<Plan> {
        let stays = "This week's rebuild could not be made, so this provisional plan stays in place. "
            + "It keeps within the load guardrails (SPEC 3.5) but holds back what the finished week would allow."
        // As in `due` (`.invalidDate`): with no valid now or race week there is
        // no retry date to set, so the plan stays with none, and the note names
        // no retry day and no end. This only comes from a bug or corrupt stored
        // data, never from the runner's runs, so the app should log it rather
        // than show it, as for `.invalidDate`.
        guard finite(now), raceWeekStart.map(finite) ?? true else {
            return Outcome(plan: plan, isRebuilt: false, retryAt: nil, note: stays, isWiringError: isWiringError)
        }
        var retry = PlanCalendar.nextWeekStart(after: PlanCalendar.weekStart(containing: now, timeZone: timeZone),
                                               timeZone: timeZone)
        for d in named where finite(d) {
            let monday = nearestWeekStart(d, timeZone: timeZone)
            if monday > retry { retry = monday }
        }
        if let race = raceWeekStart.map({ nearestWeekStart($0, timeZone: timeZone) }), retry >= race {
            return Outcome(plan: plan, isRebuilt: false, retryAt: nil, note: stays + " It runs to the race.",
                           isWiringError: isWiringError)
        }
        let day = PlanFormatting.day(retry, timeZone: timeZone)
        return Outcome(plan: plan, isRebuilt: false, retryAt: retry,
                       note: stays + " It is tried again on Monday \(day).", isWiringError: isWiringError)
    }

    // MARK: - Helpers

    /// A refusal only the app's wiring can cause: the baseline was not built
    /// as of the `today` passed (see `Outcome.isWiringError`).
    static func isWiringError(_ issue: GoalPlanIssue) -> Bool {
        switch issue {
        case .baselineAfterToday, .baselineOutOfDate: return true
        default: return false
        }
    }

    static func rebuildOn(_ issue: PlanBuildIssue) -> Date? {
        switch issue {
        case .historyVolumeUnknown(let d), .startWeekWithoutReference(let d): return d
        default: return nil
        }
    }

    static func raceWeekStart(_ plan: TrainingPlan) -> Date? {
        (plan.weeks.last(where: \.isRaceWeek) ?? plan.weeks.last)?.weekStart
    }

    static func finite(_ d: Date) -> Bool { d.timeIntervalSinceReferenceDate.isFinite }

    /// The Monday 00:00 in `timeZone` nearest to `date`: `date` itself when it
    /// is one, and the same Monday as the plan's when the runner moved a few
    /// time zones since (#55).
    static func nearestWeekStart(_ date: Date, timeZone: TimeZone) -> Date {
        let start = PlanCalendar.weekStart(containing: date, timeZone: timeZone)
        let next = PlanCalendar.nextWeekStart(after: start, timeZone: timeZone)
        return date.timeIntervalSince(start) <= next.timeIntervalSince(date) ? start : next
    }
}
