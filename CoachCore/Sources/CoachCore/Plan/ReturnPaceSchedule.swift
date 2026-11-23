import Foundation

// Paces after a break (SPEC 3.5 rule 4, "Days off and the factor" and "When it
// ends", #28): finds the runner's latest break in the history, counts its days
// off, and says which factor applies to each plan week. Pure logic over the
// plan history and the dated anchor efforts; `PlanBuilder` applies it to the
// training paces it sets. Every figure but [8]'s table is a heuristic.

/// A break in the run history: consecutive days with no running, as SPEC 3.5
/// rule 4 counts them.
struct DetectedBreak: Equatable {
    /// Day numbers (days since a fixed day, in the runner's time zone) of the
    /// first and last day off, both included.
    let firstOffDay: Int
    let lastOffDay: Int
    /// Break weeks (`GuardrailChecker.breaks`) inside it; 0 for a gap with no break week.
    let breakWeeks: Int
    /// Day number of the Monday of week 1 back: the return ramp's week 1 after
    /// a break week, else the week of the first run back (the plan's first
    /// week when the break is still running at the plan's start).
    let firstWeekBackDay: Int
    /// True when no run after the break is in the history yet.
    let ongoing: Bool
    /// True for a short break: one or two break weeks (`maxShortBreakWeeks`),
    /// or with no break week 6 to 14 days off. A longer break has no ramp to
    /// lift the factor over.
    let isShort: Bool

    /// Days off, every day of a break week counted (heuristic: the longer reading).
    var daysOff: Int { lastOffDay - firstOffDay + 1 }
}

/// The paces after the runner's latest break that still matter to a plan.
struct ReturnPaceSchedule: Equatable {
    let found: DetectedBreak
    /// [8]'s factor for `found.daysOff`.
    let factor: Double
    /// Monday 00:00 of week 1 back.
    let firstWeekBack: Date
    /// The anchor from a marked race after the break, which ends the factor
    /// (the best one by `AnchorEffort.pick`), or nil.
    let raceAnchor: RaceEquivalent?
    /// The anchor from before the break, or nil when no dated effort is before it.
    let preBreakAnchor: RaceEquivalent?

    var daysOff: Int { found.daysOff }
    var isShort: Bool { found.isShort }

    // MARK: Which weeks

    /// 1 for the week starting `weekStart` when it is week 1 back, 2 for the
    /// next, and so on; 0 or less before the break ends.
    func weekNumber(of weekStart: Date, timeZone: TimeZone) -> Int {
        let cal = PlanCalendar.calendar(timeZone: timeZone)
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: firstWeekBack), to: cal.startOfDay(for: weekStart)).day ?? 0
        // Floor division, so a day before week 1 is week 0 or less.
        let weeks = days >= 0 ? days / 7 : -((-days + 6) / 7)
        return weeks + 1
    }

    /// The factor on week `k` back (1 for the first): the table's value
    /// lifted over the return after a short break, held after a longer one,
    /// and 1.0 once a marked race after the break is the anchor.
    func factor(week k: Int) -> Double {
        BreakPaceFactor.effectiveFactor(factor, shortBreak: isShort, weeksBack: k, ended: raceAnchor != nil)
    }

    /// True when week `k` back is within the weeks where no training pace may
    /// be faster than before the break (the first three).
    func isCapped(week k: Int) -> Bool { k >= 1 && k <= BreakPaceFactor.returnWeeks }

    /// True when week `k` back is changed at all by the break.
    func affects(week k: Int) -> Bool {
        guard k >= 1 else { return false }
        return isCapped(week: k) || (!isShort && raceAnchor == nil)
    }

    // MARK: Paces

    /// `base` with the training paces of the week starting `weekStart` under
    /// the break: every pace taken from the fitness anchor (steady, threshold,
    /// VO2max) or the easy-pace sample (easy, recovery) divided by the week's
    /// factor, and through week 3 back never faster than from the anchor of
    /// before the break, even when a marked race after the break gives a
    /// faster one. In those weeks a marked race after the break is the
    /// anchor (SPEC 3.5 rule 4). The race pace is from the goal and the
    /// prediction, not the anchor or the easy-pace sample, and stays as it is.
    /// `fitnessAnchor` is `PlanInput.fitnessAnchor`.
    func targets(_ base: TargetModel, fitnessAnchor: RaceEquivalent?, weekStart: Date, timeZone: TimeZone) -> TargetModel {
        let k = weekNumber(of: weekStart, timeZone: timeZone)
        guard affects(week: k) else { return base }
        let f = factor(week: k)
        let capped = isCapped(week: k)
        let current = capped ? (raceAnchor ?? fitnessAnchor) : fitnessAnchor
        func pace(_ seconds: Double) -> Double? {
            guard let c = current, var p = TargetModel.riegelPace(anchor: c, seconds: seconds) else { return nil }
            if capped, let pre = preBreakAnchor, let q = TargetModel.riegelPace(anchor: pre, seconds: seconds) {
                p = max(p, q)
            }
            return BreakPaceFactor.pace(p, factor: f)
        }
        return base.withPaces(easy: base.easyPace.map { BreakPaceFactor.pace($0, factor: f) },
                              threshold: pace(3600), vo2max: pace(720))
    }

    // MARK: Finding the break

    /// The latest break in `history` that still matters to a plan starting at
    /// `firstMonday`, or nil.
    ///
    /// Break detection reuses the weekly reading of the load rules
    /// (`GuardrailChecker.breaks`, the same weeks the return ramp uses) and
    /// adds the day counting. A break is one or more break weeks, or 6 or more
    /// consecutive days with no run. Its days off run from the day after the
    /// last run before it to the day before the first run after it, with every
    /// day of a break week counted as off even when it holds a short run; so
    /// one or two break weeks count as at least 7 or 14 days, plus the days
    /// without a run on either side (heuristic: the longer reading). A break
    /// still running at the start counts to the day before `startDate`'s day
    /// (the days since are all that is known; the first run back is in the
    /// plan) and its week 1 is the plan's first week. A run is any session
    /// except a rest day, with a duration that isn't zero or negative; a
    /// session of unknown duration (NaN) was still a run.
    ///
    /// A break matters while some plan week is in weeks 1 to 3 back (the
    /// factor is lifted, or the pre-break cap holds), or, after a longer
    /// break, while no marked race after it has become the anchor.
    /// - Parameters:
    ///   - history: the sessions before `startDate`.
    ///   - efforts: `PlanInput.anchorEfforts`; those after the break that are
    ///     marked races end the factor, those before it set the pre-break anchor.
    static func latest(history: [PlannedWorkout], efforts: [AnchorEffort], raceDistanceMeters: Double,
                       startDate: Date, firstMonday: Date, timeZone: TimeZone, limits: GuardrailLimits) -> ReturnPaceSchedule? {
        let cal = PlanCalendar.calendar(timeZone: timeZone)
        let reference = cal.startOfDay(for: Date(timeIntervalSinceReferenceDate: 0))
        func dayNumber(_ d: Date) -> Int {
            cal.dateComponents([.day], from: reference, to: cal.startOfDay(for: d)).day ?? 0
        }
        func day(_ n: Int) -> Date { cal.date(byAdding: .day, value: n, to: reference) ?? reference }

        let past = history.filter { $0.date < startDate && $0.date.timeIntervalSinceReferenceDate.isFinite }
        let runDays = Set(past.filter { w in
            w.kind != .rest && !(w.durationSeconds.isFinite && w.durationSeconds <= 0)
        }.map { dayNumber($0.date) })
        guard let firstRun = runDays.min() else { return nil }
        let today = dayNumber(startDate)
        let lastKnown = today - 1
        let mondayNumber = dayNumber(firstMonday)

        // Weekly reading: the checker's break weeks, as day intervals.
        struct Interval { var lo: Int; var hi: Int; var weeks: Int; var monday: Int? = nil }
        var intervals: [Interval] = []
        // An open start week (a mid-week start) is not read as a week: it is not
        // over, so its days are counted one by one below.
        let weeklyEnd = min(PlanCalendar.weekStart(containing: startDate, timeZone: timeZone), firstMonday)
        let before = past.filter { $0.date < weeklyEnd }
        if let first = before.map(\.date).min() {
            let weeks = PlanWeek.weeks(from: before, firstWeekContaining: first,
                                       lastWeekContaining: weeklyEnd.addingTimeInterval(-1), timeZone: timeZone)
            let found = GuardrailChecker.breaks(volumes: weeks.map { $0.volumeOutsideRaces(.time) },
                                                lows: weeks.map { $0.knownVolumeOutsideRaces(.time) },
                                                raceWeeks: Set(weeks.indices.filter { weeks[$0].hasRace }), limits: limits)
            for b in found where b.first < weeks.count && b.end - 1 < weeks.count {
                var lo = dayNumber(weeks[b.first].weekStart)
                var hi = dayNumber(weeks[b.end - 1].weekEnd) - 1
                // The days without a run on either side belong to the break.
                while lo - 1 >= firstRun, !runDays.contains(lo - 1) { lo -= 1 }
                while hi + 1 <= lastKnown, !runDays.contains(hi + 1) { hi += 1 }
                intervals.append(Interval(lo: lo, hi: hi, weeks: b.length, monday: dayNumber(weeks[b.end - 1].weekEnd)))
            }
        }
        // Runs of 6 or more days with no run between two runs, or since the last one.
        let sortedRuns = runDays.sorted()
        for (a, b) in zip(sortedRuns, sortedRuns.dropFirst()) where b - a - 1 >= 6 {
            intervals.append(Interval(lo: a + 1, hi: b - 1, weeks: 0))
        }
        if let last = sortedRuns.last, lastKnown - last >= 6 {
            intervals.append(Interval(lo: last + 1, hi: lastKnown, weeks: 0))
        }
        guard !intervals.isEmpty else { return nil }

        // Merge the overlapping ones: one event, its break weeks added.
        var merged: [Interval] = []
        for i in intervals.sorted(by: { $0.lo < $1.lo }) {
            if var m = merged.last, i.lo <= m.hi + 1 {
                m.hi = max(m.hi, i.hi)
                // The same break week can appear in a weekly and a gap interval; weeks come from the weekly reading only.
                m.weeks += i.weeks
                m.monday = [m.monday, i.monday].compactMap { $0 }.max()
                merged[merged.count - 1] = m
            } else {
                merged.append(i)
            }
        }

        let valid = efforts.filter(\.isValid).filter { $0.date < startDate }
        for m in merged.reversed() {
            let ongoing = !runDays.contains(m.hi + 1)
            let weekBack: Int
            if ongoing {
                // The first run back is still to come, in the plan: its first week.
                weekBack = mondayNumber
            } else if let monday = m.monday {
                // The ramp's week 1: the Monday after the last break week.
                weekBack = monday
            } else {
                weekBack = dayNumber(PlanCalendar.weekStart(containing: day(m.hi + 1), timeZone: timeZone))
            }
            let short = m.weeks > 0 ? m.weeks <= max(0, limits.maxShortBreakWeeks) : (m.hi - m.lo + 1) <= 14
            let found = DetectedBreak(firstOffDay: m.lo, lastOffDay: m.hi, breakWeeks: m.weeks, firstWeekBackDay: weekBack,
                                      ongoing: ongoing, isShort: short)
            let afterRaces = valid.filter { $0.isMarkedRace && dayNumber($0.date) > m.hi }
            let race = AnchorEffort.pick(afterRaces, raceDistanceMeters: raceDistanceMeters)?.anchor
            let pre = AnchorEffort.pick(valid.filter { dayNumber($0.date) < m.lo }, raceDistanceMeters: raceDistanceMeters)?.anchor
            let schedule = ReturnPaceSchedule(found: found, factor: BreakPaceFactor.factor(daysOff: found.daysOff),
                                              firstWeekBack: day(weekBack), raceAnchor: race, preBreakAnchor: pre)
            let firstWeek = schedule.weekNumber(of: firstMonday, timeZone: timeZone)
            if schedule.factor < 1, schedule.affects(week: max(firstWeek, 1)) { return schedule }
        }
        return nil
    }
}
