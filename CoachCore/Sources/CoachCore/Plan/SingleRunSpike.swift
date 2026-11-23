import Foundation

/// The single-run spike rule (SPEC.md 3.5 rule 1, F9), the primary load check:
/// no planned run is more than `GuardrailLimits.maxSingleRunIncrease` (10% by
/// default) longer than the longest run of the previous
/// `GuardrailLimits.spikeWindowDays` (30) days.
///
/// **Heuristic.** The figures come from the Garmin-RUNSAFE cohort [1]
/// (Frandsen, Nielsen et al., BJSM 2025), which found a single run longer than
/// the 30-day longest raised overuse-injury rate (HRR 1.64 for 10 to 30%
/// longer) while week-to-week change showed no link. [1] reports no target:
/// 10% sits at the bottom of the band that raised injury rate, and SPEC 3.5
/// sets 5 to 10% as the target, so the limit is configurable. The plan builder
/// (F3) aims a little under it (`PlanHeuristics.guardrailMargin`).
///
/// How it is read:
/// - **Window.** For a run on day `D` (in the runner's time zone), the window is
///   every session that starts before the run, on day `D - 30` or later. So a
///   run 30 calendar days earlier counts, one 31 days earlier does not; a
///   run earlier on the same day counts. The window rolls back from each run's
///   own date.
/// - **What counts as the longest run.** Completed runs (`history`) and planned
///   runs that come earlier in the window, of any kind but rest days. Each
///   measure is read on its own (`PlannedWorkout.volume`).
/// - **Measures.** Time is always checked (every run has a duration). Distance
///   is checked too when the planned run states one (a plan that measures
///   distance) and the window holds a run of known distance. A run breaks the
///   rule when it is too long in either; the report gives the measure that
///   needs the larger cut.
/// - **Races** (SPEC 3.5 rule 3). A race, planned or completed in a checked
///   week, is never a violation: when it is longer than the allowance it is
///   reported in `GuardrailReport.informationFlags` only. A race does **not**
///   count as the longest run for later runs unless
///   `GuardrailLimits.racesSetSpikeReference` is set (default false). That is a
///   heuristic, the conservative reading: a half or full marathon is usually
///   longer than any training run, and letting it raise the reference would
///   let the long runs after it jump, the same reason rule 3 leaves the race
///   out of the next week's 10% baseline.
/// - **Unknown lengths (#40).** A run whose time is unknown (`durationSeconds`
///   NaN, infinite or negative, as a broken history import leaves it) never
///   counts as the longest run, and is never read as 0 or as a short run, so it
///   can't make the reference look low. The reference is the longest run of
///   known length; the true longest is at least that (an unknown run is known
///   only to be at least 0), so holding a planned run to it keeps the rule for
///   every length the unknown runs may truly have had, like the 10% rule's
///   lower-bound reference. The explanation names the runs left out. When the
///   window holds **no** run of known time, nothing is invented: the run is
///   reported in `notEvaluated`. A planned run whose own time is unknown is
///   never flagged; it is reported in `notEvaluated` too.
///   This differs on purpose from the 10% weekly rule, which gives a week
///   resting on an unknown week with no known time an allowance of 0 and
///   blocks it until a known week has been run. That block has an end (the
///   rebuild date) and no week can be planned without a reference. A spike
///   allowance of 0 would flag every run of the week after such a window,
///   and no cut could clear it short of deleting the run; the first run of a
///   runner with no history is in the same place and is not evaluated
///   either. The weekly, 4-week and freeze rules still bound the load there.
/// - Exactly hitting the limit passes (the checker's floating-point tolerance).
extension GuardrailChecker {
    /// The longest run in the window before a date (SPEC 3.5 rule 1).
    public struct SpikeReference: Equatable, Sendable {
        public let measure: VolumeMeasure
        /// The longest known length in the window: seconds for `.time`, meters for `.distance`.
        public let value: Double
        /// The run that set it.
        public let workoutID: String
        public let date: Date
        /// Most a run on the date may be: `value × (1 + maxSingleRunIncrease)`.
        public let allowed: Double
        /// Runs in the window whose length in this measure is unknown, so they
        /// were left out (#40). The true longest may be longer than `value`.
        public let unknownWorkoutIDs: [String]
    }

    /// The longest run of known length in the `spikeWindowDays` before `date`
    /// among `sessions` (any order; history and plan alike), read as the
    /// type's doc says. Nil when the window holds no run of known, positive
    /// length in `measure`: no reference is invented.
    public static func spikeReference(before date: Date, measure: VolumeMeasure, sessions: [PlannedWorkout],
                                      timeZone: TimeZone, limits: GuardrailLimits = .default) -> SpikeReference? {
        let cal = PlanCalendar.calendar(timeZone: timeZone)
        guard limits.spikeWindowDays > 0,
              let start = cal.date(byAdding: .day, value: -limits.spikeWindowDays, to: cal.startOfDay(for: date))
        else { return nil }
        var best: PlannedWorkout?
        var bestValue = 0.0
        var unknown: [String] = []
        for s in sessions where s.date >= start && s.date < date && countsAsReference(s, limits) {
            guard let v = s.volume(measure) else {
                // Distance is often simply not recorded; only an unknown time is a gap (#40).
                if measure == .time || s.distanceMeters != nil { unknown.append(s.id) }
                continue
            }
            if v > bestValue || (v == bestValue && best.map { s.date < $0.date } ?? false) {
                best = s
                bestValue = v
            }
        }
        guard let b = best, bestValue > 0 else { return nil }
        return SpikeReference(measure: measure, value: bestValue, workoutID: b.id, date: b.date,
                              allowed: bestValue * (1 + limits.maxSingleRunIncrease), unknownWorkoutIDs: unknown)
    }

    static func countsAsReference(_ s: PlannedWorkout, _ limits: GuardrailLimits) -> Bool {
        s.kind != .rest && (limits.racesSetSpikeReference || s.kind != .race)
    }

    /// Runs the spike rule over the planned runs, and over completed races in
    /// the checked weeks (`checked`, from the first checked Monday to the end
    /// of the last checked week), for information. `limits.maxSingleRunIncrease`
    /// is always a finite fraction of 0 or more, or `.infinity`
    /// (`GuardrailLimits.valid`, #142), so there is no bad-limit case here
    /// (#150); `.infinity` makes every allowance infinite, so no run exceeds it.
    static func checkSingleRunSpikes(history: [PlannedWorkout], planned: [PlannedWorkout], checked: Range<Date>,
                                     timeZone: TimeZone, limits: GuardrailLimits, units: UnitPreference = .metric)
        -> (violations: [GuardrailViolation], skips: [GuardrailSkip], flags: [GuardrailFlag]) {
        var violations: [GuardrailViolation] = []
        var skips: [GuardrailSkip] = []
        var flags: [GuardrailFlag] = []
        let all = (history + planned).sorted { $0.date < $1.date }
        let doneRaces = history.filter { $0.kind == .race && checked.contains($0.date) }
        let subjects = (planned.filter { $0.kind != .rest } + doneRaces).sorted { $0.date < $1.date }
        func week(_ d: Date) -> Date { PlanCalendar.weekStart(containing: d, timeZone: timeZone) }
        func day(_ d: Date) -> String { PlanFormatting.day(d, timeZone: timeZone) }
        func vol(_ v: Double, _ m: VolumeMeasure) -> String { PlanFormatting.volume(v, m, units: units) }

        for run in subjects {
            let isRace = run.kind == .race
            func skip(_ reason: String) {
                guard !isRace else { return } // a race is never blocked, so nothing is missed
                skips.append(GuardrailSkip(rule: .singleRunSpike, weekStart: week(run.date), reason: reason, workoutID: run.id))
            }
            guard let seconds = run.volume(.time) else {
                skip("the \(describe(run.kind)) on \(day(run.date)) has no valid duration, so its length can't be compared")
                continue
            }
            guard seconds > 0 else { continue }
            // Earlier sessions only: the window ends at the run.
            let earlier = all.prefix(while: { $0.date < run.date })
            var measures: [(VolumeMeasure, Double, SpikeReference)] = []
            if let ref = spikeReference(before: run.date, measure: .time, sessions: Array(earlier),
                                        timeZone: timeZone, limits: limits) {
                measures.append((.time, seconds, ref))
            } else {
                skip("no run of known time in the \(limits.spikeWindowDays) days before the \(describe(run.kind)) on \(day(run.date)), so there is no longest run to compare with")
            }
            if let meters = run.volume(.distance), meters > 0,
               let ref = spikeReference(before: run.date, measure: .distance, sessions: Array(earlier),
                                        timeZone: timeZone, limits: limits) {
                measures.append((.distance, meters, ref))
            }
            let over = measures.filter { exceeds($0.1, $0.2.allowed) }
            guard let worst = over.max(by: { $0.1 / $0.2.allowed < $1.1 / $1.2.allowed }) else { continue }
            let (m, value, ref) = worst
            let rise = value / ref.value - 1
            let what = isRace ? "the race" : "the \(describe(run.kind))"
            let reference = isRace && !limits.racesSetSpikeReference ? "the longest training run" : "the longest run"
            var text = "Week of \(day(week(run.date))): \(what) on \(day(run.date)) (\(vol(value, m))) is \(PlanFormatting.percent(rise)) longer than \(reference) of the \(limits.spikeWindowDays) days before it (\(vol(ref.value, m)) on \(day(ref.date)))."
            if !ref.unknownWorkoutIDs.isEmpty {
                let n = ref.unknownWorkoutIDs.count
                text += " \(n == 1 ? "A run" : "\(n) runs") in that window with no known \(m == .time ? "time" : "distance") \(n == 1 ? "is" : "are") left out, so the longest run may have been longer."
            }
            let unit: GuardrailViolation.Unit = m == .time ? .seconds : .meters
            if isRace {
                text += " A race is never blocked or cut by this rule; this is for information (heuristic guardrail, SPEC 3.5 rules 1 and 3)."
                flags.append(GuardrailFlag(rule: .singleRunSpike, weekStart: week(run.date), measured: value,
                                           allowed: ref.allowed, unit: unit, explanation: text, workoutID: run.id))
            } else {
                text += " The limit is \(PlanFormatting.percent(limits.maxSingleRunIncrease)) longer, so at most \(vol(ref.allowed, m)). (Heuristic guardrail, SPEC 3.5 rule 1.)"
                violations.append(GuardrailViolation(rule: .singleRunSpike, weekStart: week(run.date), measured: value,
                                                     allowed: ref.allowed, unit: unit, explanation: text, workoutID: run.id))
            }
        }
        return (violations, skips, flags)
    }

    static func exceeds(_ measured: Double, _ allowed: Double) -> Bool {
        measured > allowed + tolerance * max(1, abs(allowed))
    }

    static func describe(_ kind: PlannedWorkout.Kind) -> String {
        switch kind {
        case .easy: return "easy run"
        case .long: return "long run"
        case .recovery: return "recovery run"
        case .race: return "race"
        case .rest: return "rest day"
        case .quality: return "quality session"
        }
    }
}
