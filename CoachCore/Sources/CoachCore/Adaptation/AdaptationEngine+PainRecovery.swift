import Foundation

// SPEC.md 3.5 rule 7 inside the F4 engine (#73): usual pain, the
// next-morning trigger, ending a stop with a test run, the return guards and
// the clinician flag. The pure rules are in `PainRecovery.swift`; every number
// is a heuristic there. The engine calls in from `processRun` (a test run),
// `processCheckIn`, `processPainReport` and, on every event, `finish`
// (`rule7Day` before the stop is enforced, `enforceReturn` after it).
//
// Which rule judges a run (SPEC 3.5 rule 7): inside a test run, in-run pain is
// judged only by the test-run limits; during the return, symptoms on a run
// follow the recurrence rule; outside those, pain that got worse during a run
// stops running. The next-morning trigger, a movement change and a red flag
// always stop at once (in the return they reopen the stop).
//
// The restart (SPEC 3.5 rule 7, 0.8, owner-approved Nov 24, #93): after a
// stop of more than 14 days, a return week run under 1 / (1 + 20%) (about
// 83%) of what it was planned to hold sets the next week back to step 1, its
// ceiling never below the week actually run, as after a longer break (rule 4).
// `judgeReturnWeeks` reads each finished return week once, at the week's own
// time (never the time before an easy-run cap, #54), and keeps the result in
// `PainReturn` (`restartWeek`, `restartFloor`, `judgedThrough`).

/// What rule 7 told the app during one event (see `PainCourseStatus`).
struct PainEventNotes: Equatable, Sendable {
    var askForReport = false
    var flagClosed = false
    var returnStarted = false
}

extension AdaptationEngine.Work {
    /// One report's place in the clinician flag's count of reports in a row
    /// at or below usual.
    enum FlagItem { case atOrBelow, above, pending, passedTest }

    var recoveryLimits: PainRecoveryLimits { context.painRecoveryLimits }

    /// True while a stop, the return or the clinician flag is active: usual
    /// pain is frozen and check-ins are not stable.
    var painCourseActive: Bool {
        state.painStop != nil || state.painRecovery.painReturn != nil || state.painRecovery.flag != nil
    }

    /// Usual pain now: the frozen value while rule 7 is active, otherwise from
    /// the runner's own stable check-ins and interview seed (`UsualPain`).
    func usualPain() -> Int {
        state.painRecovery.frozenUsual
            ?? UsualPain.value(samples: state.painRecovery.usualSamples, seed: context.usualPainSeed,
                               tracksPain: context.tracksPain, limits: recoveryLimits)
    }

    func days(from a: Date, to b: Date) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: a), to: calendar.startOfDay(for: b)).day ?? 0
    }

    func addDays(_ n: Int, to d: Date) -> Date {
        calendar.date(byAdding: .day, value: n, to: d) ?? d.addingTimeInterval(Double(n) * 86_400)
    }

    func weekOf(_ d: Date) -> Date { PlanCalendar.weekStart(containing: d, timeZone: tz) }

    // MARK: Events

    /// Keeps a stable post-run check-in for usual pain (pain trackers only,
    /// and only while rule 7 is not active).
    mutating func recordStableSample(date: Date, score: Int) {
        guard context.tracksPain, !painCourseActive, PainCheckIn.validScores.contains(score),
              date.timeIntervalSinceReferenceDate.isFinite else { return }
        let all = (state.painRecovery.usualSamples + [UsualPainSample(date: date, score: score)]).sorted { $0.date < $1.date }
        state.painRecovery.usualSamples = Array(all.suffix(max(1, recoveryLimits.usualWindow)))
    }

    /// A run matched to the test run marks the test as run.
    mutating func rule7Run(_ a: Activity, matched: PlannedWorkout?) {
        adoptStoredStop()
        judgeReturnWeeks(asOf: a.start)
        guard var t = state.painRecovery.test, t.activityID == nil, let m = matched, m.id == t.workoutID else { return }
        t.activityID = a.id
        t.ranAt = a.start
        state.painRecovery.test = t
    }

    /// A pain check-in is a post-run report: stable for usual pain when rule 7
    /// is not active; during the return, symptoms on the run it follows.
    mutating func rule7CheckIn(_ c: PainCheckIn) {
        adoptStoredStop()
        guard PainCheckIn.validScores.contains(c.score), c.date.timeIntervalSinceReferenceDate.isFinite else { return }
        judgeReturnWeeks(asOf: c.date)
        let u = usualPain()
        recordStableSample(date: c.date, score: c.score)
        if let r = state.painRecovery.painReturn,
           PainReturnRule.symptoms(level: c.score, changedMovement: false,
                                   step: r.symptomStep(atWeek: weekOf(c.date), timeZone: tz, limits: recoveryLimits),
                                   usual: u, limits: recoveryLimits) {
            recurrence(at: c.date, level: c.score, sourceID: nil, usual: u)
        }
        let item: FlagItem = c.score > u ? .above : .atOrBelow
        if item == .above, state.painStop != nil { restartCount(at: c.date) }
        noteFlagReport(item, at: c.date)
    }

    /// A pain report under rule 7: judges a test run, return symptoms, the
    /// next-morning trigger and its freeze band, starts, makes stricter or
    /// reopens a stop, and keeps the clinician flag's count.
    mutating func rule7Report(_ report: PainReport) {
        adoptStoredStop()
        judgeReturnWeeks(asOf: report.date)
        let u = usualPain()
        let hours = hoursSinceRun(report)
        var fired = report.stopTriggers(usual: u, hoursSinceRun: hours, limits: recoveryLimits)
        // A report that starts a stop is not a stable check-in (heuristic, SPEC 3.5 rule 7).
        if report.timing == .afterRun, fired.isEmpty, let s = report.validScore { recordStableSample(date: report.date, score: s) }
        var item: FlagItem = report.isAbove(usual: u) || !fired.isEmpty ? .above : .atOrBelow
        let rec = state.painRecovery

        if report.timing == .afterRun, var t = rec.test, t.inRunPassed == nil, let ranAt = t.ranAt,
           report.activityID.map({ $0 == t.activityID }) ?? (report.date >= ranAt) {
            // The test run's in-run report: judged only by the test-run limits.
            fired.removeAll { $0 == .worsenedDuringRun }
            if PainStopEndRule.inRunPasses(report, usual: u, stopFromMovement: rec.stopFromMovement, limits: recoveryLimits) {
                t.inRunPassed = true
                state.painRecovery.test = t
                item = .pending
            } else {
                failTest(t, at: report.date, usual: u,
                         why: "pain during it was \(level(report)), above what a test run allows (at most \(min(u + recoveryLimits.testAllowance, recoveryLimits.testMaxScore))/10\(rec.stopFromMovement ? ", and no more than your usual \(u)/10 after a change in how you moved" : ""), with no change in how you move)")
                item = .above
            }
        } else if report.timing == .afterRun, let r = rec.painReturn {
            // During the return, symptoms on a run follow the recurrence rule.
            fired.removeAll { $0 == .worsenedDuringRun }
            item = report.isAbove(usual: u) || !fired.isEmpty ? .above : .atOrBelow
            let step = r.symptomStep(atWeek: weekOf(report.date), timeZone: tz, limits: recoveryLimits)
            if fired.isEmpty, PainReturnRule.symptoms(level: report.painLevel, changedMovement: report.changedMovement,
                                                      step: step, usual: u, limits: recoveryLimits) {
                recurrence(at: report.date, level: report.painLevel, sourceID: report.activityID, usual: u)
                item = .above
            }
        } else if report.timing == .nextMorning, let t = rec.test, let ranAt = t.ranAt, report.date > ranAt {
            // The morning after the test run.
            if t.inRunPassed == true, fired.isEmpty, !report.isAbove(usual: u), report.redFlags.isEmpty, !report.changedMovement {
                noteFlagReport(.passedTest, at: report.date)
                endStop(after: t, at: report, usual: u)
                return
            }
            failTest(t, at: report.date, usual: u,
                     why: t.inRunPassed == nil ? "no pain report came from the test run itself"
                        : "the next morning pain was \(level(report)), above your usual \(u)/10")
            item = .above
        }

        if report.timing == .nextMorning, state.painStop == nil, fired.isEmpty {
            let v = NextMorningRule.verdict(report, usual: u, hoursSinceRun: hours, limits: recoveryLimits)
            let rising = NextMorningRule.risingOverWeeks(state.painReports, asOf: report.date, timeZone: tz, limits: recoveryLimits)
            if v == .freeze || rising { morningFreeze(report, usual: u, rising: v != .freeze) }
        }
        if !fired.isEmpty { applyTriggers(fired, report: report, usual: u) }
        if item == .above, state.painStop != nil { restartCount(at: report.date) }
        noteFlagReport(item, at: report.date)
    }

    func level(_ r: PainReport) -> String { r.painLevel.map { "\($0)/10" } ?? "of unknown size" }

    /// Hours from the end of the run a report follows (the run it names, or
    /// the latest run before it) to the report; nil with no run.
    func hoursSinceRun(_ r: PainReport) -> Double? {
        let named = r.activityID.flatMap { id in history.first { $0.id == id } }
        guard let run = named ?? history.filter({ $0.kind != .rest && $0.date <= r.date }).max(by: { $0.date < $1.date })
        else { return nil }
        let d = run.durationSeconds.isFinite && run.durationSeconds > 0 ? run.durationSeconds : 0
        let h = r.date.timeIntervalSince(run.date.addingTimeInterval(d)) / 3600
        return h.isFinite ? max(0, h) : nil
    }

    /// Any report above usual during a stop restarts the 2-morning count, so
    /// the 2 mornings and the passed test run are always 3 reports in a row
    /// at or below usual, as the clinician flag's off rule needs (SPEC 3.5
    /// rule 7: "Ending the stop always meets this"). A morning above usual is
    /// the case the spec names.
    mutating func restartCount(at date: Date) {
        state.painRecovery.countFrom = max(state.painRecovery.countFrom ?? date, date)
    }

    // MARK: Stop triggers

    /// Starts, tightens or (during the return) reopens a stop for `fired`,
    /// and raises the clinician flag for a red flag or within 6 weeks of the
    /// flag turning off or closing.
    mutating func applyTriggers(_ fired: [PainStopTrigger], report: PainReport, usual u: Int) {
        if let r = state.painRecovery.painReturn {
            reopenStop(fired, at: report.date, sourceID: report.activityID, from: r, usual: u)
            // The stricter reading (#92): a movement change in the return is
            // a lasting one, a red flag. Heuristic, SPEC 3.5 rule 7.
            if fired.contains(.changedMovement) || report.redFlags.contains(.lastingMovementChange) {
                raiseFlag(.movementChangeInReturn, at: report.date)
            }
        } else {
            let wasStopped = state.painStop != nil
            painStopRule(report, fired: fired)
            if !wasStopped, state.painStop != nil { beginStop(usual: u, fromMovement: fired.contains(.changedMovement)) }
        }
        guard state.painStop != nil else { return }
        if fired.contains(.changedMovement) { state.painRecovery.stopFromMovement = true }
        restartCount(at: report.date)
        if fired.contains(.redFlag) { raiseFlag(.redFlag, at: report.date) }
        if state.painRecovery.flag == nil, let end = state.painRecovery.flagEnded,
           days(from: end.date, to: report.date) <= recoveryLimits.flagReopenDays {
            raiseFlag(.reopened, at: report.date)
        }
    }

    /// A stop stored before rule 7's state existed (format version 2) has no
    /// bookkeeping: none was recorded when it began. Fill it in from the stop
    /// itself, conservatively: usual frozen at its value now, the 2-morning
    /// count from the stop's start, and a movement change or red flag among
    /// its triggers read as a movement stop (a red flag may be a lasting
    /// movement change), so the stricter test-run limit applies. Heuristic,
    /// SPEC 3.5 rule 7. Runs at the start of every event; does nothing once
    /// the count is recorded.
    mutating func adoptStoredStop() {
        guard let stop = state.painStop, state.painRecovery.countFrom == nil else { return }
        let fromMovement = stop.triggers.contains(.changedMovement) || stop.triggers.contains(.redFlag)
        beginStop(usual: usualPain(), fromMovement: fromMovement)
        // The plan handed in is already in the stop's shape (a rest-mode stop
        // has turned its long runs into rest days), so it doesn't record the
        // plan before the stop, and the pre-stop long run may be gone: take
        // the lowest of what the plan still shows, the long-run share of the
        // stop's level and the longest long run in the spike window before
        // the stop.
        state.painRecovery.prePlanWeeks = []
        let measure = context.guardrails.measure
        let from = addDays(-max(1, context.guardrails.spikeWindowDays), to: stop.since)
        let ranLong = history.filter { $0.kind == .long && $0.date >= from && $0.date < stop.since }
            .compactMap { $0.volume(measure) }.filter { $0 > 0 && $0.isFinite }.max()
        let share = context.guardrails.maxLongRunShare
        let ofLevel = stop.level.flatMap { l in l > 0 && l.isFinite && share.isFinite && share > 0 ? l * min(1, share) : nil }
        state.painRecovery.preStopLongRun = [state.painRecovery.preStopLongRun, ofLevel, ranLong].compactMap { $0 }.min()
    }

    /// Rule 7's bookkeeping when a stop begins: freeze usual at its pre-stop
    /// value, start the 2-morning count, and keep the pre-stop long run. A
    /// stop that begins with usual at or above `cannotEndUsual` can't end by
    /// the test run: the runner stays stopped with the clinician flag on
    /// (#85 is the open question on a way out after a clinician visit).
    mutating func beginStop(usual u: Int, fromMovement: Bool) {
        guard let stop = state.painStop else { return }
        var rec = state.painRecovery
        let frozen = rec.frozenUsual ?? u
        rec.frozenUsual = frozen
        rec.countFrom = stop.since
        rec.test = nil
        rec.cannotEnd = frozen >= recoveryLimits.cannotEndUsual
        rec.stopFromMovement = fromMovement
        rec.preStopLongRun = preStopLongRun(since: stop.since)
        rec.prePlanWeeks = planWeeks(from: weekOf(stop.since), handedIn)
        rec.flaggedThisStop = false
        state.painRecovery = rec
        if rec.cannotEnd { raiseFlag(.staysStopped, at: stop.since) }
    }

    /// Weekly run volumes of `sessions` from `week` on, races and rest left out.
    func planWeeks(from week: Date, _ sessions: [PlannedWorkout]) -> [PlanWeekVolume] {
        let weeks = Set(sessions.map { weekOf($0.date) }.filter { $0 >= week })
        return weeks.sorted().map { PlanWeekVolume(week: $0, volume: runVolume(inWeek: $0, sessions)) }
    }

    /// The longest long run of the stop's week and the week before it, runs
    /// done from the stop on left out; else the longest in the spike window
    /// before the stop. In the guardrail measure; nil when none is known.
    func preStopLongRun(since: Date) -> Double? {
        let measure = context.guardrails.measure
        let week = weekOf(since)
        let weeks: Set<Date> = [week, shift(week, weeks: -1)]
        let before = history.filter { $0.date < since }
        let near = (before + plan).filter { $0.kind == .long && weeks.contains(weekOf($0.date)) }
            .compactMap { $0.volume(measure) }.filter { $0 > 0 && $0.isFinite }
        if let m = near.max() { return m }
        let from = addDays(-max(1, context.guardrails.spikeWindowDays), to: since)
        return before.filter { $0.kind == .long && $0.date >= from }.compactMap { $0.volume(measure) }
            .filter { $0 > 0 && $0.isFinite }.max()
    }

    /// A trigger during the return reopens the stop at once: the return ends,
    /// the stop starts again at the pre-stop level, usual stays frozen.
    mutating func reopenStop(_ fired: [PainStopTrigger], at date: Date, sourceID: String?, from r: PainReturn, usual u: Int) {
        let mode = PainStopRule.mode(for: fired, limits: context.painStopLimits) ?? .easyOnly
        state.painRecovery.painReturn = nil
        state.painStop = PainStop(since: date, mode: mode, triggers: fired, lastTriggered: date,
                                  level: r.level ?? stopLevel(since: date))
        var rec = state.painRecovery
        rec.frozenUsual = rec.frozenUsual ?? u
        rec.countFrom = date
        rec.test = nil
        rec.cannotEnd = (rec.frozenUsual ?? u) >= recoveryLimits.cannotEndUsual
        rec.stopFromMovement = r.fromMovement || fired.contains(.changedMovement)
        rec.preStopLongRun = r.preStopLongRun
        rec.prePlanWeeks = r.planWeeks
        rec.flaggedThisStop = false
        state.painRecovery = rec
        let what = mode == .rest ? "every run to come becomes a rest day" : "every quality session to come becomes an easy run"
        changes.append(PlanChange(
            kind: .painStop, workoutIDs: [], triggers: stopTriggers(state.painStop!, report: nil) + [stepTrigger(r, at: date)],
            rule: Self.stopRule,
            explanation: "On \(day(date)) the pain \(fired.map(\.words).joined(separator: " and ")) during your return, so the pain stop starts again: \(what), and the stop ends the same way as before (2 mornings at or below your usual pain, walking pain at 2/10 or less, and a passed test run). This is a training adjustment, not a diagnosis. (Heuristic, SPEC 3.5 rule 7.)"))
    }

    /// A next-morning report 1 above usual, or next-morning pain rising over
    /// successive weeks: volume growth freezes for a week, as after a check-in.
    mutating func morningFreeze(_ r: PainReport, usual u: Int, rising: Bool) {
        guard !state.freezes.contains(where: { $0.checkIn == r.date }) else { return }
        let end = addDays(max(1, recoveryLimits.freezeDays), to: r.date)
        state.freezes.append(VolumeFreeze(interval: DateInterval(start: r.date, end: end), checkIn: r.date))
        let score = Double(r.painLevel ?? 0)
        let why = rising ? "your next-morning pain has risen week after week"
            : "it is 1 above your usual \(u)/10, which freezes growth rather than stopping running"
        changes.append(PlanChange(
            kind: .painVolumeFreeze, workoutIDs: [],
            triggers: [TriggerMetric(metric: .painScore, value: score, expectedHigh: Double(u), unit: .painScore,
                                     sourceID: r.activityID,
                                     detail: "next-morning pain \(level(r)) on \(day(r.date)) against your usual \(u)/10")],
            rule: "SPEC 3.5 rule 7 (heuristic), section 8",
            explanation: "You rated next-morning pain \(level(r)) on \(day(r.date)), and \(why). As a precaution, weekly volume won't grow for \(recoveryLimits.freezeDays) days (until \(day(end))). This is a training adjustment, not a diagnosis. (Heuristic, SPEC 3.5 rule 7.)"))
    }

    // MARK: Clinician flag

    /// Raises the clinician flag (or adds a reason to it). Every caller has
    /// started or reopened a stop, or one stands (SPEC 3.5 rule 7).
    mutating func raiseFlag(_ why: ClinicianFlagReason, at date: Date) {
        var rec = state.painRecovery
        if var f = rec.flag {
            if !f.reasons.contains(why) { f.reasons.append(why) }
            f.streak = 0
            f.streakHasPassedTest = false
            rec.flag = f
        } else {
            rec.flag = ClinicianFlag(raisedAt: date, reasons: [why])
        }
        rec.frozenUsual = rec.frozenUsual ?? usualPain()
        rec.flaggedThisStop = true
        state.painRecovery = rec
    }

    /// Counts a report for the flag: `flagReportsToClear` in a row at or
    /// below usual, one of them a passed test run, turn it off.
    mutating func noteFlagReport(_ item: FlagItem, at date: Date) {
        guard var f = state.painRecovery.flag else { return }
        f.lastReport = max(f.lastReport ?? date, date)
        f.askedAt = nil
        switch item {
        case .atOrBelow: f.streak += 1
        case .above: f.streak = 0; f.streakHasPassedTest = false
        case .pending: break
        case .passedTest: f.streak += 1; f.streakHasPassedTest = true
        }
        state.painRecovery.flag = f
        if f.clears(recoveryLimits) { endFlag(at: date, how: .cleared) }
    }

    mutating func endFlag(at date: Date, how: ClinicianFlagEnd.How) {
        guard state.painRecovery.flag != nil else { return }
        state.painRecovery.flag = nil
        state.painRecovery.flagEnded = ClinicianFlagEnd(date: date, how: how)
        if how == .closedUnresolved { painNotes.flagClosed = true }
    }

    // MARK: Ending a stop

    /// A test run that didn't pass: it is cleared and the 2-morning count
    /// starts again, so a stop lasts at least about 3 days.
    mutating func failTest(_ t: PainTestRun, at date: Date, usual u: Int, why: String) {
        state.painRecovery.test = nil
        state.painRecovery.countFrom = max(state.painRecovery.countFrom ?? date, date)
        changes.append(PlanChange(
            kind: .painTestRunFailed, workoutIDs: [t.workoutID],
            triggers: [TriggerMetric(metric: .painScore, value: Double(u), expectedHigh: Double(u), unit: .painScore,
                                     sourceID: t.activityID, detail: "test run on \(day(t.ranAt ?? t.offeredAt)): \(why)")],
            rule: Self.stopRule,
            explanation: "The test run on \(day(t.ranAt ?? t.offeredAt)) didn't pass: \(why). The pain stop stays, and the count of 2 mornings at or below your usual pain starts again. This is a training adjustment, not a diagnosis. (Heuristic, SPEC 3.5 rule 7.)"))
    }

    /// The test run passed: the stop is cleared, the clinician flag with it
    /// (the end path is always 3 reports in a row at or below usual with a
    /// passed test run), and the return starts.
    mutating func endStop(after t: PainTestRun, at report: PainReport, usual u: Int) {
        guard let stop = state.painStop else { return }
        let start = report.date
        let week = weekOf(start)
        let stepWeek = calendar.startOfDay(for: start) == week ? week : shift(week, weeks: 1)
        let r = PainReturn(start: start, level: stop.level ?? returnLevelFallback(before: stop.since),
                           preStopLongRun: state.painRecovery.preStopLongRun,
                           daysOff: daysOff(before: t), fromMovement: state.painRecovery.stopFromMovement,
                           step: 1, stepWeek: stepWeek, planWeeks: state.painRecovery.prePlanWeeks)
        state.painStop = nil
        var rec = state.painRecovery
        rec.painReturn = r
        rec.prePlanWeeks = []
        rec.test = nil
        rec.countFrom = nil
        rec.cannotEnd = false
        rec.flaggedThisStop = false
        state.painRecovery = rec
        endFlag(at: start, how: .cleared)
        painNotes.returnStarted = true
        let off = r.daysOff.map { " You had \($0) \($0 == 1 ? "day" : "days") without running before the test run." } ?? ""
        changes.append(PlanChange(
            kind: .painStopEnded, workoutIDs: [t.workoutID],
            triggers: [TriggerMetric(metric: .painScore, value: Double(report.painLevel ?? 0), expectedHigh: Double(u),
                                     unit: .painScore, sourceID: t.activityID,
                                     detail: "pain the morning after the test run: \(level(report)), at or below your usual \(u)/10")],
            rule: Self.stopRule,
            explanation: "Your test run on \(day(t.ranAt ?? start)) passed and the next morning was at or below your usual pain, so the pain stop ends.\(off) The return is gradual: this week easy runs on alternate days with the long run capped at \(PlanFormatting.percent(recoveryLimits.week1Fraction)) of your pre-stop long run, then volume grows back to the plan over the next weeks, and quality sessions return only after a full week at plan volume with no symptoms. If symptoms come back on a run, stop the run; the next day is rest and the plan goes back a step. (Heuristic, SPEC 3.5 rules 4, 6 and 7.)"))
    }

    /// The return's level when the stop has none, so the return always has a
    /// weekly ceiling: the latest week in the spike window before the stop
    /// with a finite run volume above 0 (races left out), at most a small
    /// floor (`unknownLevelSeconds` or `unknownLevelMetres`); the floor alone
    /// when there is none. Heuristic, SPEC 3.5 rule 7, pending the owner's
    /// OK (#92).
    func returnLevelFallback(before since: Date) -> Double {
        let measure = context.guardrails.measure
        let floor = measure == .distance ? recoveryLimits.unknownLevelMetres : recoveryLimits.unknownLevelSeconds
        let from = addDays(-max(1, context.guardrails.spikeWindowDays), to: since)
        var weeks: [Date: Double] = [:]
        for w in history where w.date < since && w.date >= from && w.kind != .race {
            let v = GuardrailRepair.volume(w, measure)
            if v.isFinite, v > 0 { weeks[weekOf(w.date), default: 0] += v }
        }
        if let latest = weeks.keys.max(), let v = weeks[latest], v.isFinite, v > 0 { return min(v, floor) }
        return floor
    }

    /// Days with no running before the test run (rule 4 decides from them);
    /// nil when no earlier run is known.
    func daysOff(before t: PainTestRun) -> Int? {
        guard let ran = t.ranAt else { return nil }
        guard let prev = history.filter({ $0.kind != .rest && $0.id != t.activityID && $0.date < ran && ($0.volume(.time) ?? 1) > 0 })
            .map(\.date).max() else { return nil }
        return max(0, days(from: prev, to: ran) - 1)
    }

    // MARK: The return

    /// Symptoms came back on a run during the return: the next day is rest
    /// and the plan goes back one step (week 1 repeats); a second failure at
    /// the same step reopens the stop with the clinician flag on.
    mutating func recurrence(at date: Date, level: Int?, sourceID: String?, usual u: Int) {
        guard var r = state.painRecovery.painReturn else { return }
        let week = weekOf(date)
        let s = r.step(atWeek: week, timeZone: tz, limits: recoveryLimits)
        if r.failedSteps.contains(s) {
            reopenStop([.recurredInReturn], at: date, sourceID: sourceID, from: r, usual: u)
            raiseFlag(.secondFailure, at: date)
            return
        }
        r.failedSteps.append(s)
        r.step = max(1, s - 1)
        r.stepWeek = shift(week, weeks: 1)
        r.restDay = addDays(1, to: calendar.startOfDay(for: date))
        state.painRecovery.painReturn = r
        let back = s <= 1 ? "week 1 of the return repeats" : "the plan goes back to step \(r.step) of the return for a week"
        changes.append(PlanChange(
            kind: .painReturnStep, workoutIDs: [],
            triggers: [stepTrigger(r, at: date, was: s),
                       TriggerMetric(metric: .painScore, value: Double(level ?? 10), expectedHigh: Double(u), unit: .painScore,
                                     sourceID: sourceID, detail: "pain on a return run on \(day(date)): \(level.map { "\($0)/10" } ?? "of unknown size") against your usual \(u)/10")],
            rule: Self.stopRule,
            explanation: "Symptoms came back on your run on \(day(date)). End the run there; \(day(r.restDay!)) is a rest day and \(back). A second time at the same step starts the pain stop again. This is a training adjustment, not a diagnosis. (Heuristic, SPEC 3.5 rule 7, [20].)"))
    }

    func stepTrigger(_ r: PainReturn, at date: Date, was: Int? = nil) -> TriggerMetric {
        let s = was ?? r.step(atWeek: weekOf(date), timeZone: tz, limits: recoveryLimits)
        return TriggerMetric(metric: .painReturnStep, value: Double(s), unit: .count,
                             detail: "step \(s) of the return after the pain stop that ended on \(day(r.start))")
    }

    /// Weekly ceilings of the return (rule 7's week 1, then the lower of rule
    /// 6's regrowth and rule 4's ramp; after a restart, step 1 again with the
    /// week run as its floor) as volume holds, one per plan week
    /// from the return's start until a step at full plan volume. The week the
    /// return starts in, when it starts after that week's first day, allows
    /// what was already run before the return plus the step's ceiling for
    /// the days left (heuristic).
    func returnHolds() -> [VolumeHold] {
        guard let r = state.painRecovery.painReturn, let level = r.level, level > 0, level.isFinite else { return [] }
        let measure = context.guardrails.measure
        var out: [VolumeHold] = []
        let startDay = calendar.startOfDay(for: r.start)
        var week = weekOf(r.start)
        let last = weekOf((history + plan).map(\.date).max() ?? r.start)
        while week <= last {
            defer { week = shift(week, weeks: 1) }
            guard let f = PainReturnRule.ceilingFraction(step: r.step(atWeek: week, timeZone: tz, limits: recoveryLimits),
                                                         daysOff: r.daysOff, limits: recoveryLimits) else { continue }
            var ceiling = level * f
            // A restarted week (SPEC 3.5 rule 7, #93): never below the week actually run.
            if let floor = r.restartFloor(forWeek: week), floor.isFinite { ceiling = max(ceiling, floor) }
            if startDay > week {
                let left = Double(max(0, 7 - days(from: week, to: startDay))) / 7
                let done = history.filter { $0.date < startDay && weekOf($0.date) == week }
                    .reduce(0) { $0 + GuardrailRepair.volume($1, measure) }
                ceiling = done + ceiling * left
            }
            out.append(VolumeHold(interval: DateInterval(start: week, end: shift(week, weeks: 1)), level: ceiling))
        }
        return out
    }

    /// Keeps the return's guards on the plan (SPEC 3.5 rule 7): no quality
    /// sessions until the return ends; the rest day after a recurrence; and
    /// in week 1, easy runs on alternate days with the long run capped at
    /// `week1Fraction` of the pre-stop long run (an easy run at the floor
    /// when that is under it, #101). It never adds load to the plan as
    /// handed in. The weekly ceilings run with the volume holds (`returnHolds`).
    mutating func enforceReturn(asOf: Date) {
        guard let r = state.painRecovery.painReturn else { return }
        let triggers = [stepTrigger(r, at: asOf)]
        let ended = day(r.start)
        for i in plan.indices where plan[i].kind.isQuality {
            let w = plan[i]
            plan[i] = w.swappedToEasyKeepingTarget(reason: "the return after the pain stop that ended on \(ended) (SPEC 3.5 rule 7).")
            changes.append(PlanChange(
                kind: .qualitySwappedToEasy, workoutIDs: [w.id], triggers: triggers, rule: Self.stopRule,
                explanation: "The \(describe(w.kind)) on \(day(w.date)) becomes an easy run of the same length: during the return after the pain stop, quality sessions come back only after a full week at plan volume with no symptoms (distance before speed). (Heuristic, SPEC 3.5 rule 7, [18].)"))
        }
        func rest(_ i: Int, _ why: String) {
            let w = plan[i]
            plan[i] = PlannedWorkout(id: w.id, date: w.date, kind: .rest, durationSeconds: 0)
            changes.append(PlanChange(kind: .sessionRested, workoutIDs: [w.id], triggers: triggers, rule: Self.stopRule,
                                      explanation: "The \(describe(w.kind)) on \(day(w.date)) becomes a rest day: \(why) (Heuristic, SPEC 3.5 rule 7.)"))
        }
        func isRun(_ w: PlannedWorkout) -> Bool { w.kind != .rest && w.kind != .race }
        if let rd = r.restDay {
            for i in plan.indices where isRun(plan[i]) && calendar.startOfDay(for: plan[i].date) == rd {
                rest(i, "the day after symptoms came back on a run is rest during the return.")
            }
        }
        let startDay = calendar.startOfDay(for: r.start)
        // A restart sets the weekly ceilings back, not week 1's guards: its step-1 week
        // is left out (they come back only through the recurrence rule, #93).
        func inWeek1(_ d: Date) -> Bool {
            d >= startDay && weekOf(d) != r.restartWeek
                && r.step(atWeek: weekOf(d), timeZone: tz, limits: recoveryLimits) <= 1
        }
        // Week 1's long run: at most `week1Fraction` of the pre-stop long run,
        // even after a short stop, where rule 4 itself has no ramp. The run on
        // a long-run day that the engine or a regrowth trial made easy is
        // held to it too, so the cap can't be dodged by the swap. A cap that
        // leaves less than the easy-run floor makes the day an easy run at
        // the floor, or a rest day (`applyLongRunFloor`, #101).
        let measure = context.guardrails.measure
        if let pre = r.preStopLongRun, pre > 0, pre.isFinite {
            let cap = pre * recoveryLimits.week1Fraction
            let fraction = PlanFormatting.percent(recoveryLimits.week1Fraction)
            let test = state.painRecovery.test?.workoutID
            for i in plan.indices where plan[i].id != test && isLongRunDay(plan[i]) && plan[i].date >= asOf && inWeek1(plan[i].date) {
                let w = plan[i]
                guard let v = w.volume(measure), v > cap * (1 + 1e-9), w.durationSeconds.isFinite, w.durationSeconds > 0 else { continue }
                let seconds = (w.durationSeconds * cap / v / 60).rounded(.down) * 60
                let cited = triggers + [TriggerMetric(metric: .longRunDuration, value: v, expectedHigh: cap,
                                                      unit: measure == .time ? .seconds : .meters, sourceID: w.id,
                                                      detail: "the long run on \(day(w.date)) against \(fraction) of the pre-stop long run")]
                if let floor = runFloorSeconds, seconds < floor {
                    applyLongRunFloor(at: i, cap: cap, capped: seconds, triggers: cited,
                                      reason: "in week 1 of the return the long run is capped at \(fraction) of your long run before the pain stop",
                                      source: "SPEC 3.5 rules 4, 5 and 7")
                    continue
                }
                guard seconds < w.durationSeconds, seconds > 0 else { continue }
                plan[i] = w.resized(toSeconds: seconds)
                let what = w.kind == .long ? "The long run" : "The \(describe(w.kind)) in place of the long run"
                changes.append(PlanChange(
                    kind: .sessionShortened, workoutIDs: [w.id], triggers: cited, rule: Self.stopRule,
                    explanation: "\(what) on \(day(w.date)) is shortened to \(AdaptationFormatting.minutes(seconds)): in week 1 of the return it is capped at \(fraction) of your long run before the pain stop. (Heuristic, SPEC 3.5 rules 4 and 7.)"))
            }
        }
        // Week 1's runs on alternate days [18]: the long-run day keeps its day
        // first, then the rest in date order; a run on or next to a kept run's
        // day becomes a rest day.
        var kept = Set(history.filter { isRun($0) && ($0.volume(.time) ?? 1) > 0 && $0.date >= addDays(-1, to: startDay) }
            .map { calendar.startOfDay(for: $0.date) })
        let candidates = plan.indices.filter { isRun(plan[$0]) && plan[$0].date >= asOf && inWeek1(plan[$0].date) }
            .sorted { (isLongRunDay(plan[$0]) ? 0 : 1, plan[$0].date) < (isLongRunDay(plan[$1]) ? 0 : 1, plan[$1].date) }
        for i in candidates {
            let d = calendar.startOfDay(for: plan[i].date)
            if kept.contains(d) || kept.contains(addDays(-1, to: d)) || kept.contains(addDays(1, to: d)) {
                rest(i, "in week 1 of the return, easy runs are on alternate days.")
            } else {
                kept.insert(d)
            }
        }
    }

    // MARK: Every event

    /// Rule 7's day-by-day part, on every event before the stop is enforced:
    /// pain above usual for about 7 days, staying stopped, the test run, the
    /// return's end, the flag's silence timers, and unfreezing usual pain.
    /// Guardrail repair that keeps an offered test run (SPEC 3.5 rule 7): the
    /// test is the only way out of a stop, so when repair would drop or
    /// shorten it, the other easy and long runs of its week are dropped
    /// instead, latest first, and repair runs again. Heuristic: those runs
    /// are optional while the stop stands, and dropping them only lowers load.
    ///
    /// Rule 7 fixes the test run's size, so it is kept whole or not at all:
    /// when even dropping every such run leaves repair shortening or dropping
    /// it (unplanned runs already filled the week), the test run alone is
    /// dropped. The plan is then rebuilt from what it was before any room
    /// was made, minus the test run, and repaired as usual, so no run is lost
    /// for a test run that isn't kept, and no room change is posted. A new
    /// test run is offered once the week allows. A shortened test run would
    /// no longer match `PainTestRun.seconds` (#139).
    mutating func repairKeepingTestRun(asOf: Date, regrowth: GuardrailRegrowth = .none) -> GuardrailRepair.Result {
        testRunDrop = nil
        var result = GuardrailRepair.repair(plan: plan, history: history, asOf: asOf,
                                            freezes: state.freezeIntervals(at: asOf), context: context, regrowth: regrowth)
        guard let t = state.painRecovery.test, t.ranAt == nil,
              let test = plan.first(where: { $0.id == t.workoutID }) else { return result }
        let week = weekOf(test.date)
        let run = Set(history.map(\.id))
        var made: [String] = []
        let before = plan, first = result
        func whole(_ r: GuardrailRepair.Result) -> Bool {
            r.plan.contains { $0.id == t.workoutID && $0.durationSeconds >= test.durationSeconds - 1e-6 }
        }
        while !whole(result) {
            guard let i = plan.indices.filter({
                let w = plan[$0]
                return w.id != t.workoutID && weekOf(w.date) == week && w.date > asOf && !run.contains(w.id)
                    && (w.kind == .easy || w.kind == .recovery || w.kind == .long)
            }).max(by: { plan[$0].date < plan[$1].date }) else { break }
            made.append(plan[i].id)
            plan.remove(at: i)
            result = GuardrailRepair.repair(plan: plan, history: history, asOf: asOf,
                                            freezes: state.freezeIntervals(at: asOf), context: context, regrowth: regrowth)
        }
        if !whole(result) {
            // The best repair could do with every room made: shortened, or dropped.
            let short = result.plan.first { $0.id == t.workoutID }?.durationSeconds
            let cited = (result.changes + first.changes).filter { $0.workoutIDs.contains(t.workoutID) }.flatMap(\.triggers)
            plan = before.filter { $0.id != t.workoutID }
            made = []
            result = GuardrailRepair.repair(plan: plan, history: history, asOf: asOf,
                                            freezes: state.freezeIntervals(at: asOf), context: context, regrowth: regrowth)
            let size = AdaptationFormatting.minutes(test.durationSeconds)
            let would = short.map { "would shorten it to \(AdaptationFormatting.minutes($0))" } ?? "leave no room for it"
            let triggers = cited.isEmpty ? (state.painStop.map { stopTriggers($0) } ?? []) : cited
            let drop = PlanChange(
                kind: .sessionDropped, workoutIDs: [t.workoutID], triggers: triggers, rule: Self.stopRule,
                explanation: "The test run on \(day(test.date)) is dropped: with the runs of its week, the load guardrails \(would), and rule 7 sets it at \(size). A new test run is offered once the week allows. (Heuristic, SPEC 3.5 rule 7.)")
            result.changes.append(drop)
            testRunDrop = (drop, week)
        }
        if !made.isEmpty, let stop = state.painStop {
            result.changes.insert(PlanChange(
                kind: .painTestRunRoom, workoutIDs: made, triggers: stopTriggers(stop), rule: Self.stopRule,
                explanation: "Dropped \(made.count == 1 ? "a run" : "\(made.count) runs") in the week of \(day(week)) to make room for the test run within the load guardrails: while the pain stop stands, the test run comes first. (Heuristic, SPEC 3.5 rule 7.)"),
                at: 0)
        }
        return result
    }

    mutating func rule7Day(asOf: Date) {
        adoptStoredStop()
        let u = usualPain()
        if let lp = lastingPain(asOf: asOf), !(state.painRecovery.flag?.reasons.contains(.lastingAboveUsual) ?? false) {
            applyTriggers([.lastingAboveUsual], report: PainReport(date: lp.latest, timing: .nextMorning, hasPain: true), usual: u)
            raiseFlag(.lastingAboveUsual, at: lp.latest)
        }
        if let stop = state.painStop, !state.painRecovery.flaggedThisStop,
           days(from: stop.since, to: asOf) >= recoveryLimits.stuckDays,
           let m = state.painReports.filter({ $0.isValid && $0.timing == .nextMorning && $0.date >= stop.since && $0.date <= asOf })
               .max(by: { $0.date < $1.date }) {
            let walking = (m.validWalkingScore ?? -1) >= recoveryLimits.walkingStuck
            let newPain = !context.tracksPain && u == 0 && m.isAbove(usual: 0)
            if walking || newPain { raiseFlag(.staysStopped, at: asOf) }
        }
        manageTestRun(asOf: asOf, usual: u)
        judgeReturnWeeks(asOf: asOf)
        if var r = state.painRecovery.painReturn {
            if let rd = r.restDay, addDays(1, to: rd) <= asOf { r.restDay = nil; state.painRecovery.painReturn = r }
            let full = r.planVolumeWeek(timeZone: tz, limits: recoveryLimits)
            if asOf >= shift(full, weeks: 1) { judgeFullWeek(r, week: full, at: asOf, usual: u) }
        }
        if let f = state.painRecovery.flag {
            let last = f.lastReport ?? f.raisedAt
            let silent = days(from: last, to: asOf)
            if silent >= recoveryLimits.flagCloseDays {
                endFlag(at: min(asOf, addDays(recoveryLimits.flagCloseDays, to: last)), how: .closedUnresolved)
            } else if silent >= recoveryLimits.flagAskDays, f.askedAt == nil {
                state.painRecovery.flag?.askedAt = asOf
                painNotes.askForReport = true
            }
        }
        if !painCourseActive { state.painRecovery.frozenUsual = nil }
    }

    /// Offers the test run once the 2 mornings and walking pain allow it,
    /// keeps it while they still hold, and withdraws it (or offers it again
    /// after a missed one) otherwise.
    mutating func manageTestRun(asOf: Date, usual u: Int) {
        guard let stop = state.painStop else { state.painRecovery.test = nil; return }
        let rec = state.painRecovery
        let ready = rec.cannotEnd ? nil
            : PainStopEndRule.readySince(reports: state.painReports.filter { $0.date <= asOf }, from: rec.countFrom ?? stop.since,
                                         usual: u, timeZone: tz, limits: recoveryLimits)
        if let t = rec.test {
            guard t.ranAt == nil else { return }   // run: its reports decide
            let i = plan.firstIndex { $0.id == t.workoutID }
            if ready != nil, i != nil { return }
            state.painRecovery.test = nil
            if let i, ready == nil {
                let w = plan[i]
                plan[i] = PlannedWorkout(id: w.id, date: w.date, kind: .rest, durationSeconds: 0)
                changes.append(PlanChange(
                    kind: .painTestRunWithdrawn, workoutIDs: [w.id], triggers: stopTriggers(stop), rule: Self.stopRule,
                    explanation: "The test run on \(day(w.date)) is withdrawn and becomes a rest day: since it was planned, pain went above your usual \(u)/10, so the count of 2 mornings at or below your usual pain starts again. (Heuristic, SPEC 3.5 rule 7.)"))
            }
        }
        guard let ready else { return }
        offerTest(from: max(asOf, ready), stop: stop, usual: u)
    }

    /// Makes the first session from `from` to the end of the next day (no
    /// race on or next to it) the test run, or adds one the next day at the
    /// time of the runner's latest run.
    mutating func offerTest(from: Date, stop: PainStop, usual u: Int) {
        let seconds = PainStopEndRule.testSeconds(usualEasySeconds: usualEasySeconds(before: stop.since), limits: recoveryLimits)
        let horizon = addDays(2, to: calendar.startOfDay(for: from))
        let slot = plan.indices.filter { plan[$0].date >= from && plan[$0].date < horizon && plan[$0].kind != .race && !nearRace(plan[$0].date) }
            .min { plan[$0].date < plan[$1].date }
        let base: PlannedWorkout
        if let i = slot {
            base = plan[i]
        } else {
            var day1 = addDays(1, to: calendar.startOfDay(for: from))
            var tries = 0
            while nearRace(day1), tries < 7 { day1 = addDays(1, to: day1); tries += 1 }
            let clock = history.map(\.date).max().map { $0.timeIntervalSince(calendar.startOfDay(for: $0)) } ?? 12 * 3600
            let id = "pain-test-\(Int(day1.timeIntervalSince1970))"
            base = PlannedWorkout(id: id, date: day1.addingTimeInterval(clock), kind: .rest, durationSeconds: 0)
            plan.append(base)
            plan.sort { $0.date < $1.date }
        }
        let test = testRun(from: base, seconds: seconds)
        if let i = plan.firstIndex(where: { $0.id == base.id }) { plan[i] = test }
        state.painRecovery.test = PainTestRun(workoutID: test.id, offeredAt: from, seconds: seconds)
        changes.append(PlanChange(
            kind: .painTestRun, workoutIDs: [test.id],
            triggers: [TriggerMetric(metric: .painScore, value: Double(u), expectedHigh: Double(u), unit: .painScore,
                                     detail: "\(recoveryLimits.morningsToEnd) mornings in a row at or below your usual \(u)/10, with walking pain at \(recoveryLimits.walkingMax)/10 or less")],
            rule: Self.stopRule,
            explanation: "Your last \(recoveryLimits.morningsToEnd) mornings were at or below your usual pain, with walking pain at \(recoveryLimits.walkingMax)/10 or less, so \(day(test.date)) is a test run: \(AdaptationFormatting.minutes(seconds)) easy and flat. It passes if pain during it stays at most \(min(u + recoveryLimits.testAllowance, recoveryLimits.testMaxScore))/10\(state.painRecovery.stopFromMovement ? " (no more than your usual \(u)/10, since the stop came from a change in how you moved)" : ""), you move normally, and the next morning is at or below your usual pain; the pain stop then ends. (Heuristic, SPEC 3.5 rule 7.)"))
    }

    /// Posts the test run's offer and drop once per week that can't hold it
    /// (#144): while the week stays full, every event offers the test run
    /// again (`manageTestRun`) and repair drops it again, so the pair is
    /// skipped when the previous event posted it for the same week, whichever
    /// day or workout the re-offer lands on that week. Only the
    /// change records go; the plan, the state of the offer and the timing of
    /// the way out are as without this. The next week, or an event that
    /// drops no test run, posts as usual.
    mutating func dedupeTestRunDrop() {
        guard let (drop, week) = testRunDrop else { state.painRecovery.reportedTestRunDropWeek = nil; return }
        if state.painRecovery.reportedTestRunDropWeek == week, let id = drop.workoutIDs.first {
            changes.removeAll { $0 == drop || ($0.kind == .painTestRun && $0.workoutIDs == [id]) }
        }
        state.painRecovery.reportedTestRunDropWeek = week
    }

    /// `base` as the test run: an easy, flat run of `seconds` under the easy
    /// heart-rate cap, keeping its id and date. Its distance is scaled from
    /// the session it replaces, or from the runner's usual easy speed.
    func testRun(from base: PlannedWorkout, seconds: Double) -> PlannedWorkout {
        var distance: Double?
        if base.kind != .rest, let d = base.distanceMeters, d.isFinite, base.durationSeconds > 0, base.durationSeconds.isFinite {
            distance = d * seconds / base.durationSeconds
        } else if let speed = usualEasySpeed() {
            distance = speed * seconds
        }
        let target = WorkoutTarget(heartRate: HeartRateTarget(zones: HRZone.z1...HRZone.z2, floorBPM: nil,
                                                              ceilingBPM: context.zones.easyCeiling),
                                   pace: nil, primary: .heartRate)
        let p = WorkoutPrescription(
            purpose: "Test run after a pain stop: easy and flat, \(AdaptationFormatting.minutes(seconds)). Stop if pain rises above the limit or you move differently (SPEC 3.5 rule 7).",
            phase: .base, segments: [WorkoutSegment(role: .main, intensity: .easy, durationSeconds: seconds, target: target)],
            rules: [.easyByHeartRate])
        return PlannedWorkout(id: base.id, date: base.date, kind: .easy, durationSeconds: seconds, distanceMeters: distance,
                              prescription: p)
    }

    /// The median length of the runner's last few easy runs before `date`
    /// (at most 10), or nil with none.
    func usualEasySeconds(before date: Date) -> Double? {
        let easy = history.filter { $0.kind == .easy && $0.date < date && $0.durationSeconds.isFinite && $0.durationSeconds > 0 }
            .sorted { $0.date < $1.date }.suffix(10).map(\.durationSeconds).sorted()
        guard !easy.isEmpty else { return nil }
        let m = easy.count / 2
        return easy.count % 2 == 1 ? easy[m] : (easy[m - 1] + easy[m]) / 2
    }

    /// The median speed of the runner's easy runs with a distance, in m/s, or nil.
    func usualEasySpeed() -> Double? {
        let speeds = history.filter { $0.kind == .easy }.compactMap { w -> Double? in
            guard let d = w.distanceMeters, d.isFinite, d > 0, w.durationSeconds.isFinite, w.durationSeconds > 0 else { return nil }
            return d / w.durationSeconds
        }.sorted()
        guard !speeds.isEmpty else { return nil }
        return speeds[speeds.count / 2]
    }

    // MARK: The restart after a week run short (SPEC 3.5 rule 7, #93)

    /// True when the return restarts after a week run short: only after a
    /// stop of more than `rampDaysOff.upperBound` (14) days off, with a known
    /// level. After a shorter stop each week is in rule 6's regrowth, which
    /// has its own restart (`growthWeeks`).
    func restartApplies(_ r: PainReturn) -> Bool {
        guard let off = r.daysOff, off > recoveryLimits.rampDaysOff.upperBound,
              let level = r.level, level > 0, level.isFinite else { return false }
        return true
    }

    /// The first full week of the return: the week it starts in when it
    /// starts on that week's first day, else the week after.
    func firstFullWeek(_ r: PainReturn) -> Date {
        let week = weekOf(r.start)
        return calendar.startOfDay(for: r.start) == week ? week : shift(week, weeks: 1)
    }

    /// What return week `week` was planned to hold, outside races: the volume
    /// the engine returned for it at its first event (`PlanSnapshot.planned`);
    /// a week run before the plan existed counts as planned at its step's
    /// ceiling (the pre-stop plan's volume at full plan volume), as after a
    /// longer break (rule 4). Nil when neither is known.
    func plannedReturnWeek(_ r: PainReturn, week: Date) -> Double? {
        if let p = plannedVolume(week), p.isFinite { return p }
        guard let level = r.level else { return nil }
        let step = r.step(atWeek: week, timeZone: tz, limits: recoveryLimits)
        guard let f = PainReturnRule.ceilingFraction(step: step, daysOff: r.daysOff, limits: recoveryLimits) else {
            return r.reference(forWeek: week)
        }
        return max(level * f, r.restartFloor(forWeek: week) ?? 0)
    }

    /// Reads each finished return week once (SPEC 3.5 rule 7, 0.8, #93): a
    /// week run under 1 / (1 + 20%) of what it was planned to hold
    /// (`GuardrailChecker.isShortReturnWeek`, the reading of rule 4) sets the
    /// next week back to step 1, its ceiling the step's share of the pre-stop
    /// level or the volume of the short week if that is higher, so it is
    /// never below the week run. The week's own time is read, never its time
    /// before an easy-run cap (#54).
    ///
    /// A week that is also a recurrence week (symptoms came back in it, which
    /// set the step back one) takes the lower of the step back and the
    /// restart: the restart only replaces the step back when its ceiling is
    /// lower. A second failure at the same step still reopens the stop
    /// (`recurrence`). The restart sets the weekly ceilings back only: week 1's
    /// alternate days and long-run cap return only through the recurrence
    /// rule (`enforceReturn`). Heuristic, owner-approved Nov 24.
    mutating func judgeReturnWeeks(asOf: Date) {
        guard var r = state.painRecovery.painReturn, restartApplies(r), let level = r.level else { return }
        let current = weekOf(asOf)
        var week = r.judgedThrough.map { shift($0, weeks: 1) } ?? firstFullWeek(r)
        guard week < current else { return }
        let measure = context.guardrails.measure
        let limits = context.guardrails
        let rise = limits.regrowthMaxWeeklyRise.isFinite ? max(0, limits.regrowthMaxWeeklyRise) : 0
        let first = PainReturnRule.ceilingFraction(step: 1, daysOff: r.daysOff, limits: recoveryLimits) ?? 1
        var posted: [PlanChange] = []
        while week < current {
            let judged = week
            week = shift(week, weeks: 1)
            let next = week
            defer { r.judgedThrough = judged }
            guard let planned = plannedReturnWeek(r, week: judged) else { continue }
            let ran = runVolume(inWeek: judged, history)
            guard ran.isFinite, GuardrailChecker.isShortReturnWeek(ran: ran, planned: planned, limits: limits) else { continue }
            let restart = max(level * first, ran)
            // The step back a recurrence in this week set, or the step on: whichever the state holds for the next week.
            if let f = PainReturnRule.ceilingFraction(step: r.step(atWeek: next, timeZone: tz, limits: recoveryLimits),
                                                      daysOff: r.daysOff, limits: recoveryLimits) {
                let back = level * f
                if restart >= back - 1e-9 * max(1, back) { continue }
            }
            r.step = 1
            r.stepWeek = next
            r.restartWeek = next
            r.restartFloor = ran
            let units = context.units
            let fmt = { (v: Double) in PlanFormatting.volume(v, measure, units: units) }
            let raised = ran > level * first
            posted.append(PlanChange(
                kind: .painReturnStep, workoutIDs: [],
                triggers: [stepTrigger(r, at: next),
                           TriggerMetric(metric: .weeklyVolume, value: ran, expectedLow: planned / (1 + rise),
                                         unit: measure == .distance ? .meters : .seconds,
                                         detail: "run in the week of \(day(judged)) of the \(fmt(planned)) it was planned to hold, under \(PlanFormatting.percent(1 / (1 + rise)))")],
                rule: Self.stopRule,
                explanation: "In the week of \(day(judged)) you ran \(fmt(ran)) of the \(fmt(planned)) the return planned, under about \(PlanFormatting.percent(1 / (1 + rise))) of it, so the return restarts: the week of \(day(next)) is step 1 again, at most \(fmt(restart)) (\(PlanFormatting.percent(first)) of your level before the stop\(raised ? ", or the week you ran, which is more" : "")), then \(PlanFormatting.percent(PainReturnRule.ceilingFraction(step: 2, daysOff: r.daysOff, limits: recoveryLimits) ?? 1)) and the full plan follow. Week 1's alternate days and long-run cap come back only if symptoms do. This is a training adjustment, not a diagnosis. (Heuristic, SPEC 3.5 rule 7, owner decision Nov 24, #93.)"))
        }
        state.painRecovery.painReturn = r
        changes += posted
    }

    /// The return is over: a full week at plan volume with no symptoms.
    /// Volume of the runs in `week` (guardrail measure, races and rest left out).
    func runVolume(inWeek week: Date, _ sessions: [PlannedWorkout]) -> Double {
        let measure = context.guardrails.measure
        return sessions.filter { weekOf($0.date) == week && $0.kind != .race && $0.kind != .rest }
            .map { GuardrailRepair.volume($0, measure) }.filter(\.isFinite).reduce(0, +)
    }

    /// The week at full plan volume has passed: the return ends only when it
    /// was run at plan volume with no symptoms (SPEC 3.5 rule 7: "1 full week
    /// at plan volume with no symptoms"). Plan volume is the fixed reference
    /// recorded before the stop (`PainReturn.reference(forWeek:)`), never the
    /// week as the guardrails, holds or freezes have since cut it, and the
    /// week counts when what was run reaches `fullWeekShare` of it. No
    /// symptoms: no report or check-in above usual, no movement change, no
    /// red flag. With no reference, or nothing run, the week never counts.
    /// Otherwise the week repeats from the current week, with quality still
    /// out; a return the guardrails keep below the reference keeps repeating,
    /// the conservative result. Heuristic.
    mutating func judgeFullWeek(_ r: PainReturn, week: Date, at asOf: Date, usual u: Int) {
        let end = shift(week, weeks: 1)
        let ran = runVolume(inWeek: week, history)
        let reference = r.reference(forWeek: week)
        let planned = reference ?? 0
        let share = recoveryLimits.fullWeekShare.isFinite ? min(1, max(0, recoveryLimits.fullWeekShare)) : 1
        let short = reference == nil || ran <= 0 || ran < share * planned - 1e-6
        let reports = state.painReports.filter { $0.isValid && $0.date >= week && $0.date < end }
        let symptom = reports.first { $0.isAbove(usual: u) || $0.changedMovement || !$0.redFlags.isEmpty }?.date
            ?? state.painCheckIns.first { $0.date >= week && $0.date < end && PainCheckIn.validScores.contains($0.score) && $0.score > u }?.date
        guard short || symptom != nil else { return finishReturn(r, at: asOf, lastWeek: week) }
        var next = r
        next.step = PainReturnRule.planVolumeStep(recoveryLimits)
        next.stepWeek = max(end, weekOf(asOf))
        next.restartWeek = nil
        next.restartFloor = nil
        state.painRecovery.painReturn = next
        let measure = context.guardrails.measure
        let why = symptom.map { "pain went above your usual \(u)/10 or your movement changed on \(day($0))" }
            ?? (reference == nil ? "your volume before the stop isn't known, so no week can count as at plan volume"
                : "you ran \(PlanFormatting.volume(ran, measure, units: context.units)) of the \(PlanFormatting.volume(planned, measure, units: context.units)) planned before the stop")
        changes.append(PlanChange(
            kind: .painReturnRepeated, workoutIDs: [],
            triggers: [stepTrigger(next, at: end),
                       TriggerMetric(metric: .weeklyVolume, value: ran, expectedLow: share * planned, unit: measure == .distance ? .meters : .seconds,
                                     detail: "run in the week of \(day(week)) at full plan volume, against \(PlanFormatting.percent(share)) of the \(PlanFormatting.volume(planned, measure, units: context.units)) planned before the stop")],
            rule: Self.stopRule,
            explanation: "Your return after the pain stop isn't complete yet: in the week of \(day(week)) \(why). Quality sessions come back only after a full week at plan volume with no symptoms, so the week at plan volume repeats from \(day(next.stepWeek)). (Heuristic, SPEC 3.5 rule 7.)"))
    }

    mutating func finishReturn(_ r: PainReturn, at asOf: Date, lastWeek: Date) {
        state.painRecovery.painReturn = nil
        // After a stop of more than 14 days, the weeks from the stop's week
        // through the return's last week count at the pre-stop level in the
        // rolling 4-week check while they are among the 4 earlier weeks; the
        // snapshot keeps them from here on (3.5 rule 7, #93).
        if restartApplies(r), let level = r.level {
            var cut = Dictionary(state.planSnapshot.cut.map { ($0.week, $0.volume) }, uniquingKeysWith: { a, _ in a })
            var w = min(r.planWeeks.map(\.week).min() ?? weekOf(r.start), weekOf(r.start))
            while w <= lastWeek {
                cut[w] = level
                w = shift(w, weeks: 1)
            }
            state.planSnapshot.cut = cut.keys.sorted().map { PlanWeekVolume(week: $0, volume: cut[$0]!) }
        }
        changes.append(PlanChange(
            kind: .painReturnStep, workoutIDs: [], triggers: [stepTrigger(r, at: asOf)], rule: Self.stopRule,
            explanation: "Your return after the pain stop is complete: a full week at plan volume with no symptoms. Quality sessions can come back in the plan from now. (Heuristic, SPEC 3.5 rule 7.)"))
    }

    func painStatus(asOf: Date) -> PainCourseStatus {
        let rec = state.painRecovery
        let test = rec.test.flatMap { t in plan.first { $0.id == t.workoutID } ?? t.activityID.flatMap { id in history.first { $0.id == id } } }
        return PainCourseStatus(
            usual: usualPain(), stopped: state.painStop != nil, stopCannotEnd: state.painStop != nil && rec.cannotEnd,
            testRun: test,
            returnStep: rec.painReturn.map { $0.step(atWeek: weekOf(asOf), timeZone: tz, limits: recoveryLimits) },
            clinicianFlag: rec.flag, askForReport: painNotes.askForReport, flagClosedUnresolved: painNotes.flagClosed,
            askMorningQuestions: state.painStop != nil || rec.painReturn != nil, returnStarted: painNotes.returnStarted)
    }
}
