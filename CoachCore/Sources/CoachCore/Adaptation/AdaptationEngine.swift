import Foundation

/// The result of one event through the adaptation engine.
public struct AdaptationOutcome: Equatable, Sendable {
    /// The state to persist and pass to the next event.
    public let state: AdaptationState
    /// Sessions still to come, in date order. A run's matched session has left it.
    /// The app hands this back unchanged with the next event (sessions dated
    /// before that event's day may be dropped); any other plan handed in is
    /// read as a re-plan and becomes the original plan regrowth grows back to
    /// (`PlanSnapshot`, SPEC 3.5 rule 6).
    public let plan: [PlannedWorkout]
    /// Completed sessions, the new run included (as `PlannedWorkout(activity:kind:)`).
    public let history: [PlannedWorkout]
    /// The run's assessment, for a run event.
    public let assessment: RunAssessment?
    /// Every change made, each citing its trigger metrics.
    public let changes: [PlanChange]
    /// The guardrail checker (3.5) over `history` and `plan` with the pain
    /// freezes still in force (`state.freezeIntervals(at:)`). It passes unless
    /// even cutting every session still to come could not fix the plan (for
    /// example, the runner has already run more this week than the limit
    /// allows, or skipped an easy run after the week's long run); the
    /// violations then say why.
    public let guardrailReport: GuardrailReport
    /// True when a pain response applied by this event asks the runner to see a clinician (3.5).
    public let suggestClinician: Bool
    /// False when a volume hold in force could not be met in a week still to
    /// finish, or that week's volume is unknown. It stays false while the
    /// shortfall lasts, while the `holdShortfall` change saying by how much is
    /// posted only when it is new or has changed. True when no hold is in force.
    public let holdsSatisfied: Bool
    /// Pain reported on most days for about a week (3.5 rule 7), read from
    /// every pain report and check-in in `state`; nil otherwise. It stays set
    /// on every event until a pain-free report ends that stretch of pain.
    public internal(set) var lastingPain: LastingPain? = nil
    /// Where 3.5 rule 7 stands: usual pain, the stop, its test run, the
    /// return and the clinician flag (`PainCourseStatus`).
    public internal(set) var painCourse: PainCourseStatus = .none
    /// The weeks growing back to the original plan after a missed, cut or
    /// painful week (SPEC 3.5 rule 6, #64), as the guardrail check of this
    /// outcome read them; `.none` when there are none. Pass it to
    /// `GuardrailChecker.check(regrowth:)` to check the plan the same way.
    public internal(set) var regrowth: GuardrailRegrowth = .none

    /// The flag the app uses to advise seeing a clinician, in its own words
    /// (3.5): pain that stayed high over recent check-ins, or rule 7's
    /// clinician flag (pain above usual for about a week, a red flag, a
    /// second failure in the return, a runner who stays stopped, or a reopen).
    /// It stays on until rule 7 turns it off or closes it, whatever
    /// `lastingPain` says. CoachCore never diagnoses.
    public var adviseClinician: Bool { suggestClinician || painCourse.clinicianFlag != nil }
}

/// The automatic adaptation engine (SPEC.md F4, section 8). Deterministic and
/// stateless: each call takes the state from the previous outcome, the plan
/// still to come and the completed history, and returns new ones.
///
/// After each run (`processRun`):
/// 1. The run is matched to its planned session, measured (`RunMetrics`) and
///    classified (`RunClassifier`): ahead, on track, behind or overreached.
/// 2. **Paces** (heuristic): when `signalsToMove` of the last `signalWindow`
///    classified quality sessions are ahead, quality pace targets (steady,
///    threshold, VO2max, race pace) on sessions to come move one `paceStep`
///    faster; when that many are behind or overreached, they move one step
///    slower and volume is held for `holdVolumeDays` (`VolumeHold`). A move consumes the
///    sessions behind it, so one-offs never move paces and the same sessions
///    never move them twice.
/// 3. **Easy runs above the cap:** when the mean heart rate of the last
///    `easyRunsForCapCheck` easy, recovery or long runs is at or above the
///    top of zone 2, easy pace targets move one step slower and the change
///    flags it for the debrief (F6).
/// 4. **Long runs** progress only when the last `longRunQualifyingCount`
///    long runs were run to `longRunCompletionShare` of their planned time
///    with steady pace-to-HR decoupling under `longRunDecouplingLimit` (3.3).
///    A long run too short for a decoupling reading (moving time of at most
///    `DecouplingOptions.minimumMovingSeconds`) counts instead when its
///    average heart rate stayed below the top of zone 2 (heuristic, SPEC 3.3,
///    #170);
///    the step is then at most `longRunStepSeconds` above the longest long run
///    planned among the last `longRunReferenceRuns`. Otherwise the next long
///    run is held at that length. Until `longRunQualifyingCount` long runs are
///    done the gate is open: the plan builder sized them from the baseline.
///
/// A quality session or race run on another day than planned (named with
/// `CompletedRun.plannedWorkoutID`) is placed on the day it was run, and a
/// quality session still to come on that day or the next turns easy
/// (`separateHardDays`), so two hard days never stack.
///
/// After each pain check-in (`processCheckIn`), the 3.5 rule
/// (`PainCheckInRule`) is evaluated with every check-in so far and the date
/// of the last applied one. A response is stored, its freeze kept in force
/// until it ends, and its quality swap re-applied if the plan given later
/// still holds that session as quality.
///
/// After each pain report (`processPainReport`), from any runner after any
/// run or the next morning, the pain stop rule (3.5 rule 7, `PainStopRule`)
/// runs: pain that got worse during the run, changed how the runner moved or
/// is still there the next morning stops progression (`PainStop`). A report
/// with a score is also a pain check-in for runners who track pain. While a
/// stop stands, every event (the no-op ones included) keeps the plan
/// easy-only or rest and every week at most the fixed pre-stop level
/// (`PainStop.level`). A stop ends only by rule 7's end path, and the return
/// guards then shape the plan (`AdaptationEngine+PainRecovery.swift`).
///
/// On every event (and `processDay` on a day without one), planned sessions
/// from earlier days that were not run are **missed**: a long run or quality
/// session takes the slot of the lowest-value later session in the same week
/// (dropping it, so the week is never crammed), never next to another quality
/// day or race; easy and recovery runs are simply dropped (F4, section 8).
///
/// Finally `GuardrailRepair` shortens sessions to come until the plan passes
/// `GuardrailChecker` with the pain freezes in force (volume holds are
/// enforced before it, see `VolumeHold`), and every change is returned
/// with its trigger metrics. Not here yet: weather and grade (F7, F8), the
/// morning readiness check (F5) and zone recomputation (3.2).
public enum AdaptationEngine {
    public static func processRun(_ run: CompletedRun, state: AdaptationState, plan: [PlannedWorkout],
                                  history: [PlannedWorkout], context: AdaptationContext) -> AdaptationOutcome {
        let a = run.activity
        let end = a.durationSeconds.isFinite && a.durationSeconds > 0 ? a.start.addingTimeInterval(a.durationSeconds) : a.start
        var w = Work(state: state, plan: plan, history: history, context: context, asOf: a.start)
        // A run seen before (the app re-syncs) is a no-op: counting it again
        // would double its volume and log it a second time as unplanned.
        if history.contains(where: { $0.id == a.id }) || state.assessments.contains(where: { $0.activityID == a.id }) {
            return w.unchanged(asOf: end)
        }
        guard a.sport == .run else { return w.finish(asOf: end, assessment: nil) }

        let matched = w.match(run)
        // Sessions missed on earlier days are handled as of the run's start, as
        // the morning call would have, but the session being run is not a slot
        // a missed one can take.
        w.missed(asOf: a.start, protecting: matched?.id)
        if let m = matched { w.plan.removeAll { $0.id == m.id } }
        let kind = matched?.kind ?? run.unplannedKind
        if let done = PlannedWorkout(activity: a, kind: kind) { w.history.append(done) }
        // A hard session named for another day sits where it was run, not where it was planned.
        if let m = matched, m.isHardDay, !w.calendar.isDate(m.date, inSameDayAs: a.start) {
            w.separateHardDays(session: m, ranAt: a.start, activityID: a.id)
        }

        let assessment = RunClassifier.assess(run, planned: matched, zones: context.zones, limits: context.limits,
                                               history: w.state.assessments, units: context.units)
        w.state.assessments.append(assessment)
        if kind.isQuality, let s = assessment.signal {
            w.state.qualitySignals.append(SignalRecord(activityID: a.id, date: a.start, signal: s, triggers: assessment.triggers))
        }
        // An unplanned run counts toward the zone-2 cap check only when its
        // heart rate shows it was easy: its kind is a default, not a plan.
        if kind == .easy || kind == .long || kind == .recovery, let hr = assessment.metrics.key?.heartRate,
           matched != nil || hr < context.zones.easyCeiling {
            w.state.easyHeartRates.append(EasyHeartRateRecord(activityID: a.id, date: a.start, heartRate: hr))
        }
        w.rule7Run(a, matched: matched)
        if kind == .long, let m = matched {
            w.state.longRuns.append(LongRunRecord(activityID: a.id, date: a.start, plannedSeconds: m.durationSeconds,
                                                  movingSeconds: assessment.metrics.movingSeconds,
                                                  decouplingPercent: assessment.metrics.decoupling?.percent,
                                                  averageHeartRate: assessment.metrics.key?.heartRate,
                                                  easyCeiling: context.zones.easyCeiling))
        }
        w.paceRules(asOf: end)
        w.easyCapRule()
        return w.finish(asOf: end, assessment: assessment)
    }

    /// - Parameter asOf: now; defaults to the check-in's own date.
    public static func processCheckIn(_ checkIn: PainCheckIn, state: AdaptationState, plan: [PlannedWorkout],
                                      history: [PlannedWorkout], asOf: Date? = nil,
                                      context: AdaptationContext) -> AdaptationOutcome {
        let now = max(checkIn.date, asOf ?? checkIn.date)
        var w = Work(state: state, plan: plan, history: history, context: context, asOf: now)
        w.record(checkIn)
        w.missed(asOf: now)
        w.evaluateCheckIns(asOf: now)
        w.rule7CheckIn(checkIn)
        return w.finish(asOf: now, assessment: nil)
    }

    /// A pain report from any runner, after any run or the next morning (3.5
    /// rule 7). A report with a valid score is also recorded as a pain
    /// check-in and runs the check-in rule (for runners who track pain), so the
    /// app can send one event for both. The same report delivered twice is a
    /// no-op; one with a non-finite date is ignored.
    /// - Parameter asOf: now; defaults to the report's own date.
    public static func processPainReport(_ report: PainReport, state: AdaptationState, plan: [PlannedWorkout],
                                         history: [PlannedWorkout], asOf: Date? = nil,
                                         context: AdaptationContext) -> AdaptationOutcome {
        var w = Work(state: state, plan: plan, history: history, context: context,
                     asOf: report.isValid ? max(report.date, asOf ?? report.date) : asOf)
        guard report.isValid else {
            if let now = asOf, now.timeIntervalSinceReferenceDate.isFinite { return w.finish(asOf: now, assessment: nil) }
            return w.unchanged(asOf: history.map(\.date).max() ?? .distantPast)
        }
        let now = max(report.date, asOf ?? report.date)
        if state.painReports.contains(report) { return w.unchanged(asOf: now) }
        w.state.painReports = (w.state.painReports + [report]).enumerated()
            .sorted { $0.element.date != $1.element.date ? $0.element.date < $1.element.date : $0.offset < $1.offset }
            .map(\.element)
        if let score = report.validScore { w.record(PainCheckIn(date: report.date, score: score)) }
        w.missed(asOf: now)
        if report.validScore != nil { w.evaluateCheckIns(asOf: now) }
        w.rule7Report(report)
        return w.finish(asOf: now, assessment: nil)
    }

    /// For a day with no run or check-in: picks up missed sessions, expired
    /// freezes and guardrail repairs. The app calls it each morning.
    public static func processDay(asOf: Date, state: AdaptationState, plan: [PlannedWorkout],
                                  history: [PlannedWorkout], context: AdaptationContext) -> AdaptationOutcome {
        var w = Work(state: state, plan: plan, history: history, context: context, asOf: asOf)
        return w.finish(asOf: asOf, assessment: nil)
    }

    static let qualityIntensities: Set<WorkoutIntensity> = [.steady, .threshold, .vo2max, .racePace]
    static let easyIntensities: Set<WorkoutIntensity> = [.easy, .recovery]

    struct Work {
        var state: AdaptationState
        var plan: [PlannedWorkout]
        var history: [PlannedWorkout]
        let context: AdaptationContext
        var changes: [PlanChange] = []
        var suggestClinician = false
        /// What rule 7 told the app on this event (see `PainCourseStatus`).
        var painNotes = PainEventNotes()
        /// The drop of the pain test run that `repairKeepingTestRun` made in this event, and its week (#144).
        var testRunDrop: (change: PlanChange, week: Date)?
        /// History and plan as the event handed them in, before any change:
        /// what a pain stop's ceiling reads recovery weeks from.
        let handedIn: [PlannedWorkout]

        var tz: TimeZone { context.timeZone }
        var limits: AdaptationLimits { context.limits }
        var calendar: Calendar { PlanCalendar.calendar(timeZone: tz) }
        func day(_ d: Date) -> String { PlanFormatting.day(d, timeZone: tz) }

        /// `asOf` is the event's time when known before the event is read: the
        /// snapshot (`PlanSnapshot`) lets the app drop sessions dated before its day.
        init(state: AdaptationState, plan: [PlannedWorkout], history: [PlannedWorkout], context: AdaptationContext,
             asOf: Date? = nil) {
            self.state = state
            self.plan = plan.sorted { $0.date < $1.date }
            self.history = history
            // F3's limit, no easy run longer than the week's long run, holds
            // for every plan the engine changes (3.5 rule 5, #54).
            var context = context
            context.guardrails.easyRunsWithinLongRun = true
            self.context = context
            self.handedIn = history + plan
            takeSnapshot(asOf: asOf)
        }

        // MARK: Matching

        /// The planned session a run was for: the one named, or the closest in
        /// time on the same local day (rest days excluded).
        func match(_ run: CompletedRun) -> PlannedWorkout? {
            if let id = run.plannedWorkoutID, let w = plan.first(where: { $0.id == id }) { return w }
            let start = run.activity.start
            return plan
                .filter { $0.kind != .rest && calendar.isDate($0.date, inSameDayAs: start) }
                .min { abs($0.date.timeIntervalSince(start)) < abs($1.date.timeIntervalSince(start)) }
        }

        // MARK: Hard days run on another day (F4, 3.5)

        /// `m`, a quality session or race, was run at `start` on another day
        /// than planned (the app named it with `plannedWorkoutID`). Adjacency
        /// is judged by the day it was actually run: a quality session still to
        /// come on that day or the next turns into an easy run of the same
        /// length, so two hard days never stack (F4 "never stack two quality
        /// days"; 3.5 "never on consecutive days"). It only lowers intensity and
        /// never adds load. A race is never changed, and a hard day already run
        /// the day before can't be undone, so neither is touched.
        mutating func separateHardDays(session m: PlannedWorkout, ranAt start: Date, activityID: String) {
            let runDay = calendar.startOfDay(for: start)
            for i in plan.indices where plan[i].kind.isQuality && plan[i].date >= runDay {
                let next = plan[i]
                let gap = calendar.dateComponents([.day], from: runDay, to: calendar.startOfDay(for: next.date)).day ?? 99
                guard gap <= 1 else { continue }
                let when = gap == 0 ? "the same day as" : "the day before"
                let trigger = TriggerMetric(
                    metric: .daysBetweenHardDays, value: Double(gap), expectedLow: 2, unit: .days, sourceID: activityID,
                    detail: "the \(describe(m.kind)) planned for \(day(m.date)) was run on \(day(start)), \(when) the \(describe(next.kind)) on \(day(next.date))")
                plan[i] = next.swappedToEasyKeepingTarget(
                    reason: "the \(describe(m.kind)) planned for \(day(m.date)) was run on \(day(start)), \(when) it (SPEC F4).")
                changes.append(PlanChange(
                    kind: .qualitySwappedToEasy, workoutIDs: [next.id], triggers: [trigger], rule: "SPEC F4, 3.5",
                    explanation: "You ran the \(describe(m.kind)) planned for \(day(m.date)) on \(day(start)), \(when) the \(describe(next.kind)) on \(day(next.date)). That session becomes an easy run of the same length so two hard days don't stack. (SPEC F4, 3.5.)"))
            }
        }

        // MARK: Pace rules (section 8)

        mutating func paceRules(asOf: Date) {
            let window = Array(state.qualitySignals.suffix(max(1, limits.signalWindow)))
            let need = max(1, limits.signalsToMove)
            let ahead = window.filter { $0.signal == .ahead }
            let behind = window.filter { $0.signal == .behind || $0.signal == .overreached }
            if ahead.count >= need {
                let factor = 1 - limits.paceStep
                let ids = scalePaces(Self.quality, factor, asOf: asOf)
                guard !ids.isEmpty else { return }   // nothing to move yet; keep the sessions for later
                state.qualityPaceFactor *= factor
                state.qualitySignals = []
                changes.append(PlanChange(
                    kind: .paceTargetsFaster, workoutIDs: ids, triggers: cite(ahead, of: window),
                    rule: "SPEC F4, section 8 (heuristic)",
                    explanation: "\(ahead.count) of your last \(window.count) quality sessions beat the target pace without heart rate rising above its band, so quality pace targets move \(AdaptationFormatting.percent(limits.paceStep)) faster on \(ids.count) upcoming \(ids.count == 1 ? "session" : "sessions"). (Heuristic, SPEC F4, section 8.)"))
            } else if behind.count >= need {
                let factor = 1 + limits.paceStep
                let ids = scalePaces(Self.quality, factor, asOf: asOf)
                if !ids.isEmpty { state.qualityPaceFactor *= factor }
                state.qualitySignals = []
                let triggers = cite(behind, of: window)
                if !ids.isEmpty {
                    changes.append(PlanChange(
                        kind: .paceTargetsSlower, workoutIDs: ids, triggers: triggers, rule: "SPEC F4, section 8 (heuristic)",
                        explanation: "\(behind.count) of your last \(window.count) quality sessions fell short of the target or showed strain, so quality pace targets move \(AdaptationFormatting.percent(limits.paceStep)) slower on \(ids.count) upcoming \(ids.count == 1 ? "session" : "sessions"). (Heuristic, SPEC F4, section 8.)"))
                }
                let end = calendar.date(byAdding: .day, value: limits.holdVolumeDays, to: asOf)
                    ?? asOf.addingTimeInterval(Double(limits.holdVolumeDays) * 86_400)
                let week = PlanCalendar.weekStart(containing: asOf, timeZone: tz)
                let all = history + plan
                guard let level = [week, shift(week, weeks: -1)].compactMap({ GuardrailRepair.weekVolume($0, all, context) }).max(),
                      level > 0 else { return }   // no known volume to hold at
                // The long-run floor: a share of the longest long run planned in
                // the held weeks or recently, fixed now so it never compounds.
                let longs = plan.filter { $0.kind == .long && $0.date < end && $0.date >= week }.map(\.durationSeconds)
                    + state.longRuns.suffix(max(1, limits.longRunReferenceRuns)).map(\.plannedSeconds)
                let floor = longs.max().map { $0 * limits.holdLongRunFloorShare }
                state.holds.append(VolumeHold(interval: DateInterval(start: asOf, end: end), level: level, longRunFloorSeconds: floor))
                changes.append(PlanChange(
                    kind: .volumeHeld, workoutIDs: [], triggers: triggers, rule: "SPEC F4, section 8 (heuristic)",
                    explanation: "Because \(behind.count) of your last \(window.count) quality sessions were behind or overreached, weekly volume stays at or below \(PlanFormatting.volume(level, context.guardrails.measure, units: context.units)) until \(day(end)). (Heuristic, SPEC section 8.)"))
            }
        }

        static let quality = AdaptationEngine.qualityIntensities

        /// Scales pace targets of the given intensities on every session to
        /// come except races. Returns the ids changed.
        ///
        /// A faster step (factor below 1) never takes a session in weeks 1 to
        /// 3 back from a break past its pre-break target: the paces it holds
        /// are the pre-break ones divided by the return factor already
        /// applied, so the step is limited to that (SPEC 3.5 rule 4, #28).
        mutating func scalePaces(_ intensities: Set<WorkoutIntensity>, _ factor: Double, asOf: Date = .distantPast) -> [String] {
            var ids: [String] = []
            let schedule = factor < 1 ? returnSchedule(asOf: asOf) : nil
            func step(_ w: PlannedWorkout) -> Double {
                guard let schedule, inReturnCap(schedule, on: w.date) else { return factor }
                return max(factor, w.prescription?.returnPaceFactor ?? 1)
            }
            for i in plan.indices where plan[i].kind != .race {
                let by = step(plan[i])
                if by < 1 || factor >= 1, let scaled = plan[i].scalingPaces(of: intensities, by: by) {
                    plan[i] = scaled
                    ids.append(scaled.id)
                }
            }
            // The original plan moves with it (section 8), so what grows back
            // keeps the paces in force.
            for i in state.planSnapshot.sessions.indices where state.planSnapshot.sessions[i].kind != .race {
                let by = step(state.planSnapshot.sessions[i])
                if by < 1 || factor >= 1, let scaled = state.planSnapshot.sessions[i].scalingPaces(of: intensities, by: by) {
                    state.planSnapshot.sessions[i] = scaled
                }
            }
            return ids
        }

        /// The signal count and each agreeing session's own trigger metrics.
        func cite(_ agreeing: [SignalRecord], of window: [SignalRecord]) -> [TriggerMetric] {
            let names = agreeing.map { "\($0.activityID) (\($0.signal.rawValue))" }.joined(separator: ", ")
            var out = [TriggerMetric(metric: .signalCount, value: Double(agreeing.count),
                                     expectedLow: Double(limits.signalsToMove), unit: .count,
                                     detail: "\(agreeing.count) of the last \(window.count) quality sessions agree: \(names)")]
            for r in agreeing { out += r.triggers }
            return out
        }

        // MARK: Easy runs above the zone-2 cap (section 8)

        mutating func easyCapRule() {
            let n = max(1, limits.easyRunsForCapCheck)
            let recent = Array(state.easyHeartRates.suffix(n))
            guard recent.count >= n else { return }
            let mean = recent.reduce(0) { $0 + $1.heartRate } / Double(n)
            let cap = context.zones.easyCeiling
            guard mean >= cap else { return }
            let factor = 1 + limits.paceStep
            let ids = scalePaces(AdaptationEngine.easyIntensities, factor)
            if !ids.isEmpty { state.easyPaceFactor *= factor }
            state.easyHeartRates = []
            var triggers = [TriggerMetric(metric: .heartRate, value: mean, expectedHigh: cap, unit: .bpm,
                                          detail: "mean heart rate \(AdaptationFormatting.bpm(mean)) over your last \(n) easy runs, at or above the zone-2 cap of \(AdaptationFormatting.bpm(cap))")]
            triggers += recent.map {
                TriggerMetric(metric: .heartRate, value: $0.heartRate, expectedHigh: cap, unit: .bpm, sourceID: $0.activityID,
                              detail: "easy run \($0.activityID) on \(day($0.date)): \(AdaptationFormatting.bpm($0.heartRate))")
            }
            let effect = ids.isEmpty
                ? "There are no easy pace targets to move; keep easy runs below \(AdaptationFormatting.bpm(cap)) by heart rate."
                : "Easy pace targets move \(AdaptationFormatting.percent(limits.paceStep)) slower on \(ids.count) upcoming \(ids.count == 1 ? "session" : "sessions"); heart rate still governs easy running."
            changes.append(PlanChange(kind: .easyPaceSlower, workoutIDs: ids, triggers: triggers,
                                      rule: "SPEC 3.1, 3.2, section 8",
                                      explanation: "Your easy runs have averaged above the top of zone 2, so they were not truly easy. \(effect) (SPEC 3.1, section 8.)"))
        }

        // MARK: Pain check-in (3.5)

        /// Stores a check-in, ordered by date and then score.
        mutating func record(_ checkIn: PainCheckIn) {
            state.painCheckIns = (state.painCheckIns + [checkIn]).sorted {
                $0.date != $1.date ? $0.date < $1.date : $0.score < $1.score
            }
        }

        /// Runs the check-in rule over every stored check-in.
        mutating func evaluateCheckIns(asOf now: Date) {
            // Check-ins at the same time are one report: keep the highest score,
            // so two at once (say 0 and 2) never read as a rise.
            var collapsed: [PainCheckIn] = []
            for c in state.painCheckIns {
                if let last = collapsed.last, last.date == c.date { collapsed[collapsed.count - 1] = c } else { collapsed.append(c) }
            }
            let outcome = PainCheckInRule.evaluate(tracksPain: context.tracksPain, checkIns: collapsed,
                                                   plan: history + plan, asOf: now,
                                                   lastAppliedCheckIn: state.lastAppliedCheckIn,
                                                   timeZone: context.timeZone, limits: context.painLimits)
            if case .act(let r) = outcome { apply(r) }
        }

        mutating func apply(_ r: PainResponse) {
            state.appliedPainResponse = r
            state.lastAppliedCheckIn = r.checkIn.date
            state.freezes.append(VolumeFreeze(interval: r.freeze, checkIn: r.checkIn.date))
            suggestClinician = suggestClinician || r.suggestClinician
            let triggers = painTriggers(r)
            changes.append(PlanChange(kind: .painVolumeFreeze, workoutIDs: [], triggers: triggers,
                                      rule: "SPEC 3.5 (heuristic), F9", explanation: r.explanation))
            if let swap = r.swap { swapForPain(swap.original.id, triggers: triggers, response: r) }
        }

        func painTriggers(_ r: PainResponse) -> [TriggerMetric] {
            var out = [TriggerMetric(metric: .painScore, value: Double(r.checkIn.score), expectedHigh: Double(context.painLimits.highScore - 1),
                                     unit: .painScore, detail: "pain \(r.checkIn.score)/10 on \(day(r.checkIn.date))")]
            for t in r.triggers {
                if case .rise(let previous, let rise) = t {
                    out.append(TriggerMetric(metric: .painRise, value: Double(rise), expectedHigh: Double(context.painLimits.minimumRise - 1),
                                             unit: .painScore, detail: "pain rose by \(rise) from \(previous)/10"))
                }
            }
            return out
        }

        /// Turns the quality session `id` into an easy run of the same length.
        /// From then on it is an easy run like any other: guardrail repair or a
        /// hold may trim or drop it, and nothing turns it back into quality.
        mutating func swapForPain(_ id: String, triggers: [TriggerMetric], response r: PainResponse) {
            guard let i = plan.firstIndex(where: { $0.id == id && $0.kind.isQuality }) else { return }
            let original = plan[i]
            plan[i] = original.swappedToEasyKeepingTarget(reason: "pain \(r.checkIn.score)/10 on \(day(r.checkIn.date)) (SPEC 3.5).")
            changes.append(PlanChange(
                kind: .qualitySwappedToEasy, workoutIDs: [id], triggers: triggers, rule: "SPEC 3.5 (heuristic), F9",
                explanation: "The \(describe(original.kind)) on \(day(original.date)) becomes an easy run of the same length after your pain check-in of \(r.checkIn.score)/10. This is a training adjustment, not a diagnosis. (Heuristic, SPEC 3.5.)"))
        }

        /// Keeps the applied response in force until its freeze ends: a plan
        /// handed back with the swapped session as quality again (a re-plan)
        /// gets the swap again.
        mutating func reEnforcePain(asOf: Date) {
            guard let r = state.appliedPainResponse, r.freezeEnd > asOf, let swap = r.swap,
                  plan.contains(where: { $0.id == swap.original.id && $0.kind.isQuality && $0.date >= asOf }) else { return }
            swapForPain(swap.original.id, triggers: painTriggers(r), response: r)
        }

        // MARK: Pain stop (3.5 rule 7)

        static let stopRule = "SPEC 3.5 rule 7 (heuristic), section 8"

        /// Starts a stop, or makes a standing one stricter, after `report`
        /// fired `fired` (`PainReport.stopTriggers(usual:hoursSinceRun:)`).
        mutating func painStopRule(_ report: PainReport, fired: [PainStopTrigger]) {
            let before = state.painStop
            guard report.isValid,
                  var after = PainStopRule.stop(fired: fired, at: report.date, current: before, limits: context.painStopLimits),
                  after != before else { return }
            if after.level == nil { after.level = stopLevel(since: after.since) }
            state.painStop = after
            guard before == nil || after.mode != before?.mode else { return }   // nothing new to say
            let what = after.mode == .rest
                ? "Running stops for now: every run to come becomes a rest day"
                : "Running stays easy for now: every quality session to come becomes an easy run of the same length"
            let ceiling = after.level.map { "stays at or below \(PlanFormatting.volume($0, context.guardrails.measure, units: context.units))" }
                ?? "won't grow"
            let race = plan.first { $0.kind == .race }.map {
                " The race on \(day($0.date)) stays in the plan as you set it."
            } ?? ""
            let opening = before == nil
                ? "You reported pain on \(day(report.date)) that \(fired.map(\.words).joined(separator: " and ")). Progression stops from \(day(after.since))."
                : "Progression has been stopped since \(day(after.since)), and on \(day(report.date)) you reported pain that \(fired.map(\.words).joined(separator: " and "))."
            changes.append(PlanChange(
                kind: .painStop, workoutIDs: [], triggers: stopTriggers(after, report: report), rule: Self.stopRule,
                explanation: "\(opening) \(what), and weekly volume \(ceiling) until the stop ends: 2 mornings in a row at or below your usual pain, walking pain at 2/10 or less, then a short easy test run that passes.\(race) This is a training adjustment, not a diagnosis. (Heuristic, SPEC 3.5 rule 7.)"))
        }

        /// The pre-stop weekly level: the higher of the known volumes of the
        /// week holding `since` and the week before it, races left out (3.5
        /// rule 3) and runs done from `since` on left out, so running more
        /// once stopped never raises it. When neither week has a known volume
        /// above 0, the first such week of the plan from the stop on (#72
        /// review). Nil when there is none.
        func stopLevel(since: Date) -> Double? {
            let week = PlanCalendar.weekStart(containing: since, timeZone: tz)
            // The test run is not part of the plan the level measures (3.5 rule 7).
            let test = state.painRecovery.test?.workoutID
            let all = history.filter { $0.date < since } + plan.filter { $0.id != test }
            let measure = context.guardrails.measure
            func held(_ w: Date) -> Double? {
                guard let total = GuardrailRepair.weekVolume(w, all, context) else { return nil }
                let races = all.filter { $0.kind == .race && PlanCalendar.weekStart(containing: $0.date, timeZone: tz) == w }
                    .reduce(0) { $0 + GuardrailRepair.volume($1, measure) }
                let v = total - races
                return v > 0 && v.isFinite ? v : nil
            }
            if let v = [week, shift(week, weeks: -1)].compactMap(held).max() { return v }
            let lastWeek = all.map(\.date).max().map { PlanCalendar.weekStart(containing: $0, timeZone: tz) } ?? week
            var w = shift(week, weeks: 1)
            while w <= lastWeek {
                if let v = held(w) { return v }
                w = shift(w, weeks: 1)
            }
            return nil
        }

        /// A pain stop's weekly ceiling in `week` from the fixed level `base`:
        /// the level, except in a recovery week of the plan as handed in to
        /// the event (at most `GuardrailLimits.recoveryWeekMaxRatio` of the
        /// week before), where it is the level times that ratio.
        ///
        /// In rest mode the ceiling is always the plain level. The plan handed
        /// in is then the stop's own shape (every run a rest day), so its
        /// weeks say nothing about the plan's recovery weeks: a week the stop
        /// emptied would read as a recovery week with a ceiling of 0, or near
        /// it, and drop the test run, the only way out of the stop (#108). And
        /// the plan a rest-mode stop leaves holds only the test run (and
        /// races, which the hold leaves out), so even the original plan's
        /// recovery-week share could only trim or drop the test run: there is
        /// no recovery week left for it to keep (#124). Heuristic, SPEC 3.5
        /// rule 7.
        func stopCeiling(_ week: Date, _ base: Double) -> Double {
            guard state.painStop?.mode != .rest else { return base }
            guard let cur = GuardrailRepair.weekVolume(week, handedIn, context),
                  let prev = GuardrailRepair.weekVolume(shift(week, weeks: -1), handedIn, context), prev > 0,
                  cur <= context.guardrails.recoveryWeekMaxRatio * prev * (1 + 1e-9) else { return base }
            return base * cur / prev
        }

        /// The stop's ceiling as a volume hold over every week from the stop's
        /// week to the end of the plan, leaving long runs to `enforcePainStop`
        /// (no floor); nil without a stop or a known level.
        func stopHold() -> VolumeHold? {
            guard let stop = state.painStop, let level = stop.level else { return nil }
            let start = PlanCalendar.weekStart(containing: stop.since, timeZone: tz)
            let last = (history + plan).map(\.date).filter { $0 >= start }.max() ?? start
            let end = shift(PlanCalendar.weekStart(containing: last, timeZone: tz), weeks: 1)
            return VolumeHold(interval: DateInterval(start: start, end: max(end, shift(start, weeks: 1))), level: level)
        }

        /// The stop's trigger metrics: how many triggers it has seen, with each named.
        func stopTriggers(_ stop: PainStop, report: PainReport? = nil) -> [TriggerMetric] {
            let since = day(stop.since)
            return [TriggerMetric(
                metric: .painStopTriggers, value: Double(stop.triggers.count), expectedHigh: 0, unit: .count,
                sourceID: report?.activityID,
                detail: "pain reported since \(since) that \(stop.triggers.map(\.words).joined(separator: " and "))\(report.map { "; latest report \(day($0.date))" } ?? "")")]
        }

        /// Keeps a standing stop in force on the plan: easy-only turns every
        /// quality session easy, rest turns every run into a rest day. Races
        /// are left alone. It only lowers load (the length is kept or dropped
        /// to nothing). A session already in the stop's shape is not touched,
        /// so a change is posted only when a plan handed back undoes it.
        mutating func enforcePainStop() {
            guard var stop = state.painStop else { return }
            if stop.level == nil, let level = stopLevel(since: stop.since) {
                stop.level = level
                state.painStop = stop
            }
            let triggers = stopTriggers(stop)
            let since = day(stop.since)
            let test = state.painRecovery.test?.workoutID
            for i in plan.indices where plan[i].id != test {   // the test run is how a stop ends (3.5 rule 7)
                let w = plan[i]
                switch stop.mode {
                case .easyOnly:
                    guard w.kind.isQuality else { continue }
                    plan[i] = w.swappedToEasyKeepingTarget(reason: "pain reported since \(since) (SPEC 3.5 rule 7).")
                    changes.append(PlanChange(
                        kind: .qualitySwappedToEasy, workoutIDs: [w.id], triggers: triggers, rule: Self.stopRule,
                        explanation: "The \(describe(w.kind)) on \(day(w.date)) becomes an easy run of the same length: progression has been stopped since \(since) after the pain you reported. This is a training adjustment, not a diagnosis. (Heuristic, SPEC 3.5 rule 7.)"))
                case .rest:
                    guard w.kind != .rest, w.kind != .race else { continue }
                    plan[i] = PlannedWorkout(id: w.id, date: w.date, kind: .rest, durationSeconds: 0)
                    changes.append(PlanChange(
                        kind: .sessionRested, workoutIDs: [w.id], triggers: triggers, rule: Self.stopRule,
                        explanation: "The \(describe(w.kind)) on \(day(w.date)) becomes a rest day: running has been stopped since \(since) after the pain you reported. This is a training adjustment, not a diagnosis. (Heuristic, SPEC 3.5 rule 7.)"))
                }
            }
            guard stop.mode == .easyOnly, let level = stop.level else { return }
            // Long runs fit the share cap of each week's ceiling (the held
            // level, or its recovery-week share) once, so the held weeks keep
            // them instead of the share guardrail trimming a little more each
            // week (heuristic, SPEC 3.5 rules 5 and 7). A cap that leaves less
            // than the easy-run floor makes the day an easy run at the floor,
            // or a rest day (`applyLongRunFloor`, #101).
            let measure = context.guardrails.measure
            let stopWeek = PlanCalendar.weekStart(containing: stop.since, timeZone: tz)
            for i in plan.indices where plan[i].kind == .long && plan[i].date >= stopWeek {
                let w = plan[i]
                let ceiling = stopCeiling(PlanCalendar.weekStart(containing: w.date, timeZone: tz), level)
                let cap = context.guardrails.maxLongRunShare * ceiling
                let held = PlanFormatting.volume(ceiling, measure, units: context.units)
                guard cap.isFinite, cap > 0, ceiling > 0 else { continue }
                guard let v = w.volume(measure), v > cap * (1 + 1e-9), w.durationSeconds.isFinite, w.durationSeconds > 0 else { continue }
                let seconds = (w.durationSeconds * cap / v / 60).rounded(.down) * 60
                let cited = triggers + [TriggerMetric(metric: .longRunShare, value: v / ceiling,
                                                      expectedHigh: context.guardrails.maxLongRunShare, unit: .fraction, sourceID: w.id,
                                                      detail: "the long run on \(day(w.date)) would be \(PlanFormatting.percent(v / ceiling)) of the held weekly level of \(held)")]
                if let floor = runFloorSeconds, seconds < floor {
                    applyLongRunFloor(at: i, cap: cap, capped: seconds, triggers: cited,
                                      reason: "while progression is stopped it has to fit the long-run share (\(PlanFormatting.percent(context.guardrails.maxLongRunShare))) of the held weekly level of \(held)",
                                      source: "SPEC 3.5 rules 5 and 7")
                    continue
                }
                guard seconds < w.durationSeconds else { continue }
                plan[i] = w.resized(toSeconds: seconds)
                changes.append(PlanChange(
                    kind: .sessionShortened, workoutIDs: [w.id],
                    triggers: cited,
                    rule: Self.stopRule,
                    explanation: "The long run on \(day(w.date)) is shortened to \(AdaptationFormatting.minutes(seconds)) so it fits the long-run share of the held weekly level of \(held) while progression is stopped. (Heuristic, SPEC 3.5 rules 5 and 7.)"))
            }
        }

        // MARK: Missed sessions (F4, section 8)

        mutating func missed(asOf: Date, protecting protected: String? = nil) {
            let today = calendar.startOfDay(for: asOf)
            let gone = plan.filter { $0.date < today && $0.id != protected }
            guard !gone.isEmpty else { return }
            plan.removeAll { $0.date < today && $0.id != protected }
            for m in gone where m.kind != .rest {
                let trigger = TriggerMetric(metric: .missedSession, value: m.durationSeconds, unit: .seconds, sourceID: m.id,
                                            detail: "planned \(describe(m.kind)) of \(AdaptationFormatting.minutes(m.durationSeconds)) on \(day(m.date)) was not run")
                if m.kind == .long || m.kind.isQuality, let slot = slot(for: m, today: today, protecting: protected) {
                    let replaced = plan[slot]
                    var moved = m
                    moved.date = replaced.date
                    plan[slot] = moved
                    changes.append(PlanChange(
                        kind: .sessionMoved, workoutIDs: [m.id, replaced.id], triggers: [trigger], rule: "SPEC F4, section 8",
                        explanation: "You missed the \(describe(m.kind)) on \(day(m.date)). It moves to \(day(replaced.date)) in place of the \(describe(replaced.kind)), the lowest-value session left this week, so the week is not crammed\(m.kind.isQuality ? " and no two quality days are back to back" : ""). (SPEC F4, section 8.)"))
                } else {
                    let why: String
                    if m.kind == .long || m.kind.isQuality {
                        // A race this week or on the Monday after it shapes what is left.
                        let week = PlanCalendar.weekStart(containing: m.date, timeZone: tz)
                        let after = addDays(1, to: shift(week, weeks: 1))
                        let race = (history + plan).first { $0.kind == .race && $0.date >= today && $0.date < after }
                        why = race.map { "The only days left this week it could take are on or next to the race on \(day($0.date)) or another hard day, so it is not made up: the race comes first." }
                            ?? "No lower-value session is left this week that it could replace without stacking hard days, so it is not made up."
                    } else {
                        why = "Easy running is the lowest-value session, so it is not made up."
                    }
                    changes.append(PlanChange(kind: .sessionDropped, workoutIDs: [m.id], triggers: [trigger], rule: "SPEC F4, section 8",
                                              explanation: "You missed the \(describe(m.kind)) on \(day(m.date)). \(why) (SPEC F4, section 8.)"))
                }
            }
        }

        /// Index of the session a missed long run or quality session replaces:
        /// the lowest-value one left in the same week (today or later), earliest
        /// first, never on or next to another hard day for a quality session.
        /// A long run prefers a day away from hard days but may sit next to one.
        func slot(for m: PlannedWorkout, today: Date, protecting protected: String?) -> Int? {
            let week = PlanCalendar.weekStart(containing: m.date, timeZone: tz)
            let candidates = plan.indices.filter {
                let w = plan[$0]
                return w.id != protected && w.date >= today && w.kind != .rest && w.adaptationValue < m.adaptationValue
                    && PlanCalendar.weekStart(containing: w.date, timeZone: tz) == week
            }.sorted { plan[$0].adaptationValue != plan[$1].adaptationValue
                ? plan[$0].adaptationValue < plan[$1].adaptationValue : plan[$0].date < plan[$1].date }
            func clear(_ i: Int) -> Bool {
                let d = calendar.startOfDay(for: plan[i].date)
                let hard = (history + plan.enumerated().filter { $0.offset != i }.map(\.element)).filter(\.isHardDay)
                return !hard.contains { h in
                    let diff = calendar.dateComponents([.day], from: d, to: calendar.startOfDay(for: h.date)).day ?? 0
                    return abs(diff) <= 1
                }
            }
            if let i = candidates.first(where: clear) { return i }
            // A long run may sit next to a quality day, never on or next to a race.
            return m.kind == .long ? candidates.first { !nearRace(plan[$0].date) } : nil
        }

        /// True when `date` is a race day or the day before or after one.
        func nearRace(_ date: Date) -> Bool {
            let d = calendar.startOfDay(for: date)
            return (history + plan).contains { r in
                r.kind == .race && abs(calendar.dateComponents([.day], from: d, to: calendar.startOfDay(for: r.date)).day ?? 99) <= 1
            }
        }

        // MARK: Long-run gate (3.3)

        mutating func longRunGate(asOf: Date) {
            let q = limits.longRunQualifyingCount
            guard q > 0, state.longRuns.count >= q,
                  let i = plan.indices.filter({ plan[$0].kind == .long && plan[$0].date >= asOf }).min(by: { plan[$0].date < plan[$1].date })
            else { return }
            let recent = Array(state.longRuns.suffix(q))
            // The level to progress from: the longest long run planned among the
            // last few, so a short recovery-week or trimmed long run does not
            // pull the next one down.
            let reference = state.longRuns.suffix(max(q, limits.longRunReferenceRuns)).map(\.plannedSeconds).max() ?? 0
            // Heuristic (SPEC 3.3, #170): a run with at most the decoupling
            // minimum of moving time (decoupling needs strictly more, the same
            // `DecouplingOptions` value `RunMetrics` measures with) is judged by
            // its own moving time, never by the plan's.
            let decouplingMinimum = DecouplingOptions.default.minimumMovingSeconds
            func tooShortForDecoupling(_ r: LongRunRecord) -> Bool { r.movingSeconds <= decouplingMinimum }
            func easyByHeartRate(_ r: LongRunRecord) -> Bool {
                guard let hr = r.averageHeartRate, let ceiling = r.easyCeiling, hr.isFinite, ceiling.isFinite else { return false }
                return hr < ceiling
            }
            func qualifies(_ r: LongRunRecord) -> Bool {
                guard r.movingSeconds >= limits.longRunCompletionShare * r.plannedSeconds else { return false }
                // Heuristic (SPEC 3.3, #170): a short run takes only the heart-rate
                // route; a longer one needs decoupling under the limit.
                if tooShortForDecoupling(r) { return easyByHeartRate(r) }
                return r.decouplingPercent.map { $0 < limits.longRunDecouplingLimit } ?? false
            }
            let open = recent.count >= q && recent.allSatisfy(qualifies)
            let allowed = open ? reference + limits.longRunStepSeconds : reference
            let next = plan[i]
            // A long run within the gate is left as planned, even under the
            // floor: nothing here shortens it, and a rest day would record no
            // long run, so the gate's level could never move again (#136).
            guard next.durationSeconds > allowed + 1e-6, allowed > 0 else { return }
            // When the allowance is under the easy-run floor (20 min, a product
            // heuristic), the long run is held at the allowance, never longer
            // than its plan, whether planned under, at or above the floor. It
            // is not raised to the floor (#121) or rested (#132), since a rest
            // day records no long run and the gate could never move (#136,
            // owner's decision, #159, SPEC 3.3). The 3.5 guardrails still
            // repair the plan after the gate.
            let floor = runFloorSeconds.flatMap { allowed < $0 - 1e-9 ? $0 : nil }
            let planned = "next long run planned at \(AdaptationFormatting.minutes(next.durationSeconds))"
            var triggers = [TriggerMetric(metric: .longRunDuration, value: next.durationSeconds, expectedHigh: allowed, unit: .seconds,
                                          sourceID: next.id,
                                          detail: floor.map { "\(planned); the gate allows at most \(AdaptationFormatting.minutes(allowed)), under the \(AdaptationFormatting.minutes($0)) floor" }
                                              ?? "\(planned); at most \(AdaptationFormatting.minutes(allowed)) allowed")]
            for r in recent {
                if tooShortForDecoupling(r) {
                    let ran = "long run \(r.activityID) on \(day(r.date)): \(AdaptationFormatting.minutes(r.movingSeconds)) of \(AdaptationFormatting.minutes(r.plannedSeconds)) planned"
                    if let hr = r.averageHeartRate, let ceiling = r.easyCeiling, hr.isFinite, ceiling.isFinite {
                        let verdict = easyByHeartRate(r) ? "below" : "at or above"
                        let unfinished = r.movingSeconds < limits.longRunCompletionShare * r.plannedSeconds ? ", but not finished" : ""
                        triggers.append(TriggerMetric(metric: .longRunDuration, value: r.movingSeconds,
                                                      expectedLow: limits.longRunCompletionShare * r.plannedSeconds, unit: .seconds,
                                                      sourceID: r.activityID,
                                                      detail: "\(ran); too short for a decoupling reading, so heart rate decides: average heart rate \(Int(hr.rounded())) bpm was \(verdict) the top of zone 2 (\(Int(ceiling.rounded())) bpm)\(unfinished)"))
                    } else {
                        triggers.append(TriggerMetric(metric: .longRunDuration, value: r.movingSeconds,
                                                      expectedLow: limits.longRunCompletionShare * r.plannedSeconds, unit: .seconds,
                                                      sourceID: r.activityID,
                                                      detail: "\(ran); too short for a decoupling reading, and no heart rate recorded"))
                    }
                } else if let d = r.decouplingPercent {
                    triggers.append(TriggerMetric(metric: .decoupling, value: d, expectedHigh: limits.longRunDecouplingLimit, unit: .percent,
                                                  sourceID: r.activityID,
                                                  detail: String(format: "long run %@ on %@: decoupling %.1f%% over %@ of %@ planned",
                                                                 r.activityID, day(r.date), d, AdaptationFormatting.minutes(r.movingSeconds),
                                                                 AdaptationFormatting.minutes(r.plannedSeconds))))
                } else {
                    triggers.append(TriggerMetric(metric: .longRunDuration, value: r.movingSeconds,
                                                  expectedLow: limits.longRunCompletionShare * r.plannedSeconds, unit: .seconds,
                                                  sourceID: r.activityID,
                                                  detail: "long run \(r.activityID) on \(day(r.date)): \(AdaptationFormatting.minutes(r.movingSeconds)) of \(AdaptationFormatting.minutes(r.plannedSeconds)) planned; decoupling could not be measured on a steady run"))
                }
            }
            let why = open
                ? "the step is limited to \(AdaptationFormatting.minutes(limits.longRunStepSeconds))"
                : "your last \(q == 1 ? "long run was" : "\(q) long runs were") not all completed at target duration with decoupling under \(Int(limits.longRunDecouplingLimit))% (or, for a run too short for decoupling, an average heart rate below the top of zone 2)"
            let gate = "Long runs progress only when decoupling stays under \(Int(limits.longRunDecouplingLimit))% at the target duration; a long run too short for a decoupling reading counts when its average heart rate stays below the top of zone 2 (heuristic)."
            plan[i] = next.resized(toSeconds: allowed)
            let held = "\(AdaptationFormatting.minutes(allowed)) instead of \(AdaptationFormatting.minutes(next.durationSeconds))"
            let explanation: String
            if let f = floor {
                explanation = "The long run on \(day(next.date)) stays at \(held): \(why), so it is held at \(AdaptationFormatting.minutes(allowed)), under the \(AdaptationFormatting.minutes(f)) floor, rather than raised to the floor or rested. \(gate) (SPEC 3.3, section 8; owner's decision, #159; the floor is a heuristic.)"
            } else {
                explanation = "The long run on \(day(next.date)) stays at \(held): \(why). \(gate) (SPEC 3.3.)"
            }
            changes.append(PlanChange(kind: .longRunHeld, workoutIDs: [next.id], triggers: triggers, rule: "SPEC 3.3, section 8",
                                      explanation: explanation))
        }

        func shift(_ d: Date, weeks: Int) -> Date { PlanCalendar.weekStart(weeks: weeks, after: d, timeZone: tz) }

        // MARK: Volume holds (section 8)

        /// Cuts sessions to come in each week overlapping a hold down to its
        /// level. A hold never cuts races or quality sessions, shortens a long
        /// run no further than its floor, and in a race week compares only the
        /// volume outside the race with the level. A week it can't bring down
        /// to the level, or whose volume is unknown, gets a `holdShortfall`
        /// change, and the result is false.
        ///
        /// A pain stop's ceiling (3.5 rule 7) runs here too, over every week
        /// from the stop's week on, after the volume holds. Its level is the
        /// fixed pre-stop level, except in easy-only mode in a recovery week of
        /// the plan as handed in to the event (`handedIn`, at most
        /// `GuardrailLimits.recoveryWeekMaxRatio` of the week before): there
        /// it is the level times that ratio, so the recovery week stays one
        /// and the recovery cadence never has to cut a build week instead. Once cut, the ratio to the held week before is
        /// the same, so the ceiling is stable from one event to the next.
        ///
        /// No hold cuts an offered pain test run: it is the only way out of a
        /// stop, and rule 7 fixes its size (20 to 30 minutes, or half the
        /// usual easy run), so trimming it would break that size and
        /// `PainTestRun.seconds`, and dropping it would only delay the stop's
        /// end. A week the test run keeps above a hold's level (unplanned runs
        /// already filled it) is a `holdShortfall` that says so (heuristic,
        /// SPEC 3.5 rule 7, #139).
        mutating func enforceHolds(asOf: Date, cutting: Bool = true) -> Bool {
            var satisfied = true
            let measure = context.guardrails.measure
            let test = state.painRecovery.test?.workoutID
            let unit: TriggerMetric.Unit = measure == .time ? .seconds : .meters
            let stop = stopHold()
            let returning = returnHolds()
            for hold in state.holds + (stop.map { [$0] } ?? []) + returning {
                let isStop = stop != nil && hold == stop
                let isReturn = !isStop && returning.contains(hold) && !state.holds.contains(hold)
                let rule = isStop || isReturn ? Self.stopRule : "SPEC F4, section 8 (heuristic)"
                let source = isStop || isReturn ? "SPEC 3.5 rule 7" : "SPEC section 8"
                var week = PlanCalendar.weekStart(containing: hold.interval.start, timeZone: tz)
                while week < hold.interval.end {
                    defer { week = shift(week, weeks: 1) }
                    guard shift(week, weeks: 1) > asOf else { continue }   // a finished week can't change
                    let ceiling = isStop ? stopCeiling(week, hold.level) : hold.level
                    func inWeek(_ w: PlannedWorkout) -> Bool { PlanCalendar.weekStart(containing: w.date, timeZone: tz) == week }
                    func held() -> Double? {
                        let all = history + plan
                        guard let total = GuardrailRepair.weekVolume(week, all, context) else { return nil }
                        return total - all.filter { $0.kind == .race && inWeek($0) }.reduce(0) { $0 + GuardrailRepair.volume($1, measure) }
                    }
                    let level = PlanFormatting.volume(ceiling, measure, units: context.units)
                    guard let v = held() else {
                        satisfied = false
                        // No volume was measured, so the trigger counts the
                        // sessions that can't be measured rather than citing one.
                        let unmeasured = (history + plan).filter { inWeek($0) && $0.volume(measure) == nil }
                        let what = measure == .time ? "duration" : "distance"
                        changes.append(PlanChange(
                            kind: .holdShortfall, workoutIDs: [],
                            triggers: [TriggerMetric(metric: .unmeasuredSessions, value: Double(unmeasured.count), expectedHigh: 0,
                                                     unit: .count, sourceID: unmeasured.first?.id,
                                                     detail: "the week of \(day(week)) has \(unmeasured.count == 1 ? "a session" : "\(unmeasured.count) sessions") with no known \(what) (\(unmeasured.map(\.id).joined(separator: ", "))), so its volume can't be compared with the held level of \(level)")],
                            rule: rule,
                            explanation: "Volume is held at \(level) a week, but the week of \(day(week)) can't be measured, so the hold can't be checked. (Heuristic, \(source).)"))
                        continue
                    }
                    guard v > ceiling * (1 + 1e-9) else { continue }
                    let race = (history + plan).contains { $0.kind == .race && inWeek($0) }
                    let trigger = TriggerMetric(metric: .weeklyVolume, value: v, expectedHigh: ceiling, unit: unit,
                                                detail: "the week of \(day(week)) plans \(PlanFormatting.volume(v, measure, units: context.units))\(race ? " outside the race" : ""), above the held level of \(level)")
                    let sessions = plan.indices.filter { plan[$0].date >= asOf && inWeek(plan[$0]) && plan[$0].id != test }
                    if cutting, let c = GuardrailRepair.cut(v - ceiling, sessions: sessions, longOnly: false, plan: plan,
                                                   longFloorSeconds: hold.longRunFloorSeconds ?? .infinity, context: context) {
                        plan = c.plan
                        changes += GuardrailRepair.changes(c, week: week, trigger: trigger, rule: rule,
                                                           reason: isStop ? "to keep weekly volume at the level before the pain stop (heuristic, SPEC 3.5 rule 7)."
                                                               : isReturn ? "to keep weekly volume within this step of the return after the pain stop (heuristic, SPEC 3.5 rules 4, 6 and 7)."
                                                               : "to hold volume after quality sessions pointed behind (heuristic, SPEC section 8).",
                                                           context: context)
                    }
                    let after = held() ?? v
                    let remainder = after - ceiling
                    guard remainder > max(1e-6, ceiling * 1e-9) else { continue }
                    satisfied = false
                    let keepsTest = plan.contains { $0.id == test && inWeek($0) && $0.date >= asOf }
                    changes.append(PlanChange(
                        kind: .holdShortfall, workoutIDs: [],
                        triggers: [trigger,
                                   TriggerMetric(metric: .weeklyVolume, value: after, expectedHigh: ceiling, unit: unit,
                                                 detail: "\(PlanFormatting.volume(remainder, measure, units: context.units)) remains above the held level after cutting what a hold may cut")],
                        rule: rule,
                            explanation: "Volume is held at \(level) a week, but the week of \(day(week)) still has \(PlanFormatting.volume(after, measure, units: context.units))\(race ? " outside the race" : ""), \(PlanFormatting.volume(remainder, measure, units: context.units)) over. A hold never cuts races\(keepsTest ? ", quality sessions or the test run that ends the pain stop" : " or quality sessions"), never drops a long run or shortens it below \(hold.longRunFloorSeconds.map { AdaptationFormatting.minutes($0) } ?? "its planned length"), and can't undo what is already run. (Heuristic, \(source).)"))
                }
            }
            return satisfied
        }

        // MARK: Finish

        mutating func finish(asOf: Date, assessment: RunAssessment?) -> AdaptationOutcome {
            missed(asOf: asOf)
            state.freezes = state.activeFreezes(at: asOf)
            state.holds = state.activeHolds(at: asOf)
            reEnforcePain(asOf: asOf)
            rule7Day(asOf: asOf)
            enforcePainStop()
            enforceReturn(asOf: asOf)
            longRunGate(asOf: asOf)
            let before = changes.count
            _ = enforceHolds(asOf: asOf)
            // Shortfalls are reported once, from the final plan below.
            changes = Array(changes[..<before]) + changes[before...].filter { $0.kind != .holdShortfall }
            var regrowth = regrowth(asOf: asOf)
            var repaired = repairKeepingTestRun(asOf: asOf, regrowth: regrowth)
            changes += repaired.changes
            // The weeks repair capped keep their time before the cap, for good (#54).
            state.preCap = repaired.preCap
            regrowth.preCap = repaired.preCap
            dedupeTestRunDrop()
            plan = repaired.plan.sorted { $0.date < $1.date }
            // Growing back to the original plan where the rules now allow it
            // (SPEC 3.5 rule 6, #64).
            if let grown = growBack(asOf: asOf, regrowth: regrowth, base: repaired.report) {
                plan = grown.plan
                changes += grown.changes
                repaired.report = grown.report
            }
            // Guardrail repair only cuts, so it can't break a hold; check the
            // holds on the final plan, cutting nothing more.
            var check = self
            check.changes = []
            let satisfied = check.enforceHolds(asOf: asOf, cutting: false)
            // A shortfall the previous event already found is not posted again.
            changes += check.changes.filter { !state.reportedHoldShortfalls.contains($0) }
            state.reportedHoldShortfalls = check.changes
            // The slower paces after a break (3.5 rule 4) go on before the plan is noted as returned.
            applyReturnPaces(asOf: asOf)
            noteReturned(asOf: asOf, regrowth: regrowth)
            return AdaptationOutcome(state: state, plan: plan, history: history,
                                     assessment: assessment, changes: changes, guardrailReport: repaired.report,
                                     suggestClinician: suggestClinician, holdsSatisfied: satisfied,
                                     lastingPain: lastingPain(asOf: asOf), painCourse: painStatus(asOf: asOf),
                                     regrowth: regrowth)
        }

        /// The outcome of an event that changes nothing (a run already seen):
        /// the same state, plan and history, no changes.
        ///
        /// While a pain stop stands, the plan handed in may not be in the
        /// stop's shape (a re-plan), so the event is finished like a quiet day
        /// instead: that only lowers load (3.5 rule 7).
        func unchanged(asOf: Date) -> AdaptationOutcome {
            if state.painStop != nil || state.painRecovery.painReturn != nil || state.painRecovery.flag != nil {
                var w = self
                return w.finish(asOf: asOf, assessment: nil)
            }
            var check = self
            let satisfied = check.enforceHolds(asOf: asOf, cutting: false)
            let regrowth = regrowth(asOf: asOf)
            let report = GuardrailChecker.check(history: history, planned: plan, timeZone: tz, limits: context.guardrails,
                                                freezes: state.freezeIntervals(at: asOf), units: context.units, regrowth: regrowth)
            check.noteReturned(asOf: asOf, regrowth: regrowth)
            return AdaptationOutcome(state: check.state, plan: plan, history: history, assessment: nil, changes: [],
                                     guardrailReport: report, suggestClinician: false, holdsSatisfied: satisfied,
                                     lastingPain: lastingPain(asOf: asOf), painCourse: painStatus(asOf: asOf),
                                     regrowth: regrowth)
        }

        /// Pain above usual on most days for about a week, from the reports
        /// after the latest clinician-flag stretch ended (3.5 rule 7).
        func lastingPain(asOf: Date) -> LastingPain? {
            PainStopRule.lastingPain(reports: state.painReports, checkIns: state.painCheckIns, asOf: asOf,
                                     timeZone: tz, usual: usualPain(), after: state.painRecovery.flagEnded?.date,
                                     limits: context.painStopLimits)
        }
    }

    static func describe(_ kind: PlannedWorkout.Kind) -> String {
        switch kind {
        case .easy: return "easy run"
        case .long: return "long run"
        case .recovery: return "recovery run"
        case .race: return "race"
        case .rest: return "rest day"
        case .quality(let q):
            switch q {
            case .tempo: return "tempo session"
            case .threshold: return "threshold session"
            case .intervals: return "interval session"
            case .hills: return "hill session"
            case .fartlek: return "fartlek"
            case .racePace: return "race-pace session"
            }
        }
    }
}

extension AdaptationEngine.Work {
    func describe(_ kind: PlannedWorkout.Kind) -> String { AdaptationEngine.describe(kind) }
}

extension AdaptationFormatting {
    static func percent(_ fraction: Double) -> String { PlanFormatting.percent(fraction) }
}
