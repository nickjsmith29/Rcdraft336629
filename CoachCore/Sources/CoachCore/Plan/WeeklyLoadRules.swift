import Foundation

// The owner's guardrail decisions of #38 (SPEC.md 3.5 rules 2 to 5, #62),
// shared by `GuardrailChecker` and the plan builder's ledger
// (`PlanBuilder.LoadLedger`) so the two read every week the same way.
// Every number here is a heuristic from `GuardrailLimits`.

extension PlanWeek {
    /// True when the week holds a race (planned or done).
    var hasRace: Bool { workouts.contains { $0.kind == .race } }

    /// The week's volume outside races (SPEC 3.5 rule 3): what the weekly
    /// caps of rule 2 measure. Nil when a session other than a race has no
    /// valid value; a race's own value never matters here, so a race of
    /// unknown length leaves it known.
    func volumeOutsideRaces(_ measure: VolumeMeasure) -> Double? {
        var total = 0.0
        for w in workouts where w.kind != .race {
            guard let v = w.volume(measure) else { return nil }
            total += v
        }
        return total
    }

    /// The known part of `volumeOutsideRaces` (#40): a lower bound of it when it is nil.
    func knownVolumeOutsideRaces(_ measure: VolumeMeasure) -> Double {
        workouts.filter { $0.kind != .race }.reduce(0) { $0 + ($1.volume(measure) ?? 0) }
    }
}

/// A break in the weekly checks (SPEC 3.5 rule 4, read in weeks): one or more
/// Monday-start weeks in a row, each with at most
/// `GuardrailLimits.breakWeekMaxRatio` of the pre-break weekly volume, no
/// race and a known volume. Heuristic.
struct LoadBreak: Equatable, Sendable {
    /// Index of the first break week.
    let first: Int
    /// Number of break weeks.
    let length: Int
    /// Pre-break weekly volume: the mean of the (up to)
    /// `GuardrailLimits.preBreakWeeks` weeks before the break, each at its
    /// known part (a lower bound, so never more than the true mean, #40).
    let level: Double
    /// True when the days off, counted as for the pace factor (every day of a
    /// break week, plus the run-free days on either side), are more than 14
    /// though the break reads as only `maxShortBreakWeeks` weeks or fewer
    /// (15 to about 20 days, 3.5 rule 4). Set by
    /// `GuardrailChecker.longerByDays`; the volumes alone can't say.
    var longerByDays = false

    /// Index of the first week after the break (return week 1).
    var end: Int { first + length }

    /// A break of at most `maxShortBreakWeeks` weeks: the short-break return
    /// ramp applies to the 3 weeks after it, and its weeks count at the
    /// pre-break level in the rolling check (unless it is also a longer break).
    func isShort(_ limits: GuardrailLimits) -> Bool { length <= limits.maxShortBreakWeeks }

    /// A longer break (3.5 rule 4, owner's decision, #32): more than
    /// `maxShortBreakWeeks` break weeks in a row, or more than 14 days off.
    /// It returns by the steps of `longReturn`. False when the ramp is off
    /// (`maxShortBreakWeeks` 0) or `longerBreakReturnSteps` is empty, so those
    /// switches restore the plain rules.
    func isLonger(_ limits: GuardrailLimits) -> Bool {
        guard limits.maxShortBreakWeeks >= 1, !limits.longerBreakReturnSteps.isEmpty else { return false }
        return length > limits.maxShortBreakWeeks || longerByDays
    }
}

/// One week of the return after a longer break (SPEC 3.5 rule 4, owner's
/// decision, #32). Return weeks are counted one per Monday-start week from the
/// week after the break and never restart; the step is the ceiling a week
/// takes, and a restart (a return week run short) sets the next week's step
/// back to 1.
struct LongReturn: Equatable, Sendable {
    let brk: LoadBreak
    /// 1 for the week after the break's last break week. The session limits
    /// (no quality in week 1, at most one in week 2) go by this number.
    let returnWeek: Int
    /// 1 to `longerBreakReturnSteps.count`. The ceiling goes by this number.
    let step: Int
    /// Most the week may hold outside races: the step's share of the
    /// pre-break level, and in a week that restarts the steps at least the
    /// volume of the short week before it (the ceiling is never below the
    /// week run).
    let ceiling: Double
    /// True when the week is step 1 because the week before was run short.
    let restarted: Bool
    /// True when `ceiling` is the short week's own volume rather than the step's share.
    let raisedToWeekRun: Bool
}

/// One week of the return ramp after a short break (SPEC 3.5 rules 2 and 4).
struct ReturnRamp: Equatable, Sendable {
    /// 1 for the first week back.
    let step: Int
    let brk: LoadBreak
    /// Most the week may hold outside races.
    let allowed: Double
    /// True when the rise over the week before, not the ramp step, sets `allowed`.
    let limitedByWeekBefore: Bool
}

extension GuardrailChecker {
    /// The breaks in a series of weekly volumes outside races (`volumes`,
    /// nil where unknown, with known parts `lows`), in order. A week of
    /// unknown volume or with a race is never a break week (the conservative
    /// reading: the plain rules then apply). `notBreak` is a week counted as
    /// no break week whatever its volume (the plan builder's open start week,
    /// just over the line). Exactly at the line is a break week.
    static func breaks(volumes: [Double?], lows: [Double], raceWeeks: Set<Int>, notBreak: Int? = nil,
                       limits: GuardrailLimits) -> [LoadBreak] {
        let ratio = limits.breakWeekMaxRatio
        let window = limits.preBreakWeeks
        guard ratio.isFinite, ratio > 0, window >= 1 else { return [] }
        func low(_ k: Int) -> Double { volumes[k] ?? (k < lows.count ? max(0, lows[k]) : 0) }
        var out: [LoadBreak] = []
        var j = 0
        while j < volumes.count {
            let before = max(0, j - window)..<j
            guard !before.isEmpty else { j += 1; continue }
            let level = before.reduce(0) { $0 + low($1) } / Double(before.count)
            func isBreak(_ k: Int) -> Bool {
                guard k != notBreak, !raceWeeks.contains(k), let v = volumes[k] else { return false }
                return v <= ratio * level
            }
            guard level > 0, level.isFinite, isBreak(j) else { j += 1; continue }
            var k = j
            while k < volumes.count && isBreak(k) { k += 1 }
            out.append(LoadBreak(first: j, length: k - j, level: level))
            j = k
        }
        return out
    }

    /// True when every week a short break `b` and the weeks after it up to
    /// `through` depend on has a known volume: from `preBreakWeeks +
    /// maxShortBreakWeeks + 1` weeks before its first week (the weeks that
    /// set whether it and the weeks just before it are break weeks) to
    /// `through`. A week of unknown volume there could hide a longer break,
    /// or a break the lower bounds don't show, so the ramp and the rolling
    /// substitution are not used and the plain rules apply (the conservative
    /// reading for unknown weeks, #40). Heuristic.
    static func isCertain(_ b: LoadBreak, through: Int, volumes: [Double?], limits: GuardrailLimits) -> Bool {
        let from = max(0, b.first - max(0, limits.preBreakWeeks) - max(0, limits.maxShortBreakWeeks) - 1)
        let to = min(through, volumes.count - 1)
        guard from <= to else { return true }
        return (from...to).allSatisfy { volumes[$0] != nil }
    }

    /// The return-ramp cap on week `i` (SPEC 3.5 rules 2 and 4), or nil when
    /// week `i` is not one of the `breakReturnSteps.count` weeks after a short
    /// break. Step `k` allows `breakReturnSteps[k-1]` × the pre-break level,
    /// and from step 2 on also at most the ramp's own rise over the week
    /// before (`steps[k-1] / steps[k-2]` × its volume, at its known part), so
    /// a runner who came back lower than the ramp is not jumped to it. This
    /// replaces the 10% check for those weeks. Heuristic.
    static func returnRamp(_ i: Int, volumes: [Double?], lows: [Double], breaks: [LoadBreak],
                           limits: GuardrailLimits) -> ReturnRamp? {
        let steps = limits.breakReturnSteps
        guard !steps.isEmpty, steps.allSatisfy({ $0.isFinite && $0 > 0 }) else { return nil }
        guard !breaks.contains(where: { i >= $0.first && i < $0.end }),
              let b = breaks.last(where: { $0.end <= i }), b.isShort(limits),
              isCertain(b, through: i - 1, volumes: volumes, limits: limits) else { return nil }
        let k = i - b.end + 1
        guard k >= 1, k <= steps.count else { return nil }
        var allowed = steps[k - 1] * b.level
        var byWeekBefore = false
        if k >= 2, i >= 1, i - 1 < volumes.count {
            let before = volumes[i - 1] ?? (i - 1 < lows.count ? max(0, lows[i - 1]) : 0)
            let rise = before * steps[k - 1] / steps[k - 2]
            if rise < allowed { allowed = rise; byWeekBefore = true }
        }
        return ReturnRamp(step: k, brk: b, allowed: allowed, limitedByWeekBefore: byWeekBefore)
    }

    /// The least return-ramp cap on week `i` under a short break that a week
    /// of unknown volume nearby may hide (#40), or nil when none may. The
    /// break detection reads unknown weeks at their known part and never as
    /// break weeks, so a break it doesn't see, or sees but can't be sure of
    /// (`isCertain`), may still hold in truth, and then the ramp would cap
    /// week `i` lower than the plain 10% rule. A candidate is a run of 1 to
    /// `maxShortBreakWeeks` weeks ending 1 to `breakReturnSteps.count` weeks
    /// before `i`, each of which may be a break week (no race, and its known
    /// part at most the line of a pre-break level that may be unbounded when
    /// that level's weeks hold an unknown one and `unbounded` is true), with
    /// an unknown week in it or in the weeks its status rests on. Its cap is
    /// read at the least it can be: the step × the least pre-break level
    /// that makes it a break (its known parts, or the run's largest week over
    /// the break line if that is more), and from step 2 on the ramp's own
    /// rise over the known part of the week before. With `unbounded` false a
    /// pre-break level is read only at its known parts, as the detection
    /// reads it (an unknown week there is not taken as arbitrarily large).
    /// Heuristic, the conservative reading.
    static func hiddenBreakFloor(_ i: Int, volumes: [Double?], lows: [Double], raceWeeks: Set<Int>,
                                 unbounded: Bool, limits: GuardrailLimits) -> Double? {
        hiddenBreaks(i, volumes: volumes, lows: lows, raceWeeks: raceWeeks, unbounded: unbounded, limits: limits)
            .map(\.cap).min()
    }

    /// The least number of quality sessions the return ramp of a hidden short
    /// break (`hiddenBreakFloor`'s candidates) could allow in week `i` (3.5
    /// rule 4), or nil when no candidate puts week `i` in weeks 1 or 2 back.
    static func hiddenBreakMaxQuality(_ i: Int, volumes: [Double?], lows: [Double], raceWeeks: Set<Int>,
                                      unbounded: Bool, limits: GuardrailLimits) -> Int? {
        hiddenBreaks(i, volumes: volumes, lows: lows, raceWeeks: raceWeeks, unbounded: unbounded, limits: limits)
            .compactMap { limits.returnRampMaxQuality(step: $0.step) }.min()
    }

    /// `hiddenBreakFloor`'s candidates: for each, the ramp week `step` that
    /// week `i` would be and the cap it would set there.
    static func hiddenBreaks(_ i: Int, volumes: [Double?], lows: [Double], raceWeeks: Set<Int>,
                             unbounded: Bool, limits: GuardrailLimits) -> [(step: Int, cap: Double)] {
        let steps = limits.breakReturnSteps
        let ratio = limits.breakWeekMaxRatio
        let window = limits.preBreakWeeks
        let maxLength = limits.maxShortBreakWeeks
        guard !steps.isEmpty, steps.allSatisfy({ $0.isFinite && $0 > 0 }), ratio.isFinite, ratio > 0,
              window >= 1, maxLength >= 1, i >= 2, i <= volumes.count else { return [] }
        func low(_ k: Int) -> Double { volumes[k] ?? (k < lows.count ? max(0, lows[k]) : 0) }
        // The pre-break level before week `f`: at known parts (a lower bound)
        // and its upper bound (infinite when a week in it is unknown).
        func level(_ f: Int) -> (low: Double, high: Double)? {
            let before = max(0, f - window)..<f
            guard !before.isEmpty else { return nil }
            let lo = before.reduce(0) { $0 + low($1) } / Double(before.count)
            let hi = unbounded && before.contains { volumes[$0] == nil } ? Double.infinity : lo
            return (lo, hi)
        }
        var out: [(step: Int, cap: Double)] = []
        for k in 1...steps.count {
            let e = i - k                       // the break's last week
            guard e >= 1 else { continue }
            for length in 1...maxLength {
                let f = e - length + 1          // the break's first week
                guard f >= 1, let lvl = level(f), lvl.low > 0 else { continue }
                let weeks = f...e
                guard weeks.allSatisfy({ !raceWeeks.contains($0) && low($0) <= ratio * lvl.high }) else { continue }
                // Only where an unknown week could change what the detection
                // sees: in the run, in the weeks its level rests on, or in the
                // weeks between it and week `i`.
                let span = max(0, f - window - maxLength - 1)..<i
                guard span.contains(where: { volumes[$0] == nil }) else { continue }
                let least = max(lvl.low, (weeks.map(low).max() ?? 0) / ratio)
                var cap = steps[k - 1] * least
                if k >= 2 { cap = min(cap, low(i - 1) * steps[k - 1] / steps[k - 2]) }
                out.append((k, cap))
            }
        }
        return out
    }

    /// Marks the breaks of `brks` that are longer by days: the days off, counted as for the pace
    /// factor (`ReturnPaceSchedule`), are more than 14 although the break
    /// reads as `maxShortBreakWeeks` weeks or fewer (3.5 rule 4). Every day of
    /// a break week counts as off even when it holds a short run, plus the
    /// run-free days on either side up to the nearest run. A run is any
    /// session but a rest day whose duration isn't zero or negative.
    ///
    /// `lastKnown` is the last day whose runs are known (the day before a
    /// mid-week start, for the plan builder's history); the count never goes
    /// past it, and a break that reaches it is still running, so it counts
    /// `ongoingSlack` more days (the builder passes 1: the plan's first run
    /// may come a day later than the history ends, which the checker would
    /// count, so the builder reads such a break as longer a day sooner, the
    /// conservative reading). Without `lastKnown` it is the end of the last week.
    static func longerByDays(_ brks: [LoadBreak], weeks: [PlanWeek], timeZone: TimeZone, limits: GuardrailLimits,
                             lastKnown: Date? = nil, ongoingSlack: Int = 0) -> [LoadBreak] {
        guard !brks.isEmpty, let lastWeek = weeks.last else { return brks }
        let cal = PlanCalendar.calendar(timeZone: timeZone)
        let reference = cal.startOfDay(for: Date(timeIntervalSinceReferenceDate: 0))
        func dayNumber(_ d: Date) -> Int { cal.dateComponents([.day], from: reference, to: cal.startOfDay(for: d)).day ?? 0 }
        let runDays = Set(weeks.flatMap(\.workouts).filter { w in
            w.kind != .rest && !(w.durationSeconds.isFinite && w.durationSeconds <= 0)
                && w.date.timeIntervalSinceReferenceDate.isFinite
        }.map { dayNumber($0.date) })
        guard let firstRun = runDays.min() else { return brks }
        let endOfData = dayNumber(lastWeek.weekEnd) - 1
        let known = lastKnown.map { min(dayNumber($0), endOfData) } ?? endOfData
        return brks.map { b in
            var out = b
            guard b.first >= 0, b.end - 1 < weeks.count else { return out }
            var lo = dayNumber(weeks[b.first].weekStart)
            var hi = min(dayNumber(weeks[b.end - 1].weekEnd) - 1, known)
            while lo - 1 >= firstRun, !runDays.contains(lo - 1) { lo -= 1 }
            while hi + 1 <= known, !runDays.contains(hi + 1) { hi += 1 }
            let ongoing = hi >= known && !runDays.contains(known + 1)
            let days = hi - lo + 1 + (ongoing ? max(0, ongoingSlack) : 0)
            out.longerByDays = days > 14
            return out
        }
    }

    /// True when the weeks a longer break `b` rests on have a known volume:
    /// the weeks of its pre-break level and the break weeks themselves. A week
    /// of unknown volume there could hide a different break, so the steps are
    /// not used and the plain rules apply (the conservative reading for
    /// unknown weeks, #40). Return weeks of unknown volume are read at their
    /// known part, which only makes a week look shorter (a restart).
    static func isCertainLonger(_ b: LoadBreak, volumes: [Double?], limits: GuardrailLimits) -> Bool {
        let from = max(0, b.first - max(0, limits.preBreakWeeks))
        let to = min(b.end - 1, volumes.count - 1)
        guard from <= to else { return true }
        return (from...to).allSatisfy { volumes[$0] != nil }
    }

    /// True when a return week run at `ran` was run **short** of what it was
    /// planned to hold (`planned`), both outside races: under 1 / (1 +
    /// `regrowthMaxWeeklyRise`), about 83% (SPEC 3.5 rule 4, owner's decision,
    /// #32; the same reading after a pain stop of more than 14 days, rule 7,
    /// #93). A short week restarts the return's steps. Heuristic: the 83% is
    /// derived from rule 6's 20% default, not a separate figure. A tiny margin
    /// keeps a week run at exactly the line from counting as short.
    static func isShortReturnWeek(ran: Double, planned: Double, limits: GuardrailLimits) -> Bool {
        let rise = limits.regrowthMaxWeeklyRise.isFinite ? max(0, limits.regrowthMaxWeeklyRise) : 0
        return ran < planned / (1 + rise) - 1e-9 * max(1, planned)
    }

    /// The weeks of the return after the longer break `b`, from return week
    /// 1 to week `through` (an index that may be the week after the series:
    /// the next week), and the index of the last week of the return so far.
    ///
    /// Steps (3.5 rule 4, owner's decision, #32): the step is 1 in return week
    /// 1, then one step on per week, whatever the week held. A week run
    /// **short**, under 1 / (1 + `regrowthMaxWeeklyRise`) (about 83%) of what
    /// it was planned to hold, sets the next week back to step 1, whose
    /// ceiling is the step's share of the pre-break level or the short week's
    /// volume if that is higher, never below the week run. A week before
    /// `plannedFrom` (a week run before the plan existed) counts as planned at
    /// its step's ceiling; a week from `plannedFrom` on is planned at what it
    /// holds, so it is never short. The return ends with the last step's week
    /// that isn't short; a later break (in `breaks`) ends it too, and that
    /// break's own return follows. A week of unknown volume is read at its
    /// known part (a lower volume: it can only restart sooner, the
    /// conservative reading). Heuristic: the 83% is derived from rule 6's 20%
    /// default, not a separate figure.
    static func longReturnWeeks(_ b: LoadBreak, volumes: [Double?], lows: [Double], breaks: [LoadBreak], plannedFrom: Int,
                                through: Int, limits: GuardrailLimits) -> (weeks: [LongReturn], last: Int, ended: Bool) {
        let steps = limits.longerBreakReturnSteps
        guard !steps.isEmpty, steps.allSatisfy({ $0.isFinite && $0 > 0 }), b.end >= 0 else { return ([], b.end - 1, false) }
        let stop = breaks.first(where: { $0.first >= b.end })?.first ?? Int.max
        var out: [LongReturn] = []
        var step = 1
        var floor: Double?
        var j = b.end
        var last = b.end - 1
        while j <= through, j < stop {
            let share = steps[step - 1] * b.level
            let raised = floor.map { $0 > share } ?? false
            let ceiling = max(share, floor ?? 0)
            out.append(LongReturn(brk: b, returnWeek: j - b.end + 1, step: step, ceiling: ceiling, restarted: floor != nil,
                                  raisedToWeekRun: raised))
            guard j < volumes.count else { break }
            last = j
            let v = volumes[j] ?? (j < lows.count ? max(0, lows[j]) : 0)
            let planned = j >= plannedFrom ? v : ceiling
            let short = isShortReturnWeek(ran: v, planned: planned, limits: limits)
            if step >= steps.count, !short { return (out, last, true) }
            if short { step = 1; floor = v } else { step += 1; floor = nil }
            j += 1
        }
        return (out, last, false)
    }

    /// The return step of week `i` after a longer break (3.5 rule 4), or nil
    /// when week `i` is not a week of such a return: no longer break before
    /// it, a break week itself, a break whose weeks are not all known, or
    /// after the return's end. Both of rule 2's checks measure against the
    /// pre-break level there: this ceiling replaces the 10% check.
    static func longReturn(_ i: Int, volumes: [Double?], lows: [Double], breaks: [LoadBreak], plannedFrom: Int = .max,
                           limits: GuardrailLimits) -> LongReturn? {
        guard i >= 1, !breaks.contains(where: { i >= $0.first && i < $0.end }),
              let b = breaks.last(where: { $0.end <= i }), b.isLonger(limits),
              isCertainLonger(b, volumes: volumes, limits: limits) else { return nil }
        let chain = longReturnWeeks(b, volumes: volumes, lows: lows, breaks: breaks, plannedFrom: plannedFrom, through: i, limits: limits)
        if chain.ended, chain.last < i { return nil }
        return chain.weeks.first { $0.returnWeek == i - b.end + 1 }
    }

    /// Week `k`'s volume as the earlier 4 weeks of the rolling check count it
    /// (SPEC 3.5 rules 2 and 4). Every week from the first break week of a
    /// **longer** break through the end of its return (`longReturnWeeks`)
    /// counts at the pre-break level, so the zero break weeks never make a
    /// week's cap zero or negative; the weeks of a **short** break count at
    /// the pre-break level too, once the week after the break is in the
    /// series. Every other week counts at its volume (known part when
    /// unknown). A week counts at the higher of its volume and the level.
    /// A short break's substitution needs the weeks around it known
    /// (`isCertain`), a longer break's the weeks it rests on
    /// (`isCertainLonger`).
    static func rollingPriorVolume(_ k: Int, volumes: [Double?], lows: [Double], breaks: [LoadBreak],
                                   plannedFrom: Int = .max, limits: GuardrailLimits) -> Double {
        let v = volumes[k] ?? (k < lows.count ? max(0, lows[k]) : 0)
        for b in breaks where b.isLonger(limits) && k >= b.first && isCertainLonger(b, volumes: volumes, limits: limits) {
            let chain = longReturnWeeks(b, volumes: volumes, lows: lows, breaks: breaks, plannedFrom: plannedFrom,
                                        through: volumes.count - 1, limits: limits)
            if k <= chain.last { return max(v, b.level) }
        }
        guard let b = breaks.first(where: { k >= $0.first && k < $0.end }), b.isShort(limits),
              b.end < volumes.count, isCertain(b, through: b.end, volumes: volumes, limits: limits) else { return v }
        return max(v, b.level)
    }

    /// For each week, whether the marathon long-run share applies (SPEC 3.5
    /// rule 5): the week is in or before the week of a race of marathon
    /// distance (`RaceCategory.isMarathonDistance`, within 0.5% of 42,195 m; a
    /// race from 30 km up to it is not one, #30). A race of unknown distance is not
    /// one (the conservative reading: the usual share applies).
    static func marathonWeeks(_ weeks: [PlanWeek]) -> [Bool] {
        let last = weeks.lastIndex { w in
            w.workouts.contains { $0.kind == .race && RaceCategory.isMarathonDistance(meters: $0.distanceMeters) }
        }
        return weeks.indices.map { i in last.map { i <= $0 } ?? false }
    }
}
