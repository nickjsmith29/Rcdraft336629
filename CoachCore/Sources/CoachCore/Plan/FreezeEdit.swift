import Foundation

/// A pain freeze in force, as a goal or plan edit (F2) or a rebuild must see
/// it (SPEC 3.5 rule 7, owner's decision, #72). Pass it to
/// `PlanBuilder.build(_:history:timeZone:limits:freeze:)`,
/// `GoalPlanner.plan` / `replan` or `ProvisionalRebuild.run`, so the edit
/// builds around the weeks the freeze covers instead of being refused with
/// `PlanBuildIssue.failsGuardrails`.
///
/// The builder holds each week that overlaps a freeze at the sessions it holds
/// under the freeze (`sessions`), grows the weeks after them under the normal
/// rules (3.5 rules 1, 2, 5 and 6) measured from the last frozen week, and
/// never changes the freeze itself: `freezes` come back untouched in
/// `FreezeEditSummary` and still end on their original day.
public struct FreezeHold: Equatable, Sendable {
    /// The freezes in force (`AdaptationState.freezeIntervals(at:)`). The edit
    /// never shortens, lifts or restarts them.
    public let freezes: [DateInterval]
    /// The plan the runner holds now, as the adaptation engine adapted it
    /// (F4): its sessions in the weeks the freeze covers are the weeks to hold,
    /// with a quality session the freeze swapped for easy running already
    /// easy. Its sessions for the rest of the current week stay as planned
    /// (the goal edit keeps them, `GoalReplan.keptThisWeek`) and count in that
    /// week's volume when the first frozen week is measured against it.
    public let sessions: [PlannedWorkout]
    /// The quality swap of the latest pain check-in while it is still to come
    /// (`PainResponse.swap`): when its session lay after the frozen weeks, the
    /// rebuilt plan's next quality session is swapped for easy running instead.
    public let pendingSwap: QualitySwap?

    /// Set by `GoalPlanner.replan` when the edit changed the long-run day, so
    /// a frozen week's long run moves to the new day. A frozen week is
    /// otherwise laid out again only when a session sits on a day the runner
    /// no longer trains or is longer than the new longest session. A
    /// long run that is off the long-run day for another reason (the week
    /// before the race, a session moved by a missed day) stays where it is.
    var longRunDayChanged = false

    public init(freezes: [DateInterval], sessions: [PlannedWorkout], pendingSwap: QualitySwap? = nil) {
        self.freezes = freezes
        self.sessions = sessions
        self.pendingSwap = pendingSwap
    }

    /// The sessions of the current, still open week that the old plan keeps
    /// (the same filter `GoalPlanner.replan` uses for `keptThisWeek`: from
    /// `startDate` up to the plan's first week, no race, on a day the runner
    /// still trains). The new plan is measured against them, since they are
    /// how the week will end.
    func carried(from startDate: Date, before firstWeek: Date, trainingDays: Set<PlanWeekday>,
                 timeZone: TimeZone) -> [PlannedWorkout] {
        sessions.filter {
            $0.date >= startDate && $0.date < firstWeek && $0.kind != .race
                && trainingDays.contains(PlanWeekday(of: $0.date, timeZone: timeZone))
        }
    }
}

extension AdaptationState {
    /// The `FreezeHold` for a goal or plan edit made at `date`, from the plan
    /// the engine holds now (`AdaptationOutcome.plan`, with its swaps applied).
    /// Nil when no pain freeze is in force, which leaves the edit exactly as
    /// without one. A quality swap of the latest check-in that has not come
    /// up yet (its session is at or after `date`) is passed on as the pending
    /// swap.
    public func freezeHold(plan: [PlannedWorkout], at date: Date) -> FreezeHold? {
        let intervals = freezeIntervals(at: date)
        guard !intervals.isEmpty else { return nil }
        var pending: QualitySwap?
        if let r = appliedPainResponse, r.freezeEnd > date, let swap = r.swap, swap.original.date >= date {
            pending = swap
        }
        return FreezeHold(freezes: intervals, sessions: plan, pendingSwap: pending)
    }
}

/// What an edit during a pain freeze did, so the caller (and the explanation
/// of the edit, F2) can say it: which weeks the freeze holds, where a week
/// was laid out again or a race fell inside it, and when growth resumes.
public struct FreezeEditSummary: Equatable, Sendable {
    /// The freezes as they were given: unchanged, still ending on their original day.
    public let freezes: [DateInterval]
    /// The weeks held at their frozen volume and intensity, in order.
    public let frozenWeekStarts: [Date]
    /// The frozen weeks laid out again on new days or a new longest session
    /// (or cut to the week before it), with the same workouts moved,
    /// shortened or (when a day was lost) dropped.
    public let relaidWeekStarts: [Date]
    /// The frozen week the race falls in, when the edit placed it inside one.
    public let raceWeekStart: Date?
    /// The first week after the frozen weeks, where growth resumes; nil when
    /// the freeze covers the plan to the race.
    public let firstGrowthWeekStart: Date?
    /// The day of the rebuilt plan's session that took a pending quality swap
    /// (`FreezeHold.pendingSwap`), when there was one to place.
    public let swapLandsOn: Date?

    /// The first day of the freezes (the earliest start), or nil with none.
    public var freezeStart: Date? { freezes.map(\.start).min() }
    /// The day the freezes end (the latest end), or nil with none.
    public var freezeEnd: Date? { freezes.map(\.end).max() }

    /// Plain words for the edit's explanation (F2): the freeze still holds and
    /// when it ends, what the held weeks keep, where growth resumes, and the
    /// moved weeks, the swap and the race when there are any.
    public func explanation(timeZone: TimeZone) -> [String] {
        func day(_ d: Date) -> String { PlanFormatting.day(d, timeZone: timeZone) }
        var lines: [String] = []
        let n = frozenWeekStarts.count
        let from = freezeStart.map { " from \(day($0))" } ?? ""
        let until = freezeEnd.map { " until \(day($0))" } ?? ""
        var main = "Your pain freeze\(from) still holds\(until); this edit doesn't shorten or lift it. "
        main += n == 1 ? "The week it covers keeps its volume and its easy sessions"
                       : "The \(n) weeks it covers keep their volume and their easy sessions"
        if let g = firstGrowthWeekStart {
            main += ", and the new plan grows toward your new goal from the week of \(day(g)) (SPEC 3.5 rule 7)."
        } else {
            main += "; there is no week after them before the race (SPEC 3.5 rule 7)."
        }
        lines.append(main)
        if !relaidWeekStarts.isEmpty {
            let weeks = relaidWeekStarts.map(day).joined(separator: ", ")
            lines.append("The frozen week\(relaidWeekStarts.count == 1 ? "" : "s") of \(weeks) keep\(relaidWeekStarts.count == 1 ? "s" : "") the same sessions, moved onto your new days or shortened where your new days, your longest session or the week before it leave less room, at no more than the volume the freeze holds. No new or harder session types are added.")
        }
        if let d = swapLandsOn {
            lines.append("The quality session your pain check-in swapped for easy running hadn't come up yet, so the new plan's next quality session, on \(day(d)), is an easy run instead.")
        }
        if let w = raceWeekStart {
            lines.append("Your race falls inside the freeze, in the week of \(day(w)). It stays on the day you set and counts toward that week's frozen volume, so the other runs that week are shorter by it.")
        }
        return lines
    }
}
