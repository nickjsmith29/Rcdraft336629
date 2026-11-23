import Foundation

// The easy-run floor on a long run that a pain-stop path caps after the plan
// is built (#101, SPEC 3.5 rules 1, 5 and 7). The plan builder never drafts a
// run under `PlanHeuristics.minimumEasyRunSeconds` (#79, #98), and guardrail
// repair never trims below `AdaptationLimits.minimumTrimmedSeconds`; two caps
// in the engine shorten long runs with no floor: rule 7's week-1 return cap
// (`week1Fraction` of the pre-stop long run) and the easy-only stop's
// long-run share of the held level. Both now go through
// `AdaptationEngine.longRunUnderFloor`, matching the builder: a long run is
// raised to the floor only when the floor fits every limit on it; otherwise
// the day takes an easy run at the floor, or a rest day that says why.
//
// Heuristic: SPEC 3.5 sets no shortest long run; the 20 minutes is the
// builder's easy-run floor. The weekly bounds (the stop's level, the return's
// ceilings from #90, regrowth from #64, the other holds) are kept by the
// hold cuts and guardrail repair that run after these caps. Those only cut,
// never below the floor, and drop a run whole instead, so a run at the floor
// never takes a week over a ceiling.

extension AdaptationEngine {
    /// What becomes of a long run that a cap would shorten under the floor.
    enum LongRunFloorFit: Equatable, Sendable {
        /// A long run of these seconds, the floor: it fits the cap.
        case long(Double)
        /// An easy run of these seconds, the floor: the floor doesn't fit
        /// the cap, so the week has no long run.
        case easy(Double)
        /// A rest day: nothing at the floor can be run there.
        case rest(RestReason)
    }

    enum RestReason: Equatable, Sendable {
        /// The run is planned under the floor: raising it would add load.
        case plannedUnderFloor
        /// Even a run at the floor breaks the single-run spike rule (3.5 rule 1).
        case spike
    }

    /// The decision for a long run `w` that a cap of `cap` (in `measure`)
    /// would shorten under `floor` seconds (heuristic, #101, matching #98's
    /// builder):
    /// 1. Never lengthened: planned under the floor, it becomes a rest day.
    /// 2. A run at the floor that breaks the spike rule (`passesSpike`)
    ///    becomes a rest day too.
    /// 3. A long run at the floor when it fits `cap` (with a whole-minute
    ///    floor this only happens when the cap's own minute rounding missed
    ///    it); otherwise an easy run at the floor, which the long-run share
    ///    (3.5 rule 5) doesn't count.
    /// Nil for a floor, cap or duration that isn't a finite number above 0
    /// (a cap of 0 or more), so the caller leaves the run alone.
    static func longRunUnderFloor(_ w: PlannedWorkout, cap: Double, floor: Double, measure: VolumeMeasure,
                                  passesSpike: (PlannedWorkout) -> Bool) -> LongRunFloorFit? {
        guard floor.isFinite, floor > 0, cap.isFinite, cap >= 0,
              w.durationSeconds.isFinite, w.durationSeconds > 0 else { return nil }
        guard w.durationSeconds >= floor - 1e-9 else { return .rest(.plannedUnderFloor) }
        let atFloor = w.resized(toSeconds: floor)
        guard passesSpike(atFloor) else { return .rest(.spike) }
        if let v = atFloor.volume(measure), v <= cap * (1 + 1e-9) { return .long(floor) }
        return .easy(floor)
    }

    /// True when `run` passes the single-run spike rule (3.5 rule 1) against
    /// the other runs in `sessions` (history and plan; `run` itself is left
    /// out), as `GuardrailChecker` reads it: time always, distance when `run`
    /// states one. A window with no reference isn't evaluated, so it passes.
    static func passesSpike(_ run: PlannedWorkout, sessions: [PlannedWorkout], context: AdaptationContext) -> Bool {
        let others = sessions.filter { $0.id != run.id }
        let measures: [VolumeMeasure] = run.distanceMeters == nil ? [.time] : [.time, .distance]
        for m in measures {
            guard let v = run.volume(m),
                  let ref = GuardrailChecker.spikeReference(before: run.date, measure: m, sessions: others,
                                                            timeZone: context.timeZone, limits: context.guardrails)
            else { continue }
            if v > ref.allowed * (1 + 1e-9) { return false }
        }
        return true
    }
}

extension AdaptationEngine.Work {
    /// The shortest run the engine drafts: `AdaptationLimits.minimumTrimmedSeconds`
    /// (by default `PlanHeuristics.minimumEasyRunSeconds`, 20 min). Nil when
    /// it isn't a finite number above 0, so no floor applies.
    var runFloorSeconds: Double? {
        let f = limits.minimumTrimmedSeconds
        return f.isFinite && f > 0 ? f : nil
    }

    /// True when the long run at `w`'s day was planned as one: it is a long
    /// run, or the plan as the app handed it in (`PlanSnapshot`) has a long
    /// run under its id (the engine or a regrowth trial made it easy).
    func isLongRunDay(_ w: PlannedWorkout) -> Bool {
        w.kind == .long || ((w.kind == .easy || w.kind == .recovery)
            && state.planSnapshot.sessions.contains { $0.id == w.id && $0.kind == .long })
    }

    /// Applies `AdaptationEngine.longRunUnderFloor` to `plan[i]`, a long run
    /// (or the easy run on a long-run day) that `cap` would shorten to
    /// `capped` seconds, under the floor, and posts what it did. `reason`
    /// finishes "…: " with why the cap applies; `source` names the rules.
    /// A session already in the decided shape is left as it is, and nothing
    /// is posted, so the same plan handed back says nothing new.
    mutating func applyLongRunFloor(at i: Int, cap: Double, capped: Double, triggers: [TriggerMetric],
                                    reason: String, source: String) {
        guard let floor = runFloorSeconds else { return }
        let w = plan[i]
        let all = history + plan
        let ctx = context
        guard let fit = AdaptationEngine.longRunUnderFloor(
            w, cap: cap, floor: floor, measure: context.guardrails.measure,
            passesSpike: { AdaptationEngine.passesSpike($0, sessions: all, context: ctx) }) else { return }
        let floorText = AdaptationFormatting.minutes(floor)
        let what = w.kind == .long ? "The long run" : "The \(describe(w.kind)) in place of the long run"
        let left = capped > 0 ? "which leaves \(AdaptationFormatting.minutes(capped))" : "which leaves no time"
        let rule = Self.stopRule
        switch fit {
        case .long(let s) where w.kind == .long:
            guard s < w.durationSeconds else { return }
            plan[i] = w.resized(toSeconds: s)
            changes.append(PlanChange(
                kind: .sessionShortened, workoutIDs: [w.id], triggers: triggers, rule: rule,
                explanation: "\(what) on \(day(w.date)) is shortened to \(floorText), the shortest run the plan schedules: \(reason). A long run of \(floorText) still fits that limit and the single-run spike rule. (Heuristic, \(source), #101.)"))
        case .long(let s), .easy(let s):
            let easy = easyRun(inPlaceOf: w, seconds: s)
            guard easy != w else { return }
            plan[i] = easy
            changes.append(PlanChange(
                kind: w.kind == .long ? .longRunSwappedToEasy : .sessionShortened, workoutIDs: [w.id], triggers: triggers, rule: rule,
                explanation: "\(what) on \(day(w.date)) \(w.kind == .long ? "becomes an easy run of" : "is shortened to") \(floorText), the shortest run the plan schedules: \(reason), \(left), too short for a long run, so this week has none. (Heuristic, \(source), #101.)"))
        case .rest(let why):
            plan[i] = PlannedWorkout(id: w.id, date: w.date, kind: .rest, durationSeconds: 0)
            let because: String
            switch why {
            case .plannedUnderFloor: because = "it is planned at \(AdaptationFormatting.minutes(w.durationSeconds)), under \(floorText), and is never lengthened here"
            case .spike: because = "even a run of \(floorText) would be more than the single-run spike rule allows (SPEC 3.5 rule 1)"
            }
            changes.append(PlanChange(
                kind: .sessionRested, workoutIDs: [w.id], triggers: triggers, rule: rule,
                explanation: "\(what) on \(day(w.date)) becomes a rest day: \(reason), \(left), under \(floorText), the shortest run the plan schedules, and \(because). (Heuristic, \(source), #101.)"))
        }
    }

    /// `w` as an easy run of `seconds` on its day under the easy heart-rate
    /// cap, with an easy prescription built from its own easy target. Its
    /// distance is scaled with its time.
    func easyRun(inPlaceOf w: PlannedWorkout, seconds: Double) -> PlannedWorkout {
        let resized = w.durationSeconds == seconds ? w : w.resized(toSeconds: seconds)
        if w.kind == .easy, resized.prescription?.rules == [.easyByHeartRate] { return resized }
        var easy = resized.swappedToEasy()
        if let p = w.prescription, let target = p.segments.first(where: { $0.intensity.isBelowAerobicThreshold })?.target {
            easy.prescription = WorkoutPrescription(
                purpose: "Easy run in place of the long run: after the pain stop the long run would be too short to run as one, so it is an easy run of \(AdaptationFormatting.minutes(seconds)), the shortest run the plan schedules (SPEC 3.5 rules 5 and 7).",
                phase: p.phase,
                segments: [WorkoutSegment(role: .main, intensity: .easy, durationSeconds: seconds, target: target)],
                rules: [.easyByHeartRate])
        }
        return easy
    }
}
