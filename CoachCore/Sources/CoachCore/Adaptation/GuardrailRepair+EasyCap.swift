import Foundation

// Easy runs within the long run in plans the adaptation engine changes
// (SPEC.md 3.5 rule 5 and F3; owner's decision, #54).
//
// F3's limit, no easy run longer than the week's long run, holds for adapted
// plans too. When a repair cuts a long run (usually the long-run share
// repair), the week settles in one pass:
//   1. the share was read once, before this cap, and the long run is cut as
//      the repair does (that is done by the time `capEasyRuns` runs);
//   2. every easy or recovery run still to come in the week that is longer
//      than the cut long run is cut to the long run's length, and so is a
//      quality session's easy extension (`PlannedWorkout.easyExtensionSeconds`);
//   3. the time cut in step 2 is dropped, not moved to other runs, so the
//      week comes out smaller, and a note says why.
// The cap never triggers a second share repair: the week keeps its time
// before the cap (`GuardrailPreCap`), which the checker reads the share and
// the later weeks' checks against. Runs already done are never changed.

extension GuardrailRepair {
    /// Why the long run is as long as it is when the cap is made, for the note.
    enum LongRunCut {
        /// Cut to fit its share of the week (3.5 rule 5).
        case share
        /// Cut to stay inside the load guardrails (rules 2 and 7, holds).
        case guardrails
        /// Not cut by this repair: a plan handed in with an easy run over its long run.
        case none
    }

    struct EasyCap {
        var plan: [PlannedWorkout]
        var changes: [PlanChange]
        var preCap: GuardrailPreCap
    }

    /// The weeks in which a repair step cut a long run that is still a long
    /// run (shorter than before, same id and kind), earliest first. A long
    /// run that was dropped or turned into an easy run leaves a week with no
    /// long run to cap at (F3's limits for such weeks apply).
    static func weeksWithLongRunCut(before: [PlannedWorkout], after: [PlannedWorkout], timeZone tz: TimeZone) -> [Date] {
        var weeks: Set<Date> = []
        for w in after where w.kind == .long {
            guard let was = before.first(where: { $0.id == w.id && $0.kind == .long }),
                  w.durationSeconds.isFinite, was.durationSeconds.isFinite,
                  w.durationSeconds < was.durationSeconds - 1e-6 else { continue }
            weeks.insert(PlanCalendar.weekStart(containing: w.date, timeZone: tz))
        }
        return weeks.sorted()
    }

    /// The week's long run in seconds: the longest `.long` session of the
    /// week, done or planned, as the checker reads it (F3). Nil with none, or
    /// one under a minute (no whole-minute length to cap at).
    static func longRunSeconds(week: Date, plan: [PlannedWorkout], history: [PlannedWorkout], timeZone tz: TimeZone) -> Double? {
        let longest = (history + plan)
            .filter { $0.kind == .long && PlanCalendar.weekStart(containing: $0.date, timeZone: tz) == week }
            .compactMap { $0.volume(.time) }.max()
        guard let longest, longest.isFinite, longest >= 60 else { return nil }
        return longest
    }

    /// The week's time and, when every session has a known distance, its
    /// distance, history and plan together (what the checker reads).
    private static func weekTotals(_ week: Date, _ all: [PlannedWorkout], _ tz: TimeZone) -> (seconds: Double, meters: Double?)? {
        let inWeek = all.filter { PlanCalendar.weekStart(containing: $0.date, timeZone: tz) == week }
        var seconds = 0.0
        var meters: Double? = 0
        for w in inWeek {
            guard let s = w.volume(.time) else { return nil }
            seconds += s
            if let m = w.volume(.distance), let total = meters { meters = total + m } else { meters = nil }
        }
        return (seconds, meters)
    }

    /// Caps the easy and recovery runs still to come in `week`, and the easy
    /// extension of its quality sessions, at the week's long run (SPEC 3.5
    /// rule 5, #54), and records the week's time before the cap in `preCap`.
    ///
    /// A run longer than the long run is cut to the long run's length in
    /// whole minutes. A quality session's easy extension is cut so the whole
    /// session is no longer than the long run, never below the session
    /// without its extension: the warm-up, the hard part and the planned
    /// cool-down stay. (Conservative reading of "cut to that length": F3 lets
    /// a session grow by easy running only up to the week's long run.) The
    /// time cut is dropped, never given to other runs. Nil when nothing is
    /// longer than the long run, or the week has no long run.
    static func capEasyRuns(week: Date, plan: [PlannedWorkout], history: [PlannedWorkout], asOf: Date,
                            longRunCut: LongRunCut, preCap: GuardrailPreCap,
                            context ctx: AdaptationContext) -> EasyCap? {
        let tz = ctx.timeZone
        guard let long = longRunSeconds(week: week, plan: plan, history: history, timeZone: tz),
              let before = weekTotals(week, history + plan, tz) else { return nil }
        let target = PlanBuilder.floorMinute(long)
        var out = plan
        var easyIDs: [String] = []
        var qualityIDs: [String] = []
        var longest = 0.0
        for i in out.indices {
            let w = out[i]
            guard w.date >= asOf, w.durationSeconds.isFinite,
                  PlanCalendar.weekStart(containing: w.date, timeZone: tz) == week else { continue }
            if w.kind == .easy || w.kind == .recovery {
                guard w.durationSeconds > long + GuardrailChecker.tolerance * max(1, long) else { continue }
                longest = max(longest, w.durationSeconds)
                out[i] = w.resized(toSeconds: target)
                easyIDs.append(w.id)
            } else if w.kind.isQuality, w.easyExtensionSeconds > 0 {
                let extra = w.easyExtensionSeconds
                // The session's length without its extension: warm-up, hard part and planned cool-down.
                let room = max(0, long - (w.durationSeconds - extra))
                guard room < extra - 1e-6 else { continue }
                out[i] = w.cuttingEasyExtension(toSeconds: room)
                qualityIDs.append(w.id)
            }
        }
        guard !easyIDs.isEmpty || !qualityIDs.isEmpty, let after = weekTotals(week, history + out, tz) else { return nil }
        let timeBefore = before.seconds + preCap.extra(week, actual: before.seconds, .time)
        let metersBefore = before.meters.map { $0 + preCap.extra(week, actual: $0, .distance) }
        let recorded = preCap.recording(weekStart: week, secondsBefore: timeBefore, secondsAfter: after.seconds,
                                        metersBefore: metersBefore, metersAfter: after.meters)
        let dropped = before.seconds - after.seconds
        let minutes = Int(target / 60)
        let longText = "\(minutes) \(minutes == 1 ? "minute" : "minutes")"
        let weekText = PlanFormatting.day(week, timeZone: tz)
        let day = longRunDay(week: week, plan: plan, history: history, timeZone: tz)
        let why: String
        switch longRunCut {
        case .share: why = "\(day) long run, cut to fit its share of the week, stays the week's longest run"
        case .guardrails: why = "\(day) long run, cut to stay inside the load guardrails, stays the week's longest run"
        case .none: why = "no easy run is longer than the week's long run (\(day) long run is the week's longest run)"
        }
        var parts: [String] = []
        if !easyIDs.isEmpty {
            parts.append("Easy runs shortened to \(longText) so that \(why).")
        }
        if !qualityIDs.isEmpty {
            parts.append("\(easyIDs.isEmpty ? "The easy running at the end of a quality session's cool-down is shortened" : "The easy running at the end of a quality session's cool-down is shortened too") so that the session is no longer than the long run; its warm-up, hard part and planned cool-down stay\(easyIDs.isEmpty ? ", and " + why : "").")
        }
        parts.append("The \(PlanFormatting.volume(dropped, .time)) this cuts is not moved to other runs, so the week of \(weekText) comes out smaller. (Heuristic, SPEC F3 and 3.5 rule 5, #54.)")
        let trigger = TriggerMetric(metric: .longRunDuration, value: easyIDs.isEmpty ? long : longest, expectedHigh: long,
                                    unit: .seconds, sourceID: (easyIDs + qualityIDs).first,
                                    detail: "the week's long run is \(PlanFormatting.volume(long, .time)), and a run in the week to come was longer")
        let change = PlanChange(kind: .sessionShortened, workoutIDs: easyIDs + qualityIDs, triggers: [trigger],
                                rule: "SPEC F3 and 3.5 rule 5 (heuristic guardrail), F4, F9", explanation: parts.joined(separator: " "))
        return EasyCap(plan: out, changes: [change], preCap: recorded)
    }

    /// "Saturday's" for the day of the week's longest long run, or "the week's" with none.
    private static func longRunDay(week: Date, plan: [PlannedWorkout], history: [PlannedWorkout], timeZone tz: TimeZone) -> String {
        let longs = (history + plan).filter { $0.kind == .long && PlanCalendar.weekStart(containing: $0.date, timeZone: tz) == week }
        guard let w = longs.max(by: { ($0.volume(.time) ?? 0) < ($1.volume(.time) ?? 0) }) else { return "the week's" }
        let names = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
        return "\(names[PlanWeekday(of: w.date, timeZone: tz).rawValue])'s"
    }
}
