import Foundation

extension PlanBuilder {
    /// `build`, for a goal or plan edit made while a pain freeze lasts (SPEC
    /// 3.5 rule 7, F2, owner's decision, #72). With no freeze, or one that
    /// doesn't reach the plan's first week, it is exactly `build`.
    ///
    /// The weeks the freeze covers (the plan's first weeks that overlap a
    /// freeze) are not drafted: they are the weeks `freeze.sessions` holds,
    /// the same workouts at the same volume and intensity, a quality session
    /// the freeze swapped for easy running still easy (`FreezeLayout` says
    /// what changes when the edit moves the runner's days or longest session,
    /// or puts the race inside such a week). The weeks after them are built
    /// as `build` builds them, with the frozen weeks counted as the history
    /// before them: growth resumes under the normal rules (3.5 rules 1, 2, 5
    /// and 6), the first week after the freeze measured from the last frozen
    /// week. A pending quality swap (`FreezeHold.pendingSwap`) turns the
    /// rebuilt plan's next quality session easy. The finished plan runs
    /// through the 3.5 checker with the freezes in force; a failure comes back
    /// as `PlanBuildIssue.failsGuardrails`, never as a plan that breaks the
    /// freeze.
    ///
    /// Heuristics (conservative readings of the spec, #72):
    /// - A frozen week is a calendar week that overlaps a freeze and starts a
    ///   run of such weeks at the plan's first week. A week with no session
    ///   in `freeze.sessions` ends that run (the plan is then built from that
    ///   week on, and the checker refuses a week that grows, as without this
    ///   rule), except the race week, which always holds at least the race.
    /// - The sessions of the current week that the old plan keeps
    ///   (`FreezeHold.carried`) count as history, the week as it will end.
    /// - The plan's phases for the weeks after the frozen ones are those of a
    ///   plan that starts there, so base, build and peak are shorter than in a
    ///   plan with no freeze; the taper and the race are the same.
    ///
    /// - Parameter freeze: the freezes and the plan the runner holds; nil is
    ///   `build`.
    public static func build(_ input: PlanInput,
                             history: [PlannedWorkout] = [],
                             timeZone: TimeZone,
                             limits: GuardrailLimits = .default,
                             freeze: FreezeHold?) -> PlanBuildResult {
        buildHolding(input, history: history, timeZone: timeZone, limits: limits, freeze: freeze).result
    }

    /// `build(_:history:timeZone:limits:freeze:)`, with what the edit did
    /// (nil when no week was held).
    static func buildHolding(_ input: PlanInput, history: [PlannedWorkout], timeZone: TimeZone, limits: GuardrailLimits,
                             freeze hold: FreezeHold?) -> (result: PlanBuildResult, summary: FreezeEditSummary?) {
        func plain() -> (result: PlanBuildResult, summary: FreezeEditSummary?) {
            (build(input, history: history, timeZone: timeZone, limits: limits), nil)
        }
        guard let hold, !hold.freezes.isEmpty else { return plain() }
        let past = history.filter { $0.date < input.startDate }
        // A refusal of the plain inputs is the refusal of this edit too.
        guard case .success(let v) = validate(input, history: past, timeZone: timeZone, limits: limits) else { return plain() }
        let starts = v.weekStarts
        func end(_ weekStart: Date) -> Date { PlanCalendar.nextWeekStart(after: weekStart, timeZone: timeZone) }
        func overlaps(_ weekStart: Date) -> Bool {
            let e = end(weekStart)
            return hold.freezes.contains { $0.start < e && $0.end > weekStart }
        }

        // The frozen weeks: the plan's first weeks that overlap a freeze and hold sessions.
        let carried = hold.carried(from: input.startDate, before: v.firstMonday, trainingDays: input.trainingDays,
                                   timeZone: timeZone)
        let race = frozenRaceWorkout(input, v)
        // Volume of each week before the plan, the current week as the old plan keeps it: what the first frozen week may not pass.
        let before = Dictionary(PlanWeek.weeks(from: past + carried, timeZone: timeZone).map { ($0.weekStart, $0.volume(.time)) },
                                uniquingKeysWith: { a, _ in a })
        var previousVolume: Double? = starts.first.flatMap { first in
            before[PlanCalendar.weekStart(weeks: -1, after: first, timeZone: timeZone)] ?? nil
        }
        var frozen: [TrainingPlanWeek] = []
        var heldPhases: [PlanPhase?] = []
        var relaid: [Date] = []
        var preCap = GuardrailPreCap.none
        var raceWeekStart: Date?
        var j = 0
        while j < starts.count, overlaps(starts[j]) {
            let ws = starts[j]
            let isRaceWeek = j == starts.count - 1
            let held = hold.sessions.filter { $0.date >= ws && $0.date < end(ws) }
            if !isRaceWeek, !held.contains(where: { $0.kind != .race && $0.kind != .rest }) { break }
            // Hard days just outside the week (the Sunday before, the Monday after) keep a quality session off
            // the week's edge days, as the builder's `excludedQualityDays` does (F4).
            let cal = PlanCalendar.calendar(timeZone: timeZone)
            func hardOn(_ day: Date, in sessions: [PlannedWorkout]) -> Bool {
                sessions.contains { $0.kind.isQuality && cal.isDate($0.date, inSameDayAs: day) }
            }
            let dayBefore = cal.date(byAdding: .day, value: -1, to: ws) ?? ws.addingTimeInterval(-86_400)
            var outside: Set<Int> = []
            if hardOn(dayBefore, in: (frozen.last?.workouts ?? []) + past + carried) { outside.insert(-1) }
            if !isRaceWeek, hardOn(end(ws), in: hold.sessions) { outside.insert(7) }
            let ctx = FreezeLayout.Context(input: input, limits: limits, timeZone: timeZone,
                                           moveLongRun: hold.longRunDayChanged, race: isRaceWeek ? race : nil,
                                           ceiling: previousVolume.flatMap { $0 > 0 ? $0 : nil },
                                           hardOutside: outside)
            let laid = FreezeLayout.lay(held: held, weekStart: ws, ctx)
            if laid.relaid { relaid.append(ws) }
            if let c = laid.cap {
                preCap = preCap.recording(weekStart: ws, secondsBefore: c.before, secondsAfter: c.after, metersBefore: nil, metersAfter: nil)
            }
            var workouts = laid.workouts
            if isRaceWeek { workouts.append(race); raceWeekStart = ws }
            previousVolume = workouts.reduce(0.0) { $0 + max(0, $1.durationSeconds.isFinite ? $1.durationSeconds : 0) }
            heldPhases.append(workouts.filter { $0.kind != .race }.compactMap { $0.prescription?.phase }.first)
            frozen.append(TrainingPlanWeek(index: j, weekStart: ws, phase: isRaceWeek ? .taper : .base,
                                           isRecoveryWeek: false, isRaceWeek: isRaceWeek, workouts: workouts))
            j += 1
        }
        let k = frozen.count
        guard k > 0 else {
            // No week of the plan is held. A freeze that still lasts (it ends before the plan's first week, so it
            // covers the rest of this week) is still said in the explanation: the plan is as `build` makes it.
            let plan = plain()
            guard hold.freezes.contains(where: { $0.end > input.startDate }) else { return plan }
            return (plan.result, FreezeEditSummary(freezes: hold.freezes, frozenWeekStarts: [], relaidWeekStarts: [],
                                                   raceWeekStart: nil, firstGrowthWeekStart: starts.first, swapLandsOn: nil))
        }
        let frozenSessions = frozen.flatMap(\.workouts)
        let heldIDs = Set(frozenSessions.map(\.id))

        // The weeks after the frozen ones, built with the frozen weeks as history.
        var built: [TrainingPlanWeek] = []
        var notes = v.notes
        if k < starts.count {
            // The builder drafts a plan with at least one week before its taper. A freeze that leaves only the taper
            // (the race week, and the week before it from the 10K up) can't be built that way: refused plainly, the
            // old plan stays (heuristic limit of #72; it takes a freeze of two weeks or more to get here).
            let taper = PlanHeuristics.taperWeeks(v.category)
            if starts.count - k <= taper {
                return (.cannotBuild([.leadTimeTooShort(weeksAvailable: starts.count - k, minimumWeeks: taper + 1)]), nil)
            }
            var after = input
            after.startDate = starts[k]
            // The first week after the freeze is measured from the last frozen week itself (3.5 rule 7): it may
            // hold no more than the weekly rise over it, even where that week reads as a recovery week and
            // rule 2 would measure from the week before it (heuristic, the conservative reading, #72).
            let lastOwn = frozen[k - 1].workouts.filter { $0.kind != .race }.reduce(0.0) { $0 + max(0, $1.durationSeconds.isFinite ? $1.durationSeconds : 0) }
            // A week capped at its long run is read at its time before the cap (3.5 rule 5, #54).
            let lastFrozen = lastOwn + preCap.extra(frozen[k - 1].weekStart, actual: lastOwn, .time)
            let result = buildDiagnosed(after, history: past + carried + frozenSessions, timeZone: timeZone, limits: limits,
                                        diagnose: false, heldWeeks: k,
                                        firstWeekCap: lastFrozen * (1 + limits.maxWeeklyIncrease),
                                        baselineEnd: PlanCalendar.weekStart(containing: input.startDate, timeZone: timeZone)).result
            guard case .plan(let tail) = result else { return (result, nil) }
            notes = tail.notes
            built = tail.weeks.map { w in
                let workouts = w.workouts.map { workout -> PlannedWorkout in
                    guard workout.kind != .race else { return workout }
                    var renamed = workout
                    var id = workout.id.replacingOccurrences(of: "plan-w\(w.index)-", with: "plan-w\(w.index + k)-")
                    while heldIDs.contains(id) { id += "-e" }
                    renamed.id = id
                    return renamed
                }
                return TrainingPlanWeek(index: w.index + k, weekStart: w.weekStart, phase: w.phase,
                                        isRecoveryWeek: w.isRecoveryWeek, isRaceWeek: w.isRaceWeek, workouts: workouts)
            }
        }

        // A quality swap still to come falls on the next quality session after the frozen weeks.
        var swapLandsOn: Date?
        if let swap = hold.pendingSwap, k < starts.count, swap.original.date >= starts[k] {
            let next = built.flatMap(\.workouts).filter { $0.kind.isQuality }.min { $0.date < $1.date }
            if let target = next {
                swapLandsOn = target.date
                built = built.map { w in
                    TrainingPlanWeek(index: w.index, weekStart: w.weekStart, phase: w.phase, isRecoveryWeek: w.isRecoveryWeek,
                                     isRaceWeek: w.isRaceWeek,
                                     workouts: w.workouts.map { $0.id == target.id
                                         ? $0.swappedToEasyKeepingTarget(reason: "your pain check-in swapped your next quality session for easy running (SPEC 3.5).")
                                         : $0 })
                }
            }
        }

        // Frozen weeks take their phase from the held week, else from the weeks after them.
        let tailPhase = built.first?.phase
        let planned = frozen.flatMap(\.workouts) + built.flatMap(\.workouts)
        let checked = history.filter { $0.date < input.startDate } + carried
        // The builder's own run limits (F3, #23): no easy run longer than the week's long run, no run past the
        // category's long-run cap or the runner's longest session.
        var checkLimits = limits
        checkLimits.maxTrainingRunSeconds = min(limits.maxTrainingRunSeconds, input.maxSessionSeconds ?? .infinity,
                                                PlanHeuristics.longRunCap(v.category, isMarathonDistance: RaceCategory.isMarathonDistance(meters: input.raceDistanceMeters)))
        checkLimits.easyRunsWithinLongRun = true
        let report = GuardrailChecker.check(history: checked, planned: planned, timeZone: timeZone, limits: checkLimits,
                                            freezes: hold.freezes, regrowth: GuardrailRegrowth(preCap: preCap))
        guard report.passed else { return (.cannotBuild([.failsGuardrails(report)]), nil) }

        // Label the frozen weeks the way the checker reads recovery weeks.
        let volumes = Dictionary(PlanWeek.weeks(from: checked + planned, timeZone: timeZone).map { ($0.weekStart, $0.volume(.time)) },
                                 uniquingKeysWith: { a, _ in a })
        let labelled = frozen.enumerated().map { n, w -> TrainingPlanWeek in
            let before = volumes[PlanCalendar.weekStart(weeks: -1, after: w.weekStart, timeZone: timeZone)] ?? nil
            let own = volumes[w.weekStart] ?? nil
            let recovery = own.map { v in v == 0 || (before.map { b in b > 0 && v <= limits.recoveryWeekMaxRatio * b } ?? false) } ?? false
            let phase = heldPhases[n] ?? (w.isRaceWeek ? .taper : (tailPhase ?? .base))
            return TrainingPlanWeek(index: w.index, weekStart: w.weekStart, phase: phase, isRecoveryWeek: recovery,
                                    isRaceWeek: w.isRaceWeek, workouts: w.workouts)
        }

        let summary = FreezeEditSummary(freezes: hold.freezes, frozenWeekStarts: frozen.map(\.weekStart),
                                        relaidWeekStarts: relaid, raceWeekStart: raceWeekStart,
                                        firstGrowthWeekStart: k < starts.count ? starts[k] : nil,
                                        swapLandsOn: swapLandsOn, preCap: preCap)
        let count = k == 1 ? "The first week is" : "The first \(k) weeks are"
        notes.append("\(count) held by your pain freeze at the volume and sessions they had, until it ends; growth toward your goal starts after them (SPEC 3.5 rule 7).")
        var rebuildDate: Date?
        if PlanCalendar.weekStart(containing: input.startDate, timeZone: timeZone) < v.firstMonday {
            // As for any plan started mid-week: this week isn't over, so it is rebuilt on its first Monday, freeze still held.
            rebuildDate = v.firstMonday
            notes.append("This week isn't over yet, so this plan is provisional: it is rebuilt on Monday \(PlanFormatting.day(v.firstMonday, timeZone: timeZone)) from the finished week, with your pain freeze still held (SPEC 3.5).")
        }
        let plan = TrainingPlan(category: v.category, weeks: labelled + built, raceSeconds: v.raceSeconds,
                                guardrailReport: report, notes: notes, rebuildDate: rebuildDate)
        return (.plan(plan), summary)
    }

    /// The race as `Builder.raceWorkout` makes it, for a race inside a frozen week.
    static func frozenRaceWorkout(_ input: PlanInput, _ v: Validated) -> PlannedWorkout {
        let seg = WorkoutSegment(role: .main, intensity: .race, durationSeconds: v.raceSeconds, target: v.targets.target(.race))
        let meters = input.raceDistanceMeters
        let p = WorkoutPrescription(purpose: PlanFormatting.raceDayPurpose(meters: meters), phase: .taper,
                                    segments: [seg], rules: [.goalRace], raceDistanceMeters: meters)
        return PlannedWorkout(id: "plan-race", date: input.raceDate, kind: .race, durationSeconds: v.raceSeconds,
                              distanceMeters: meters, prescription: p)
    }
}
