import Foundation

/// Keeps an adapted plan inside the load guardrails (SPEC.md 3.5, F4 "volume
/// and difficulty change only through this engine, inside the guardrails", F9).
///
/// After the engine changes the plan, or the runner's actual weeks differ from
/// the planned ones (a missed run lowers a week, so next week's planned rise
/// may now exceed 10%), the checker is run over history plus plan and each
/// volume violation is fixed by **shortening sessions still to come**, earliest
/// week first, until the plan passes or nothing more can be cut:
/// - Weekly rise, rolling 4 weeks, freeze: the week is cut by measured minus
///   allowed. Easy and recovery runs are cut first, in proportion, down to
///   `AdaptationLimits.minimumTrimmedSeconds`; then the long run to the same
///   floor; then easy and recovery runs are dropped, shortest first. When
///   nothing is left to cut but a long run at its floor and the week is
///   still over (the runs already done fill it, #146), that long run is
///   dropped (`dropLongRunAtFloor`), never cut below the floor.
/// - Long-run share: the long run is cut until it fits (in time, as the
///   checker reads the share, 3.5 rule 5). When no cut can fit (the long
///   run is the only run left in its week, or at its floor), it becomes an
///   easy run instead (3.5 rules 5 and 6, #64), no longer than the floor
///   or what the share leaves for the day, whichever is more (#122). Time
///   that shortening frees goes back to the week's runs this repair cut,
///   never past their length before and within the guardrails (`giveBack`).
/// - Single-run spike (3.5 rule 1): the planned run named by the violation
///   is cut to the allowed length (rounded down to a whole minute), never
///   below `AdaptationLimits.minimumTrimmedSeconds`. Only easy, recovery and
///   long runs are cut; a spiking quality session to come first becomes an
///   easy run of the same length (3.5 rule 6, #64), and a race is only ever
///   an information flag. Completed runs are never touched.
/// - Recovery cadence: the lightest week of the too-long run of build weeks,
///   relative to the week before it (usually a planned recovery week that an
///   earlier cut brought too close to that week), is cut to
///   `recoveryWeekMaxRatio` of the week before. When nothing is left to cut
///   there but a long run at its floor (#154), that long run is dropped as
///   for the weekly limits, but only when dropping the week's long runs at
///   the floor can make it a recovery week; otherwise the violation is left
///   to the report.
/// - Weekly rise, rolling 4 weeks, freeze and recovery cadence, when the week
///   can't meet the limit with its quality sessions whole (3.5 rule 6, #64):
///   every quality session to come in that week first becomes an easy run of
///   the same length (`swappedToEasyKeepingTarget`), and the week is then cut
///   as above with those runs trimmed and dropped as easy runs. Volume comes
///   back before intensity, and the swap never adds load.
/// - Quality sessions (3.5 rule 4's return ramp, or the weekly limit): the
///   latest quality sessions still to come in the week become easy runs of
///   the same length until the count fits (#91's ramp limits, #64).
/// Races are never cut or changed, and nothing is ever lengthened, so a
/// repair can only lower load. Durations are rounded down to whole minutes.
/// A weekly rise over a reference of 0 that rests on a week with nothing
/// of known time (`GuardrailViolation.rebuildOn`, #40) is left to the report:
/// it allows nothing, and cutting the plan to its floors would not fix it. The
/// plan is left as it is, and `AdaptationOutcome.rebuildOn` gives the date to
/// build it again.
///
/// Repair only cuts. Growing a cut week back toward the plan the app handed
/// in (3.5 rule 6) is the engine's regrowth (`PlanRegrowth.swift`), and the
/// weeks of a regrowth reach the checker through `regrowth`.
enum GuardrailRepair {
    struct Result {
        var plan: [PlannedWorkout]
        var changes: [PlanChange]
        var report: GuardrailReport
    }

    static let fixable: Set<GuardrailRule> = [.weeklyIncrease, .fourWeekIncrease, .volumeFreeze, .longRunShare, .recoveryWeek,
                                              .singleRunSpike, .qualitySessions, .easyRunLength]

    static func repair(plan: [PlannedWorkout], history: [PlannedWorkout], asOf: Date, freezes: [DateInterval],
                       context: AdaptationContext, regrowth: GuardrailRegrowth = .none) -> Result {
        let input = plan
        var plan = plan
        var changes: [PlanChange] = []
        var stuck: Set<String> = []
        let limits = context.guardrails
        var report = GuardrailChecker.check(history: history, planned: plan, timeZone: context.timeZone,
                                            limits: limits, freezes: freezes, units: context.units, regrowth: regrowth)
        for _ in 0..<(16 + 4 * plan.count) {
            let next = report.violations
                .filter { fixable.contains($0.rule) && $0.rebuildOn == nil && !stuck.contains(key($0)) }
                .min { $0.weekStart != $1.weekStart ? $0.weekStart < $1.weekStart : order($0.rule) < order($1.rule) }
            guard let v = next else { break }
            if var fix = fixOne(v, plan: plan, history: history, asOf: asOf, context: context, regrowth: regrowth) {
                // A long-to-easy swap that shortened the long-run day gives
                // the time it freed back to the week's runs this repair cut
                // (#122), within the guardrails.
                if let c = fix.changes.last, c.kind == .longRunSwappedToEasy, let id = c.workoutIDs.first,
                   let was = plan.first(where: { $0.id == id }), let now = fix.plan.first(where: { $0.id == id }),
                   now.durationSeconds < was.durationSeconds - 1e-6 {
                    let back = giveBack(freedBy: was, swapped: now, week: v.weekStart, plan: fix.plan, input: input, history: history,
                                        asOf: asOf, freezes: freezes, context: context, regrowth: regrowth)
                    if back.seconds > 0 {
                        fix.plan = back.plan
                        let text = PlanFormatting.volume(back.seconds, .time)
                        let ids = back.plan.filter { b in plan.contains { $0.id == b.id && $0.durationSeconds < b.durationSeconds - 1e-6 } }.map(\.id)
                        fix.changes[fix.changes.count - 1] = PlanChange(
                            kind: c.kind, workoutIDs: c.workoutIDs + ids, triggers: c.triggers, rule: c.rule,
                            explanation: c.explanation + " The \(text) this frees goes back to the week's other runs that were shortened, never past their length before and within the load guardrails.")
                    }
                }
                plan = fix.plan
                changes += fix.changes
                // A fix can open a way to fix what was stuck in the same week
                // (a lone long run swapped to easy can then be dropped), so
                // that week's stuck violations are tried again.
                let at = "@\(v.weekStart.timeIntervalSince1970)"
                stuck = stuck.filter { !$0.contains(at) }
            } else {
                stuck.insert(key(v))
            }
            report = GuardrailChecker.check(history: history, planned: plan, timeZone: context.timeZone,
                                            limits: limits, freezes: freezes, units: context.units, regrowth: regrowth)
        }
        return Result(plan: plan, changes: oneChangePerDroppedRun(changes), report: report)
    }

    /// One change per run (#146 review): a run this repair shortened and
    /// then dropped is named only by the drop, which is what happened to it.
    /// It is taken out of the earlier `sessionShortened` changes; one left
    /// naming no run is removed, and one still naming others keeps its
    /// reason with the count of sessions corrected. Other kinds (a quality
    /// or long-run swap, which explains why the run was then cut as an easy
    /// run) are kept as they are.
    static func oneChangePerDroppedRun(_ changes: [PlanChange]) -> [PlanChange] {
        var out: [PlanChange] = []
        for (k, c) in changes.enumerated() {
            guard c.kind == .sessionShortened else { out.append(c); continue }
            let droppedLater = Set(changes[(k + 1)...].filter { $0.kind == .sessionDropped }.flatMap(\.workoutIDs))
            let kept = c.workoutIDs.filter { !droppedLater.contains($0) }
            if kept.count == c.workoutIDs.count { out.append(c); continue }
            guard !kept.isEmpty else { continue }
            func count(_ n: Int) -> String { n == 1 ? "Shortened a session " : "Shortened \(n) sessions " }
            let was = count(c.workoutIDs.count)
            let explanation = c.explanation.hasPrefix(was)
                ? count(kept.count) + String(c.explanation.dropFirst(was.count)) : c.explanation
            out.append(PlanChange(kind: c.kind, workoutIDs: kept, triggers: c.triggers, rule: c.rule, explanation: explanation))
        }
        return out
    }

    static func key(_ v: GuardrailViolation) -> String {
        "\(v.rule.rawValue)@\(v.weekStart.timeIntervalSince1970)" + (v.workoutID.map { "#\($0)" } ?? "")
    }

    /// Within a week, the recovery cadence is fixed before the weekly rise:
    /// restoring an earlier recovery week moves the 10% reference back past
    /// it, so the week after needs a smaller cut or none. A spike cut comes
    /// before the weekly cuts, since it lowers the week's volume too.
    static func order(_ r: GuardrailRule) -> Int {
        [GuardrailRule.qualitySessions, .volumeFreeze, .recoveryWeek, .singleRunSpike, .weeklyIncrease, .fourWeekIncrease,
         .longRunShare, .easyRunLength]
            .firstIndex(of: r) ?? 9
    }

    static func volume(_ w: PlannedWorkout, _ m: VolumeMeasure) -> Double { w.volume(m) ?? 0 }

    static func weekVolume(_ start: Date, _ all: [PlannedWorkout], _ ctx: AdaptationContext) -> Double? {
        var total = 0.0
        for w in all where PlanCalendar.weekStart(containing: w.date, timeZone: ctx.timeZone) == start {
            guard let v = w.volume(ctx.guardrails.measure) else { return nil }
            total += v
        }
        return total
    }

    /// One fix, or nil when this violation can't be cut further.
    static func fixOne(_ v: GuardrailViolation, plan: [PlannedWorkout], history: [PlannedWorkout], asOf: Date,
                       context ctx: AdaptationContext, regrowth: GuardrailRegrowth = .none) -> (plan: [PlannedWorkout], changes: [PlanChange])? {
        let tz = ctx.timeZone
        let measure = ctx.guardrails.measure
        let cal = PlanCalendar.calendar(timeZone: tz)
        func shift(_ d: Date, weeks: Int) -> Date { cal.date(byAdding: .day, value: 7 * weeks, to: d) ?? d }
        func upcoming(in week: Date) -> [Int] {
            plan.indices.filter {
                PlanCalendar.weekStart(containing: plan[$0].date, timeZone: tz) == week && plan[$0].date >= asOf
            }
        }
        // A recovery-cadence violation is fixed in the lightest week of the
        // streak relative to the week before it (usually the planned recovery
        // week), not necessarily the week where the count ran over.
        var week = v.weekStart
        if v.rule == .recoveryWeek {
            let streak = max(1, Int(v.measured.rounded()))
            var best: (ratio: Double, week: Date)?
            for k in 0..<streak {
                let w = shift(v.weekStart, weeks: -k)
                guard !upcoming(in: w).isEmpty, let this = weekVolume(w, history + plan, ctx),
                      let prev = weekVolume(shift(w, weeks: -1), history + plan, ctx), prev > 0 else { continue }
                let ratio = this / prev
                if best == nil || ratio < best!.ratio { best = (ratio, w) }
            }
            guard let b = best else { return nil }
            week = b.week
        }
        let inWeek = upcoming(in: week)
        guard !inWeek.isEmpty else { return nil }
        let trigger: TriggerMetric
        let amount: Double
        var longOnly = false
        var cutContext = ctx
        switch v.rule {
        case .weeklyIncrease, .fourWeekIncrease, .volumeFreeze:
            amount = v.measured - v.allowed
            trigger = TriggerMetric(metric: .weeklyVolume, value: v.measured, expectedHigh: v.allowed,
                                    unit: measure == .time ? .seconds : .meters, detail: v.explanation)
        case .longRunShare:
            // The share is of weekly time (3.5 rule 5), so it is cut in time.
            cutContext.guardrails.measure = .time
            guard let total = weekVolume(v.weekStart, history + plan, cutContext),
                  let li = inWeek.filter({ plan[$0].kind == .long }).max(by: { volume(plan[$0], .time) < volume(plan[$1], .time) })
            else { return nil }
            let s = v.allowed
            amount = (volume(plan[li], .time) - s * total) / (1 - s)
            longOnly = true
            trigger = TriggerMetric(metric: .longRunShare, value: v.measured, expectedHigh: v.allowed, unit: .fraction,
                                    detail: v.explanation)
        case .recoveryWeek:
            guard let this = weekVolume(week, history + plan, ctx),
                  let prev = weekVolume(shift(week, weeks: -1), history + plan, ctx), prev > 0 else { return nil }
            amount = this - ctx.guardrails.recoveryWeekMaxRatio * prev
            trigger = TriggerMetric(metric: .buildWeeks, value: v.measured, expectedHigh: v.allowed, unit: .weeks,
                                    detail: v.explanation)
        case .singleRunSpike:
            let t = TriggerMetric(metric: .singleRunSpike, value: v.measured, expectedHigh: v.allowed,
                                  unit: v.unit == .meters ? .meters : .seconds, sourceID: v.workoutID, detail: v.explanation)
            // In a regrowth week, a spiking quality session to come first
            // becomes an easy run of the same length, then is cut as one
            // (3.5 rules 1 and 6, #64: after a cut week, intensity goes
            // before volume). Elsewhere quality sessions are never cut.
            var base = plan
            var swap: [PlanChange] = []
            if regrowth.week(week) != nil,
               let id = v.workoutID, let i = inWeek.first(where: { plan[$0].id == id }), plan[i].kind.isQuality,
               let swapped = swapQuality(sessions: [i], plan: plan, week: week, trigger: t, context: ctx) {
                base = swapped.plan
                swap = swapped.changes.map { c in
                    PlanChange(kind: c.kind, workoutIDs: c.workoutIDs, triggers: c.triggers, rule: "SPEC 3.5 rules 1 and 6 (heuristic guardrail), F4, F9",
                               explanation: "The quality session in the week of \(PlanFormatting.day(week, timeZone: tz)) becomes an easy run of the same length, then is shortened: it is longer than the single-run spike rule allows, and volume comes back before intensity (\(v.explanation)). (Heuristic, SPEC 3.5 rules 1 and 6.)")
                }
            }
            guard let c = cutSpike(v, sessions: inWeek, plan: base, context: ctx) else { return nil }
            return (c.plan, swap + changes(c, week: week, trigger: t, rule: "SPEC 3.5 rule 1 (heuristic guardrail), F4, F9",
                                           reason: "to keep it within the single-run spike rule: \(v.explanation)", context: ctx))
        case .qualitySessions:
            return swapExcessQuality(v, sessions: inWeek, plan: plan, context: ctx)
        case .easyRunLength:
            // An easy run longer than the week's long run, or any run over the
            // run cap, is cut to the allowance (F3, #23). Quality sessions are
            // never cut.
            guard let id = v.workoutID, let i = inWeek.first(where: { plan[$0].id == id }),
                  [.easy, .recovery, .long].contains(plan[i].kind), v.allowed.isFinite, v.allowed >= 0,
                  plan[i].durationSeconds.isFinite else { return nil }
            let seconds = PlanBuilder.floorMinute(v.allowed)
            var out = plan
            let c: Cut
            if seconds >= 60 {
                guard seconds < plan[i].durationSeconds else { return nil }
                out[i] = plan[i].resized(toSeconds: seconds)
                c = Cut(plan: out, shortened: [id], dropped: [], remaining: 0)
            } else {
                out.remove(at: i)
                c = Cut(plan: out, shortened: [], dropped: [id], remaining: 0)
            }
            // No metric names an easy run against the long run, so the closest, the long-run duration, is cited.
            let t = TriggerMetric(metric: .longRunDuration, value: v.measured, expectedHigh: v.allowed, unit: .seconds,
                                  sourceID: id, detail: v.explanation)
            return (c.plan, changes(c, week: week, trigger: t, rule: "SPEC F3 and 3.5 rule 5 (heuristic guardrail), F4, F9",
                                    reason: "so no easy run is longer than the week's long run, or past the run cap: \(v.explanation)", context: ctx))
        }
        guard amount.isFinite, amount > 0 else { return nil }

        // With quality sessions whole first; when that can't reach the limit,
        // the week's quality sessions become easy runs of the same length and
        // are trimmed as easy runs (3.5 rule 6, #64).
        let whole = Self.cut(amount, sessions: inWeek, longOnly: longOnly, plan: plan, context: cutContext)
        if !longOnly, whole.map({ $0.remaining > 1e-6 }) ?? true,
           let swapped = swapQuality(sessions: inWeek, plan: plan, week: week, trigger: trigger, context: ctx),
           let c = Self.cut(amount, sessions: inWeek, longOnly: false, plan: swapped.plan, context: cutContext) {
            return (c.plan, swapped.changes + changes(c, week: week, trigger: trigger, rule: "SPEC 3.5 rules 2 and 6 (heuristic guardrail), F4, F9",
                                                      reason: "to stay inside the load guardrails: \(v.explanation)", context: ctx))
        }
        // A long run no cut can bring within the share (the week's other
        // running is too little, or the long run is at its floor) becomes an
        // easy run of the same length (3.5 rules 5 and 6, #64).
        if longOnly, whole.map({ $0.remaining > 1e-6 }) ?? true,
           let swapped = swapLongRunToEasy(v, sessions: inWeek, plan: plan, history: history, context: ctx) {
            return swapped
        }
        // Nothing left to trim or drop but a long run at its floor, and the
        // week still breaks a weekly limit or a freeze (#146), or the
        // recovery cadence (#154): the long run is dropped rather than the
        // violation left, never cut below the floor.
        guard let c = whole else {
            return dropLongRunAtFloor(v, sessions: inWeek, plan: plan, week: week, trigger: trigger, amount: amount, context: ctx)
        }
        return (c.plan, changes(c, week: week, trigger: trigger, rule: "SPEC 3.5 (heuristic guardrail), F4, F9",
                                reason: "to stay inside the load guardrails: \(v.explanation)", context: ctx))
    }

    /// Every quality session still to come at `sessions` as an easy run of the
    /// same length (3.5 rule 6: hard sessions become easy runs of the same
    /// length before runs are trimmed). Nil when there is none.
    static func swapQuality(sessions: [Int], plan: [PlannedWorkout], week: Date, trigger: TriggerMetric,
                            context ctx: AdaptationContext) -> (plan: [PlannedWorkout], changes: [PlanChange])? {
        let quality = sessions.filter { plan[$0].kind.isQuality }
        guard !quality.isEmpty else { return nil }
        var out = plan
        let weekText = PlanFormatting.day(week, timeZone: ctx.timeZone)
        for i in quality {
            out[i] = plan[i].swappedToEasyKeepingTarget(
                reason: "the week of \(weekText) can't stay inside the load guardrails with its quality sessions whole (SPEC 3.5 rule 6).")
        }
        let n = quality.count
        let change = PlanChange(
            kind: .qualitySwappedToEasy, workoutIDs: quality.map { plan[$0].id }, triggers: [trigger],
            rule: "SPEC 3.5 rule 6 (heuristic), F4, F9",
            explanation: "\(n == 1 ? "The quality session" : "The \(n) quality sessions") in the week of \(weekText) \(n == 1 ? "becomes an easy run" : "become easy runs") of the same length, then the week's runs are trimmed: it can't stay inside the load guardrails with its quality sessions whole, and volume comes back before intensity. (Heuristic, SPEC 3.5 rule 6.)")
        return (out, [change])
    }

    /// A long-run share violation that no cut of the long run can fix: the
    /// longest long run still to come in the week becomes an easy run on the
    /// same day (3.5 rules 5 and 6, #64: after a missed or cut week,
    /// intensity goes before volume, and a long run needs a week of running
    /// around it). That happens when the long run is the only run left in its
    /// week (so all of the week's running), or when it is already at its
    /// floor (`AdaptationLimits.minimumTrimmedSeconds`) or the week's other
    /// running is too little for any long run above that floor. Nil when no
    /// long run is still to come.
    ///
    /// The easy run lasts no longer than `longRunDayEasySeconds` allows
    /// (#122): the floor, or what the share leaves for the day if that is
    /// more, and never longer than the long run was. Rule 6 swaps first and
    /// trims after; the swap changes the run's intensity, not the length that
    /// rule 5's share bounds, so the run on the long-run day stays inside the
    /// share. Only a run at the floor, the shortest run the plan schedules,
    /// is not read as a long run, as for #101's pain-stop caps (heuristic).
    static func swapLongRunToEasy(_ v: GuardrailViolation, sessions: [Int], plan: [PlannedWorkout], history: [PlannedWorkout],
                                  context ctx: AdaptationContext) -> (plan: [PlannedWorkout], changes: [PlanChange])? {
        let tz = ctx.timeZone
        guard let i = sessions.filter({ plan[$0].kind == .long }).max(by: { volume(plan[$0], .time) < volume(plan[$1], .time) })
        else { return nil }
        let inWeek = (history + plan).filter { PlanCalendar.weekStart(containing: $0.date, timeZone: tz) == v.weekStart }
        let runs = inWeek.filter { $0.kind != .rest && ($0.volume(.time) ?? 1) > 0 }
        let lone = runs.count == 1
        var out = plan
        let w = plan[i]
        // The share is of the week's time, races included, as the checker reads it (3.5 rule 5).
        let others = (history + plan.indices.filter { $0 != i }.map { plan[$0] })
            .filter { PlanCalendar.weekStart(containing: $0.date, timeZone: tz) == v.weekStart }
            .reduce(0.0) { $0 + volume($1, .time) }
        let seconds = longRunDayEasySeconds(w, otherSeconds: others, share: v.allowed, floor: ctx.limits.minimumTrimmedSeconds)
        let shortened = seconds < w.durationSeconds - 1e-6
        var easy = (shortened ? w.resized(toSeconds: seconds) : w).swappedToEasy()
        let why = lone ? "it is the only run of its week" : "no shorter long run fits the long-run share of its week"
        let lengthText = PlanFormatting.volume(easy.durationSeconds, .time)
        if let p = w.prescription, let target = p.segments.first(where: { $0.intensity.isBelowAerobicThreshold })?.target {
            easy.prescription = WorkoutPrescription(
                purpose: "Easy run in place of the long run: \(why), so it is run as an easy run of \(shortened ? lengthText : "the same length") (SPEC 3.5 rules 5 and 6).",
                phase: p.phase,
                segments: [WorkoutSegment(role: .main, intensity: .easy, durationSeconds: easy.durationSeconds, target: target)],
                rules: [.easyByHeartRate])
        }
        out[i] = easy
        let weekText = PlanFormatting.day(v.weekStart, timeZone: tz)
        let trigger = TriggerMetric(metric: .longRunShare, value: v.measured, expectedHigh: v.allowed, unit: .fraction,
                                    sourceID: w.id, detail: v.explanation)
        let reason = lone
            ? "it is the only run left in its week, so it would be all of the week's running"
            : "the week's other running is too little for a long run of even \(PlanFormatting.volume(ctx.limits.minimumTrimmedSeconds, .time)) within the long-run share"
        let what = shortened
            ? "an easy run of \(lengthText), the shortest run the plan schedules or what the long-run share leaves for the day, whichever is more"
            : "an easy run of the same length"
        let load = shortened
            ? "The run on the long-run day stays inside the long-run share, and the load only goes down."
            : "The week's volume stays the same and the load only goes down."
        return (out, [PlanChange(
            kind: .longRunSwappedToEasy, workoutIDs: [w.id], triggers: [trigger], rule: "SPEC 3.5 rules 5 and 6 (heuristic guardrail), F4, F9",
            explanation: "The long run in the week of \(weekText) becomes \(what): \(reason) (\(v.explanation)). \(load) (Heuristic, SPEC 3.5 rules 5 and 6, #122.)")])
    }

    /// A weekly rise or rolling 4-week violation (3.5 rule 2), a volume
    /// freeze (rule 7's freeze after a pain check-in) or a recovery-cadence
    /// violation (3.5's recovery week every third or fourth week, #154) that
    /// nothing left in the week can cut: its quality sessions already became
    /// easy runs, its easy and recovery runs were trimmed (rule 6's order)
    /// and dropped (F4), and every long run still to come is at the plan's
    /// floor (`AdaptationLimits.minimumTrimmedSeconds`, 20 minutes by
    /// default, a product heuristic from `PlanHeuristics`, not SPEC text), so
    /// the runs already done fill the week (#146). By analogy with F4's
    /// missed-day rule (SPEC 8: drop the lowest-value session first, keep the
    /// long run if possible), the long run is kept while anything else can
    /// go; here it is the only session left and can't be shortened further,
    /// so the shortest such long run is dropped, rather than the violation
    /// left or the run planned below the floor. The repair loop drops the
    /// next one if the week is still over. Dropping it only lowers load
    /// (heuristic). Races and runs already done are never touched.
    ///
    /// For the recovery cadence, `amount` is what the week must lose to be a
    /// recovery week (its volume less `recoveryWeekMaxRatio` × the week
    /// before, in the guardrail measure). The drop is made only when the
    /// week's long runs at the floor hold at least that much together, so a
    /// long run is never dropped from a week that would still be a build
    /// week without it; the violation is then left to the report, as before.
    /// The weekly limits and the freeze ignore `amount` (#146's behaviour).
    /// Nil for any other rule, or when no long run at the floor is still to
    /// come.
    static func dropLongRunAtFloor(_ v: GuardrailViolation, sessions: [Int], plan: [PlannedWorkout], week: Date,
                                   trigger: TriggerMetric, amount: Double? = nil,
                                   context ctx: AdaptationContext) -> (plan: [PlannedWorkout], changes: [PlanChange])? {
        let recovery = v.rule == .recoveryWeek
        guard recovery || [.weeklyIncrease, .fourWeekIncrease, .volumeFreeze].contains(v.rule) else { return nil }
        let floor = ctx.limits.minimumTrimmedSeconds
        guard floor.isFinite, floor > 0 else { return nil }
        let atFloor = sessions.filter {
            let w = plan[$0]
            return w.kind == .long && w.durationSeconds.isFinite && w.durationSeconds > 0 && w.durationSeconds <= floor + 1e-6
        }
        guard let i = atFloor.min(by: { (plan[$0].durationSeconds, plan[$0].date) < (plan[$1].durationSeconds, plan[$1].date) })
        else { return nil }
        if recovery {
            let held = atFloor.reduce(0.0) { $0 + volume(plan[$1], ctx.guardrails.measure) }
            guard let amount, amount.isFinite, amount > 0,
                  held + GuardrailChecker.tolerance * max(1, amount) >= amount else { return nil }
        }
        let w = plan[i]
        var out = plan
        out.remove(at: i)
        let weekText = PlanFormatting.day(week, timeZone: ctx.timeZone)
        let floorText = PlanFormatting.volume(floor, .time)
        if recovery {
            return (out, [PlanChange(
                kind: .sessionDropped, workoutIDs: [w.id], triggers: [trigger],
                rule: "SPEC 3.5 recovery-week cadence and rule 6 (heuristic guardrail), F4, F9",
                explanation: "Dropped the long run in the week of \(weekText) to make it a recovery week (SPEC 3.5: a recovery week every third or fourth week, coaching convention; \(v.explanation)). The long run is kept when possible; it is dropped here only because it is already at the plan's \(floorText) floor and nothing else in the week is left to cut, as F4's missed-day rule drops the lowest-value session first and keeps the long run if possible. The load only goes down. (Heuristic, SPEC 3.5 recovery-week cadence and rule 6, F4.)")])
        }
        let rules = v.rule == .volumeFreeze ? "rules 6 and 7" : "rules 2 and 6"
        return (out, [PlanChange(
            kind: .sessionDropped, workoutIDs: [w.id], triggers: [trigger], rule: "SPEC 3.5 \(rules) (heuristic guardrail), F4, F9",
            explanation: "Dropped the long run in the week of \(weekText) to stay inside the load guardrails (\(v.explanation)). The long run is kept when possible; it is dropped here only because it is already at the plan's \(floorText) floor and nothing else in the week is left to cut. The load only goes down. (Heuristic, SPEC 3.5 \(rules), F4.)")])
    }

    /// What `giveBack` compares for a violation across two reports. A spike
    /// violation's `measured` is the worse of the run's time (seconds) and
    /// distance (meters) under one key, so its unit can differ between two
    /// reports; its `measured / allowed` is the same number in either unit
    /// (#138), so that is compared. Any other rule's `measured` is in one
    /// unit under its key and is compared as it is. Not a number when
    /// `measured` isn't, or when a spike's `allowed` isn't a finite number
    /// above 0 (the checker never emits one, but a ratio over 0 would be
    /// infinite and hide growth), which counts as more.
    static func comparable(_ v: GuardrailViolation) -> Double {
        guard v.rule == .singleRunSpike else { return v.measured }
        guard v.allowed.isFinite, v.allowed > 0 else { return .nan }
        return v.measured / v.allowed
    }

    /// No new violation (#126), and none in this week or keyed to a target
    /// run that measures more (#131): keys name the rule, week and run, not
    /// by how much, so a run stuck over the spike rule could otherwise grow,
    /// only to be cut again. A later week's violation (nil) that grows is
    /// left to repair, which reaches that week afterwards (it works earliest
    /// week first). A value that isn't a number counts as more. Values are
    /// `comparable(_:)`, so a spike that flips between time and distance is
    /// compared as a ratio.
    static func noWorse(_ new: [String: Double?], than old: [String: Double?]) -> Bool {
        new.allSatisfy { k, m in
            guard let was = old[k] else { return false }
            guard let m, let was else { return true }
            return m <= was + GuardrailChecker.tolerance * max(1, abs(was))
        }
    }

    /// Gives the time a long-to-easy swap freed (`was` shortened to
    /// `swapped`, #122) back to the week's other easy and recovery runs
    /// still to come that this repair shortened (`input` is the plan as
    /// repair got it), in date order, each never past its length in `input`
    /// and in whole minutes. The week never holds more than it did before the
    /// swap, in time or in the guardrail measure, so the holds and ceilings
    /// that bound its volume still hold; and each step is kept only when the
    /// checker finds no violation the plan without it didn't have (the spike
    /// rule, the weekly checks, the recovery cadence, the share), and no
    /// violation both plans have in this week, or keyed to a run it grows,
    /// measures more (#131): a run already over the spike rule at the floor,
    /// or this week already over a weekly limit, is never grown further only
    /// for the next repair pass to cut it again. A later week's violation
    /// may grow; repair cuts that week afterwards, as it did before #131.
    /// Heuristic, like `cut`'s give-back after a dropped run (SPEC 3.5 rules
    /// 5 and 6).
    static func giveBack(freedBy was: PlannedWorkout, swapped: PlannedWorkout, week: Date, plan: [PlannedWorkout],
                         input: [PlannedWorkout], history: [PlannedWorkout], asOf: Date, freezes: [DateInterval],
                         context ctx: AdaptationContext, regrowth: GuardrailRegrowth) -> (plan: [PlannedWorkout], seconds: Double) {
        let tz = ctx.timeZone
        let measure = ctx.guardrails.measure
        var freedSeconds = was.durationSeconds - swapped.durationSeconds
        var freedVolume = (was.volume(measure) ?? 0) - (swapped.volume(measure) ?? 0)
        guard freedSeconds.isFinite, freedSeconds >= 60, freedVolume.isFinite, freedVolume > 0 else { return (plan, 0) }
        var out = plan
        var given = 0.0
        let targets = out.indices.filter { i in
            let w = out[i]
            return w.id != swapped.id && (w.kind == .easy || w.kind == .recovery) && w.date >= asOf
                && PlanCalendar.weekStart(containing: w.date, timeZone: tz) == week
        }.sorted { out[$0].date < out[$1].date }
        let targetIDs = Set(targets.map { out[$0].id })
        /// Each violation's key, with what it measures (`comparable`) when it is in this
        /// week or keyed to a target run (the most, if a key repeats), and
        /// nil for a later week's.
        func measured(_ p: [PlannedWorkout]) -> [String: Double?] {
            let vs = GuardrailChecker.check(history: history, planned: p, timeZone: tz, limits: ctx.guardrails, freezes: freezes,
                                            units: ctx.units, regrowth: regrowth).violations
            return Dictionary(vs.map { v in
                (key(v), v.weekStart == week || v.workoutID.map(targetIDs.contains) == true ? Optional(comparable(v)) : nil)
            }, uniquingKeysWith: { a, b in
                guard let a, let b else { return a ?? b }
                return a.isNaN || b.isNaN ? .nan : max(a, b)
            })
        }
        func noWorse(_ new: [String: Double?], than old: [String: Double?]) -> Bool {
            GuardrailRepair.noWorse(new, than: old)
        }
        var allowed = measured(out)
        for i in targets {
            let w = out[i]
            guard let before = input.first(where: { $0.id == w.id }), before.durationSeconds.isFinite,
                  w.durationSeconds.isFinite, w.durationSeconds > 0, let vol = w.volume(measure), vol > 0 else { continue }
            let room = min(freedSeconds, before.durationSeconds - w.durationSeconds)
            var hi = Int((room / 60 + 1e-9).rounded(.down))
            guard hi > 0 else { continue }
            func grown(_ k: Int) -> PlannedWorkout? {
                let r = w.resized(toSeconds: w.durationSeconds + Double(k) * 60)
                guard let v = r.volume(measure), v - vol <= freedVolume + 1e-6 else { return nil }
                return r
            }
            // The most whole minutes that fit, by bisection (heuristic): a size
            // that fails is taken to fail when larger too. That mostly holds,
            // since a longer run measures more on its own spike and its week's
            // volume, but not always, since it also raises later runs' spike
            // reference and the next week's allowed rise. Where it doesn't hold,
            // bisection can only settle on less than would fit: every size it
            // keeps is checked in full, so the give-back is never less safe.
            var lo = 0
            var best: (PlannedWorkout, [String: Double?])?
            while lo < hi {
                let mid = (lo + hi + 1) / 2
                var trial = out
                if let r = grown(mid) {
                    trial[i] = r
                    let k = measured(trial)
                    if noWorse(k, than: allowed) { lo = mid; best = (r, k); continue }
                }
                hi = mid - 1
            }
            guard let (r, k) = best else { continue }
            let addedSeconds = r.durationSeconds - w.durationSeconds
            freedSeconds -= addedSeconds
            freedVolume -= (r.volume(measure) ?? vol) - vol
            given += addedSeconds
            out[i] = r
            allowed = k
            if freedSeconds < 60 || freedVolume <= 1e-6 { break }
        }
        return (out, given)
    }

    /// The most an easy run in place of the long run `w` may last (SPEC 3.5
    /// rules 5 and 6, #122, heuristic): the length that keeps it within
    /// `share` of the week's time beside `otherSeconds` of other running
    /// (`share / (1 - share) × otherSeconds`, rounded down to a whole
    /// minute), or `floor` if that is more, and never longer than `w`. A
    /// share that isn't a finite number in [0, 1), or other running that
    /// isn't a finite number above 0, leaves only the floor. A floor that
    /// isn't a finite number above 0, or a run of no valid length, leaves
    /// `w`'s length as it is (nothing to trim to).
    static func longRunDayEasySeconds(_ w: PlannedWorkout, otherSeconds: Double, share: Double, floor: Double) -> Double {
        guard w.durationSeconds.isFinite, w.durationSeconds > 0, floor.isFinite, floor > 0 else { return w.durationSeconds }
        var fit = 0.0
        if share.isFinite, share >= 0, share < 1, otherSeconds.isFinite, otherSeconds > 0 {
            fit = PlanBuilder.floorMinute(share / (1 - share) * otherSeconds)
        }
        return min(w.durationSeconds, max(floor, fit))
    }

    /// A week with more quality sessions than allowed (3.5 rule 4's return
    /// ramp, or the weekly limit): the latest quality sessions still to come
    /// become easy runs of the same length until the count fits. A race is
    /// never changed. Nil when no quality session is left to swap.
    static func swapExcessQuality(_ v: GuardrailViolation, sessions: [Int], plan: [PlannedWorkout],
                                  context ctx: AdaptationContext) -> (plan: [PlannedWorkout], changes: [PlanChange])? {
        guard v.measured.isFinite, v.allowed.isFinite else { return nil }
        let excess = Int((v.measured - v.allowed).rounded(.up))
        let quality = sessions.filter { plan[$0].kind.isQuality }.sorted { plan[$0].date > plan[$1].date }
        guard excess > 0, !quality.isEmpty else { return nil }
        let swap = Array(quality.prefix(excess))
        var out = plan
        let weekText = PlanFormatting.day(v.weekStart, timeZone: ctx.timeZone)
        for i in swap {
            out[i] = plan[i].swappedToEasyKeepingTarget(reason: "the week of \(weekText) holds too many quality sessions (SPEC 3.5 rule 4).")
        }
        let trigger = TriggerMetric(metric: .qualitySessions, value: v.measured, expectedHigh: v.allowed, unit: .count, detail: v.explanation)
        let n = swap.count
        let ids = swap.sorted { plan[$0].date < plan[$1].date }.map { plan[$0].id }
        return (out, [PlanChange(
            kind: .qualitySwappedToEasy, workoutIDs: ids, triggers: [trigger], rule: "SPEC 3.5 rules 4 and 6 (heuristic guardrail), F4, F9",
            explanation: "\(n == 1 ? "A quality session" : "\(n) quality sessions") in the week of \(weekText) \(n == 1 ? "becomes an easy run" : "become easy runs") of the same length to stay within the limit on quality sessions: \(v.explanation)")])
    }

    /// The run a spike violation names, shortened to `allowed` (by the
    /// fraction `allowed / measured`, so a time or a distance limit alike),
    /// rounded down to a whole minute and no shorter than
    /// `minimumTrimmedSeconds`. Only an easy, recovery or long run still to
    /// come (in `sessions`) is cut. Nil when it can't be shortened.
    ///
    /// In a first week with no history (no run of known time in the 30
    /// days), the checker measures each run against the runs earlier in the
    /// same week, so this can cut a long run to 10% over an easy run earlier
    /// that week. That is the rule as written (SPEC 3.5 rule 1 says nothing
    /// of an unrecorded past); the plan builder avoids it by shaping such a
    /// week to hold together (`PlanBuilder`, `reshapeChain`), so it matters
    /// only after the runner changes the week, for example by missing runs.
    static func cutSpike(_ v: GuardrailViolation, sessions: [Int], plan: [PlannedWorkout],
                         context ctx: AdaptationContext) -> Cut? {
        guard let id = v.workoutID, let i = sessions.first(where: { plan[$0].id == id }) else { return nil }
        let w = plan[i]
        guard [.easy, .recovery, .long].contains(w.kind), v.measured > 0, v.allowed.isFinite, v.allowed >= 0,
              w.durationSeconds.isFinite, w.durationSeconds > 0 else { return nil }
        let exact = PlanBuilder.floorMinute(w.durationSeconds * v.allowed / v.measured)
        // A run already under the floor gets no floor: SPEC 3.5 rule 1 applies
        // after the 3.3 hold (owner's decision, #159; the floor is a heuristic
        // and the run is already under it). It is cut to the whole minute the
        // rule allows, or dropped when that is under a minute. A run at or
        // above the floor is never cut below it.
        let minimum = ctx.limits.minimumTrimmedSeconds
        if minimum.isFinite, minimum > 0, w.durationSeconds < minimum - 1e-9 {
            if exact > 0 {
                guard exact < w.durationSeconds else { return nil }
                var out = plan
                out[i] = w.resized(toSeconds: exact)
                return Cut(plan: out, shortened: [id], dropped: [],
                           remaining: max(0, out[i].durationSeconds - w.durationSeconds * v.allowed / v.measured))
            }
            var out = plan
            out.removeAll { $0.id == id }
            return Cut(plan: out, shortened: [], dropped: [id], remaining: 0)
        }
        let seconds = max(minimum, exact)
        guard seconds < w.durationSeconds else { return nil }
        var out = plan
        out[i] = w.resized(toSeconds: seconds)
        let left = max(0, (out[i].durationSeconds - w.durationSeconds * v.allowed / v.measured))
        return Cut(plan: out, shortened: [id], dropped: [], remaining: left)
    }

    struct Cut {
        var plan: [PlannedWorkout]
        var shortened: [String]
        var dropped: [String]
        /// What could not be cut (in the guardrail measure); 0 when `amount` was reached.
        var remaining: Double
    }

    /// Cuts `amount` (in the guardrail measure) from the sessions at `sessions`:
    /// easy and recovery runs in proportion down to the floor, then the long
    /// run, then easy and recovery runs dropped shortest first (`longOnly`: the
    /// long run alone). With `longFloorSeconds`, a long run is shortened to no
    /// less than that. Nil when nothing could be cut.
    static func cut(_ amount: Double, sessions: [Int], longOnly: Bool, plan: [PlannedWorkout],
                    longFloorSeconds: Double? = nil, context ctx: AdaptationContext) -> Cut? {
        guard amount.isFinite, amount > 0 else { return nil }
        let measure = ctx.guardrails.measure
        var out = plan
        var shortened: [String] = []
        var dropped: [String] = []
        var remaining = amount
        let minimum = ctx.limits.minimumTrimmedSeconds
        func floor(_ w: PlannedWorkout) -> Double {
            guard w.kind == .long, let f = longFloorSeconds else { return minimum }
            return max(minimum, f)
        }

        func trim(_ idxs: [Int]) {
            // Room above the floor, in the guardrail's measure.
            let room = idxs.map { i -> Double in
                let w = out[i], f = floor(w)
                guard w.durationSeconds > f, let vol = w.volume(measure), vol > 0 else { return 0 }
                return vol * (1 - f / w.durationSeconds)
            }
            let total = room.reduce(0, +)
            guard total > 0, remaining > 0 else { return }
            let share = min(1, remaining / total)
            for (k, i) in idxs.enumerated() where room[k] > 0 {
                let w = out[i]
                guard let vol = w.volume(measure) else { continue }
                let target = vol - room[k] * share
                var seconds = w.durationSeconds * target / vol
                seconds = max(floor(w), PlanBuilder.floorMinute(seconds))
                guard seconds < w.durationSeconds else { continue }
                let resized = w.resized(toSeconds: seconds)
                remaining -= vol - (resized.volume(measure) ?? vol)
                out[i] = resized
                if !shortened.contains(w.id) { shortened.append(w.id) }
            }
        }

        let easy = sessions.filter { out[$0].kind == .easy || out[$0].kind == .recovery }
        let longs = sessions.filter { out[$0].kind == .long }
        if longOnly {
            trim(longs)
        } else {
            trim(easy)
            if remaining > 1e-6 { trim(longs) }
            if remaining > 1e-6 {
                for i in easy.sorted(by: { out[$0].durationSeconds < out[$1].durationSeconds }) where remaining > 1e-6 {
                    remaining -= volume(out[i], measure)
                    dropped.append(out[i].id)
                }
            }
        }
        // Dropping a whole run can overshoot: what it cut past the amount is
        // given back to the runs kept that this cut shortened, never past
        // their length before it, so a small week isn't held a run's length
        // below its limit (#64: at a few runs a week, the floor would
        // otherwise hold the regrowth at a whole number of floor-length runs).
        if !dropped.isEmpty, remaining < -1e-6 {
            var back = -remaining
            for i in sessions where !dropped.contains(out[i].id) && shortened.contains(out[i].id) && back > 1e-6 {
                let w = out[i]
                guard let vol = w.volume(measure), vol > 0, let before = plan[i].volume(measure), before > vol else { continue }
                let add = min(back, before - vol)
                let seconds = min(plan[i].durationSeconds, PlanBuilder.floorMinute(w.durationSeconds * (vol + add) / vol))
                guard seconds > w.durationSeconds else { continue }
                let resized = w.resized(toSeconds: seconds)
                back -= (resized.volume(measure) ?? vol) - vol
                out[i] = resized
            }
            remaining = -back
        }
        out.removeAll { dropped.contains($0.id) }
        shortened.removeAll { dropped.contains($0) }
        guard !shortened.isEmpty || !dropped.isEmpty else { return nil }
        return Cut(plan: out, shortened: shortened, dropped: dropped, remaining: max(0, remaining))
    }

    /// The changes describing a cut, both citing `trigger`.
    static func changes(_ c: Cut, week: Date, trigger: TriggerMetric, rule: String, reason: String,
                        context ctx: AdaptationContext) -> [PlanChange] {
        let tz = ctx.timeZone
        let unique = c.shortened, dropped = c.dropped
        let weekText = PlanFormatting.day(week, timeZone: tz)
        var changes: [PlanChange] = []
        if !unique.isEmpty {
            changes.append(PlanChange(kind: .sessionShortened, workoutIDs: unique, triggers: [trigger], rule: rule,
                                      explanation: "Shortened \(unique.count == 1 ? "a session" : "\(unique.count) sessions") in the week of \(weekText) \(reason)"))
        }
        if !dropped.isEmpty {
            changes.append(PlanChange(kind: .sessionDropped, workoutIDs: dropped, triggers: [trigger], rule: rule,
                                      explanation: "Dropped the lowest-value \(dropped.count == 1 ? "session" : "sessions") in the week of \(weekText) because shortening was not enough \(reason)"))
        }
        return changes
    }
}

extension AdaptationOutcome {
    /// The Monday from which a new plan can be built, when the plan ahead
    /// rises over a week whose volume is unknown with nothing of known time
    /// (#40, `GuardrailViolation.rebuildOn`): that rise is left in
    /// `guardrailReport` uncut, and only a week of known volume run first
    /// gives it a reference. As with `PlanBuildIssue.historyVolumeUnknown(rebuildOn:)`.
    /// Nil otherwise.
    public var rebuildOn: Date? { guardrailReport.violations.compactMap(\.rebuildOn).min() }
}
