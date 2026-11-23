import Foundation

// Paces after a break in an adapted plan (SPEC 3.5 rule 4, #28). The plan
// builder applies the Daniels return factor to the plans it builds; a runner
// already on a plan who then misses 6 or more days has to get the same
// slower paces. The engine reads the break from the run history it has, with
// the detection the builder uses (`ReturnPaceSchedule`), and sets the factor
// on the upcoming sessions' anchor- and easy-derived paces. Each session
// records the factor already applied (`WorkoutPrescription.returnPaceFactor`),
// so the step is the same on every event and a lifted factor undoes the
// slow-down.

extension AdaptationEngine.Work {
    /// The latest break that still matters to the plan from `asOf`, or nil.
    /// The dated efforts are the races in the history: a marked race after
    /// the break ends the factor. (A training best effort never does, and
    /// the engine has no dated anchors from before the break; the sessions'
    /// own paces are the pre-break targets.)
    func returnSchedule(asOf: Date) -> ReturnPaceSchedule? {
        let start = calendar.startOfDay(for: asOf)
        let efforts: [AnchorEffort] = history.compactMap { w in
            guard w.kind == .race, let d = w.distanceMeters, d.isFinite, d > 0,
                  w.durationSeconds.isFinite, w.durationSeconds > 0 else { return nil }
            return AnchorEffort(anchor: RaceEquivalent(distanceMeters: d, seconds: w.durationSeconds), date: w.date, isMarkedRace: true)
        }
        // Only the presence of a race matters here, so any distance picks one.
        let meters = plan.compactMap { $0.prescription?.raceDistanceMeters }.first ?? 10_000
        return ReturnPaceSchedule.latest(history: history.filter { $0.date < start }, efforts: efforts,
                                         raceDistanceMeters: meters, startDate: start,
                                         firstMonday: PlanCalendar.weekStart(containing: asOf, timeZone: tz),
                                         timeZone: tz, limits: context.guardrails)
    }

    /// The factor the schedule asks of a session on `date`: its week's, or 1.
    func returnFactor(_ schedule: ReturnPaceSchedule, on date: Date) -> Double {
        let k = schedule.weekNumber(of: PlanCalendar.weekStart(containing: date, timeZone: tz), timeZone: tz)
        return k >= 1 && schedule.affects(week: k) ? min(1, schedule.factor(week: k)) : 1
    }

    /// True when `date` is in weeks 1 to 3 back, where no pace may be faster
    /// than before the break.
    func inReturnCap(_ schedule: ReturnPaceSchedule, on date: Date) -> Bool {
        let k = schedule.weekNumber(of: PlanCalendar.weekStart(containing: date, timeZone: tz), timeZone: tz)
        return schedule.isCapped(week: k)
    }

    /// Sets the return factor on the upcoming sessions.
    mutating func applyReturnPaces(asOf: Date) {
        guard let schedule = returnSchedule(asOf: asOf) else { return }
        let start = calendar.startOfDay(for: asOf)
        var slower: [String] = [], faster: [String] = []
        for i in plan.indices where plan[i].kind != .race && plan[i].date >= start {
            let desired = returnFactor(schedule, on: plan[i].date)
            let applied = plan[i].prescription?.returnPaceFactor ?? 1
            if let n = plan[i].returningPaces(toFactor: desired) {
                plan[i] = n
                if desired < applied { slower.append(n.id) } else { faster.append(n.id) }
            }
        }
        // The original plan moves with it, so what grows back keeps the paces in force.
        for i in state.planSnapshot.sessions.indices where state.planSnapshot.sessions[i].kind != .race
            && state.planSnapshot.sessions[i].date >= start {
            if let n = state.planSnapshot.sessions[i].returningPaces(toFactor: returnFactor(schedule, on: state.planSnapshot.sessions[i].date)) {
                state.planSnapshot.sessions[i] = n
            }
        }
        let weeks = schedule.found.breakWeeks
        let trigger = TriggerMetric(
            metric: .daysOff, value: Double(schedule.daysOff), unit: .days,
            detail: "\(schedule.daysOff) days without a run\(weeks > 0 ? ", \(weeks) of them break \(weeks == 1 ? "week" : "weeks")" : "")")
        let held = schedule.isShort ? "and are lifted over the next 3 weeks" : "and hold until a race you run after the break gives a new anchor"
        if !slower.isEmpty {
            changes.append(PlanChange(
                kind: .returnPaces, workoutIDs: slower, triggers: [trigger], rule: "SPEC 3.5 rule 4 (Daniels return factor)",
                explanation: "After \(schedule.daysOff) days without a run, the anchor- and easy-derived paces on \(slower.count) upcoming \(slower.count == 1 ? "session" : "sessions") are slower (about \(AdaptationFormatting.percent(1 / min(1, schedule.factor) - 1)) in the first week back), \(held). (Daniels return factor, SPEC 3.5 rule 4.)"))
        }
        if !faster.isEmpty {
            changes.append(PlanChange(
                kind: .returnPaces, workoutIDs: faster, triggers: [trigger], rule: "SPEC 3.5 rule 4 (Daniels return factor)",
                explanation: "The slower paces after your break come back toward your pre-break targets on \(faster.count) upcoming \(faster.count == 1 ? "session" : "sessions"). (Daniels return factor, SPEC 3.5 rule 4.)"))
        }
    }
}
