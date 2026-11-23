import Foundation

/// The runner's own zones the watch alerts are built from (SPEC.md F10, 3.2).
/// Nothing here has a default that stands for a particular runner: a value
/// left out means no data, and the matching alert is left out with a reason.
public struct WatchSyncZones: Equatable, Sendable {
    /// Heart-rate zones from the runner's LTHR. Nil when there is no LTHR
    /// yet: then no step gets a heart-rate alert.
    public var heartRate: HRZones?
    /// Running power (W) the runner holds in each heart-rate zone, measured
    /// from their own runs. A step gets a power range only when every zone it
    /// spans has a band here; empty means no power data.
    public var powerWattsByZone: [HRZone: ClosedRange<Double>]
    /// Cadence (steps/min) the runner holds in each heart-rate zone, measured
    /// from their own runs; same rules as `powerWattsByZone`.
    public var cadenceByZone: [HRZone: ClosedRange<Double>]

    public init(heartRate: HRZones?, powerWattsByZone: [HRZone: ClosedRange<Double>] = [:],
                cadenceByZone: [HRZone: ClosedRange<Double>] = [:]) {
        self.heartRate = heartRate
        self.powerWattsByZone = powerWattsByZone
        self.cadenceByZone = cadenceByZone
    }
}

/// Which alert a step gets. WorkoutKit takes one alert per step.
public enum WatchAlertPreference: Equatable, Hashable, Sendable {
    /// The plan's primary target for the step (heart rate or pace, SPEC 3.1:
    /// easy running by heart rate, harder work by pace when known), then the
    /// other of the two, then power, then cadence.
    case followPlan
    /// This metric whenever the step has a usable range for it, otherwise as `.followPlan`.
    case prefer(WatchAlertMetric)
}

public struct WatchSyncOptions: Equatable, Sendable {
    /// Days in the window, counting the first day (F10: two weeks). Values
    /// below 1 are treated as 1.
    public var days: Int
    /// The most workouts to send (WorkoutKit's
    /// `WorkoutScheduler.maxAllowedScheduledWorkoutCount`), or nil for no cap.
    /// The latest sessions are left out first.
    public var maxWorkouts: Int?
    public var alertPreference: WatchAlertPreference
    public var location: WatchWorkoutLocation
    /// How the purpose text reads (km or mi, `UnitPreference`); goals and
    /// alerts stay in SI units either way.
    public var units: UnitPreference

    public init(days: Int = WatchSyncHeuristics.windowDays, maxWorkouts: Int? = nil,
                alertPreference: WatchAlertPreference = .followPlan, location: WatchWorkoutLocation = .outdoor,
                units: UnitPreference = .metric) {
        self.days = days
        self.maxWorkouts = maxWorkouts
        self.alertPreference = alertPreference
        self.location = location
        self.units = units
    }
}

/// Constants of the watch mapping. All are heuristics, stated so they can be tuned.
public enum WatchSyncHeuristics {
    /// F10: the next two weeks.
    public static let windowDays = 14
    /// WorkoutKit heart-rate alerts are closed ranges, but an easy target has
    /// only a ceiling. Its floor is set this far down (a fraction of LTHR),
    /// below any running heart rate, so only the ceiling ever alerts.
    public static let openFloorFractionOfLTHR = 0.5
    /// Likewise for a target with only a floor (VO2max work): a ceiling above
    /// any heart rate the runner reaches, as a fraction of LTHR.
    public static let openCeilingFractionOfLTHR = 1.2
    /// Speed alerts watch the step's average: instantaneous GPS speed is noisy
    /// (SPEC F11), and an average suits repetitions of a few minutes.
    public static let speedAggregation: WatchAlertAggregation = .average
    /// Power responds at once and is not GPS-based, so power alerts watch the current value.
    public static let powerAggregation: WatchAlertAggregation = .current
}

/// Maps planned sessions to watch workouts for the Workout app (SPEC.md F10).
///
/// Pure and deterministic: the same plan, zones, date and time zone always
/// give the same batch, with the same ids. Every target comes from the plan
/// (`WorkoutPrescription`) and the runner's zones; nothing is guessed. An
/// alert the data can't support is left out and its reason recorded on the step.
///
/// Structure: a leading warm-up segment becomes the warm-up, a trailing
/// cool-down segment the cool-down, and the segments between become interval
/// blocks, with consecutive repeats of the same steps folded into one block
/// with iterations (so `rep, jog, rep, jog, rep` is `[rep, jog] × 2` then
/// `[rep] × 1`, exactly the planned time). Every step has a time goal, except
/// a race with a known distance, which runs to the distance.
///
/// Heart-rate ranges are recomputed from the runner's current zones using the
/// zones each target spans, so a new LTHR updates the alerts without a new
/// plan. A session with no prescription (for example one the adaptation
/// engine swapped to easy) becomes one timed step; easy, long and recovery
/// runs still get their heart-rate cap from the zones.
public enum WatchSyncMapper {
    /// The result of mapping one session.
    public enum Mapped: Equatable, Sendable {
        case workout(WatchWorkout)
        case skipped(WatchSyncSkip.Reason)
    }

    /// The workouts for the window starting on the day of `from` (in
    /// `timeZone`), covering `options.days` calendar days. Sessions of that
    /// first day that have already started by `from` are skipped
    /// (`startedBeforeNow`), so nothing is scheduled at a time in the past.
    public static func batch(for plan: TrainingPlan, zones: WatchSyncZones, from: Date, timeZone: TimeZone,
                             options: WatchSyncOptions = WatchSyncOptions()) -> WatchSyncBatch {
        batch(for: plan.workouts, zones: zones, from: from, timeZone: timeZone, options: options)
    }

    /// The same for any timeline of planned sessions (for example the plan
    /// after the adaptation engine changed it, F4).
    public static func batch(for sessions: [PlannedWorkout], zones: WatchSyncZones, from: Date, timeZone: TimeZone,
                             options: WatchSyncOptions = WatchSyncOptions()) -> WatchSyncBatch {
        let (start, end) = window(from: from, timeZone: timeZone, days: options.days)
        let inWindow = sessions
            .filter { $0.date >= start && $0.date < end }
            .sorted { $0.date != $1.date ? $0.date < $1.date : $0.id < $1.id }

        var workouts: [WatchWorkout] = []
        var skipped: [WatchSyncSkip] = []
        var seen = Set<String>()
        for s in inWindow {
            guard seen.insert(s.id).inserted else {
                skipped.append(WatchSyncSkip(sessionID: s.id, date: s.date, reason: .duplicateID))
                continue
            }
            if s.kind != .rest, WatchScheduleDate(s.date, timeZone: timeZone).hasStarted(by: from, timeZone: timeZone) {
                skipped.append(WatchSyncSkip(sessionID: s.id, date: s.date, reason: .startedBeforeNow))
                continue
            }
            switch workout(for: s, zones: zones, timeZone: timeZone, options: options) {
            case .workout(let w): workouts.append(w)
            case .skipped(let r): skipped.append(WatchSyncSkip(sessionID: s.id, date: s.date, reason: r))
            }
        }
        if let cap = options.maxWorkouts.map({ max(0, $0) }), workouts.count > cap {
            for w in workouts[cap...] {
                skipped.append(WatchSyncSkip(sessionID: w.sessionID, date: w.date, reason: .overScheduleLimit(limit: cap)))
            }
            workouts = Array(workouts[..<cap])
        }
        skipped.sort { $0.date != $1.date ? $0.date < $1.date : $0.sessionID < $1.sessionID }
        return WatchSyncBatch(from: from, windowStart: start, windowEnd: end, workouts: workouts, skipped: skipped)
    }

    /// Midnight on the day of `from` and midnight `days` days later, in `timeZone`.
    /// Uses calendar days, so a daylight-saving change doesn't move the edges.
    public static func window(from: Date, timeZone: TimeZone, days: Int = WatchSyncHeuristics.windowDays) -> (start: Date, end: Date) {
        let cal = PlanCalendar.calendar(timeZone: timeZone)
        let start = cal.startOfDay(for: from)
        let n = max(1, days)
        let end = cal.date(byAdding: .day, value: n, to: start) ?? start.addingTimeInterval(Double(n) * 86_400)
        return (start, end)
    }

    /// One session as a watch workout, or why it can't be one.
    public static func workout(for session: PlannedWorkout, zones: WatchSyncZones, timeZone: TimeZone,
                               options: WatchSyncOptions = WatchSyncOptions()) -> Mapped {
        if session.kind == .rest { return .skipped(.restDay) }
        let raceDistance: Double? = session.kind == .race ? session.distanceMeters.flatMap { valid($0) } : nil
        let segments = session.prescription?.segments ?? []
        let builder = StepBuilder(zones: zones, preference: options.alertPreference, kind: session.kind)

        var warmup: WatchStep?
        var cooldown: WatchStep?
        var blocks: [WatchIntervalBlock] = []
        if segments.isEmpty {
            let goal: WatchGoal
            if let d = raceDistance {
                goal = .distance(meters: d)
            } else if let t = valid(session.durationSeconds) {
                goal = .time(seconds: t)
            } else {
                return .skipped(.invalidDuration)
            }
            blocks = [WatchIntervalBlock(steps: [WatchIntervalStep(purpose: .work, step: builder.step(goal: goal, segment: nil))],
                                         iterations: 1)]
        } else {
            guard segments.allSatisfy({ valid($0.durationSeconds) != nil }) else { return .skipped(.invalidDuration) }
            // A lone segment is the run itself, whatever its role; with two or
            // more, a leading warm-up and a trailing cool-down are pulled out
            // (both, for a session that is only `[warmUp, coolDown]`).
            var middle = segments[...]
            if segments.count >= 2, let first = segments.first, first.role == .warmUp {
                warmup = builder.step(goal: .time(seconds: first.durationSeconds), segment: first)
                middle = middle.dropFirst()
            }
            if segments.count >= 2, let last = middle.last, last.role == .coolDown {
                cooldown = builder.step(goal: .time(seconds: last.durationSeconds), segment: last)
                middle = middle.dropLast()
            }
            // A race run to a distance: its single main segment becomes a distance goal.
            let distanceGoal = raceDistance != nil && middle.count == 1 ? raceDistance : nil
            blocks = fold(Array(middle)).map { pattern, iterations in
                let steps = pattern.map { seg -> WatchIntervalStep in
                    let goal: WatchGoal = distanceGoal.map { .distance(meters: $0) } ?? .time(seconds: seg.durationSeconds)
                    let purpose: WatchIntervalStep.Purpose = isRecovery(seg) ? .recovery : .work
                    return WatchIntervalStep(purpose: purpose, step: builder.step(goal: goal, segment: seg))
                }
                return WatchIntervalBlock(steps: steps, iterations: iterations)
            }
        }
        let w = WatchWorkout(id: WatchSyncID.uuid(forSessionID: session.id), sessionID: session.id, date: session.date,
                             scheduleDate: WatchScheduleDate(session.date, timeZone: timeZone),
                             displayName: displayName(session.kind), purpose: PlanFormatting.purpose(of: session, units: options.units),
                             location: options.location, warmup: warmup, blocks: blocks, cooldown: cooldown)
        return .workout(w)
    }

    /// Short workout name for the watch, from the session kind.
    public static func displayName(_ kind: PlannedWorkout.Kind) -> String {
        switch kind {
        case .easy: return "Easy run"
        case .long: return "Long run"
        case .recovery: return "Recovery run"
        case .race: return "Race"
        case .rest: return "Rest"
        case .quality(let q):
            switch q {
            case .tempo: return "Tempo"
            case .threshold: return "Threshold"
            case .intervals: return "Intervals"
            case .hills: return "Hills"
            case .fartlek: return "Fartlek"
            case .racePace: return "Race pace"
            }
        }
    }

    // MARK: Structure

    static func isRecovery(_ s: WorkoutSegment) -> Bool { s.role == .jog || s.intensity == .repRecovery }

    /// Folds consecutive repeats into (steps, iterations). At each position the
    /// repeat covering the most segments wins (ties: the shorter pattern);
    /// segments that don't repeat are gathered into one block run once.
    static func fold(_ segments: [WorkoutSegment]) -> [(pattern: [WorkoutSegment], iterations: Int)] {
        var out: [(pattern: [WorkoutSegment], iterations: Int)] = []
        var single: [WorkoutSegment] = []
        var i = 0
        while i < segments.count {
            var best: (length: Int, reps: Int)?
            let maxLength = (segments.count - i) / 2
            if maxLength >= 1 {
                for length in 1...maxLength {
                    let pattern = segments[i..<(i + length)]
                    var reps = 1
                    while i + (reps + 1) * length <= segments.count,
                          segments[(i + reps * length)..<(i + (reps + 1) * length)].elementsEqual(pattern) {
                        reps += 1
                    }
                    if reps >= 2, length * reps > (best.map { $0.length * $0.reps } ?? 0) { best = (length, reps) }
                }
            }
            if let b = best {
                if !single.isEmpty { out.append((single, 1)); single = [] }
                out.append((Array(segments[i..<(i + b.length)]), b.reps))
                i += b.length * b.reps
            } else {
                single.append(segments[i])
                i += 1
            }
        }
        if !single.isEmpty { out.append((single, 1)) }
        return out
    }

    static func valid(_ x: Double) -> Double? { x.isFinite && x > 0 ? x : nil }
}

/// Builds one step's goal and alert.
private struct StepBuilder {
    let zones: WatchSyncZones
    let preference: WatchAlertPreference
    let kind: PlannedWorkout.Kind

    /// The heart-rate zones a step spans and which ends are real limits.
    struct HRSpec {
        let span: ClosedRange<HRZone>
        let hasFloor: Bool
        let hasCeiling: Bool
    }

    func step(goal: WatchGoal, segment: WorkoutSegment?) -> WatchStep {
        let intensity = segment?.intensity
        if let segment, WatchSyncMapper.isRecovery(segment) {
            let omitted = WatchAlertMetric.allCases.map { WatchAlertOmission(metric: $0, reason: .recoveryStep) }
            return WatchStep(goal: goal, alert: nil, omittedAlerts: omitted, intensity: intensity)
        }
        let spec = hrSpec(segment)
        var candidates: [WatchAlertMetric: Result<WatchAlert, Omitted>] = [:]
        candidates[.heartRate] = heartRate(spec)
        candidates[.speed] = speed(segment?.target.pace)
        candidates[.power] = band(spec, data: zones.powerWattsByZone, metric: .power,
                                  aggregation: WatchSyncHeuristics.powerAggregation, missing: .noPowerData)
        candidates[.cadence] = band(spec, data: zones.cadenceByZone, metric: .cadence,
                                    aggregation: .current, missing: .noCadenceData)

        let primary: WatchAlertMetric = segment?.target.primary == .pace ? .speed : .heartRate
        var order: [WatchAlertMetric] = [primary, primary == .speed ? .heartRate : .speed, .power, .cadence]
        if case .prefer(let m) = preference { order = [m] + order.filter { $0 != m } }

        let chosen = order.first { if case .success = candidates[$0] { return true } else { return false } }
        var alert: WatchAlert?
        var omitted: [WatchAlertOmission] = []
        for m in WatchAlertMetric.allCases {
            switch candidates[m] {
            case .success(let a)? where m == chosen: alert = a
            case .success?: omitted.append(WatchAlertOmission(metric: m, reason: .oneAlertPerStep(chosen: chosen ?? m)))
            case .failure(let o)?: omitted.append(WatchAlertOmission(metric: m, reason: o.reason))
            case nil: break
            }
        }
        return WatchStep(goal: goal, alert: alert, omittedAlerts: omitted, intensity: intensity)
    }

    struct Omitted: Error { let reason: WatchAlertOmissionReason }

    /// From the segment's target; without one, from the session kind (easy
    /// running stays below the top of zone 2, SPEC 3.1, 3.2). Quality sessions
    /// and races without a prescription have no known effort.
    func hrSpec(_ segment: WorkoutSegment?) -> HRSpec? {
        if let t = segment?.target.heartRate {
            return HRSpec(span: t.zones, hasFloor: t.floorBPM != nil, hasCeiling: t.ceilingBPM != nil)
        }
        switch kind {
        case .easy, .long: return HRSpec(span: .z1 ... .z2, hasFloor: false, hasCeiling: true)
        case .recovery: return HRSpec(span: .z1 ... .z1, hasFloor: false, hasCeiling: true)
        case .quality, .race, .rest: return nil
        }
    }

    /// Whole bpm: from the floor rounded up to one below the (exclusive) ceiling.
    ///
    /// The range is rebuilt from the zones the target spans, not from its
    /// stored bpm, so it follows the runner's current LTHR. That relies on the
    /// plan's convention (`TargetModel.heartRate` in PlanHeuristics.swift): a
    /// floor is the lower bound of the span's lowest zone and a ceiling the
    /// lower bound of the zone just above the span. `WatchSyncMapperTests.
    /// testHeartRateRebuildMatchesThePlansZoneEdges` checks every intensity
    /// against it, so a change to that convention fails there.
    func heartRate(_ spec: HRSpec?) -> Result<WatchAlert, Omitted> {
        guard let spec else { return .failure(Omitted(reason: .noHeartRateTarget)) }
        guard let z = zones.heartRate else { return .failure(Omitted(reason: .noHeartRateZones)) }
        var low = spec.hasFloor ? z.lowerBound(spec.span.lowerBound) : 0
        if low <= 0 { low = WatchSyncHeuristics.openFloorFractionOfLTHR * z.lthr }
        let above = HRZone(rawValue: spec.span.upperBound.rawValue + 1)
        let high = spec.hasCeiling ? above.map { z.lowerBound($0) } : nil
        let ceiling = high ?? WatchSyncHeuristics.openCeilingFractionOfLTHR * z.lthr
        let lo = low.rounded(.up), hi = ceiling.rounded(.up) - 1
        guard lo.isFinite, hi.isFinite, lo > 0, lo < hi else { return .failure(Omitted(reason: .invalidRange)) }
        return .success(WatchAlert(metric: .heartRate, range: lo...hi, aggregation: .current))
    }

    /// Speed in m/s from a pace range in s/km.
    func speed(_ pace: PaceTarget?) -> Result<WatchAlert, Omitted> {
        guard let pace else { return .failure(Omitted(reason: .noPaceTarget)) }
        guard let fast = WatchSyncMapper.valid(pace.fastestSecondsPerKm),
              let slow = WatchSyncMapper.valid(pace.slowestSecondsPerKm) else {
            return .failure(Omitted(reason: .invalidRange))
        }
        let lo = 1000 / slow, hi = 1000 / fast
        guard lo.isFinite, hi.isFinite, lo > 0, lo < hi else { return .failure(Omitted(reason: .invalidRange)) }
        return .success(WatchAlert(metric: .speed, range: lo...hi, aggregation: WatchSyncHeuristics.speedAggregation))
    }

    /// The union of the runner's bands over every zone the step spans.
    /// Without a heart-rate target the step's zones are unknown, so the
    /// reason is that, not missing power or cadence data.
    func band(_ spec: HRSpec?, data: [HRZone: ClosedRange<Double>], metric: WatchAlertMetric,
              aggregation: WatchAlertAggregation, missing: WatchAlertOmissionReason) -> Result<WatchAlert, Omitted> {
        guard let spec else { return .failure(Omitted(reason: .noHeartRateTarget)) }
        let wanted = HRZone.allCases.filter { spec.span.contains($0) }
        let bands = wanted.compactMap { data[$0] }
        guard !wanted.isEmpty, bands.count == wanted.count else { return .failure(Omitted(reason: missing)) }
        guard bands.allSatisfy({ $0.lowerBound.isFinite && $0.upperBound.isFinite && $0.lowerBound > 0 }) else {
            return .failure(Omitted(reason: .invalidRange))
        }
        let lo = bands.map(\.lowerBound).min()!, hi = bands.map(\.upperBound).max()!
        guard lo < hi else { return .failure(Omitted(reason: .invalidRange)) }
        return .success(WatchAlert(metric: metric, range: lo...hi, aggregation: aggregation))
    }
}
