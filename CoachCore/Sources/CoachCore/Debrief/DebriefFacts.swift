// TimeZone is not Sendable in swift-corelibs-foundation (Linux, Swift 5.10);
// @preconcurrency keeps DebriefFacts' Sendable conformance warning-free there.
@preconcurrency import Foundation

/// The facts a post-run debrief may state about one run (SPEC.md F6).
///
/// CoachCore computes every fact; the wording layer (`DebriefText`, or an LLM
/// handed these facts) only restates them. Each fact names the computed metric
/// it came from: `RunMetrics` and `RunAssessment` for pace, heart rate, drift
/// and cadence (F4, 3.3), `HRZones` for the zone (3.2), and the
/// `AdaptationOutcome` for what changes in the plan (F4).
///
/// A fact that can't be computed is left out, never guessed: no heart rate,
/// no cadence, a treadmill run, or a hilly run without usable altitude (pace
/// not compared; a hilly run with it is compared in grade-adjusted pace), a run too short
/// to read trends from, an unplanned run (no target), or a non-finite value.
public struct DebriefFacts: Equatable, Sendable {
    public let activityID: String
    public let facts: [DebriefFact]
    /// The runner's time zone, for days in the wording.
    public let timeZone: TimeZone

    public init(activityID: String, facts: [DebriefFact], timeZone: TimeZone) {
        self.activityID = activityID
        self.facts = facts
        self.timeZone = timeZone
    }

    public func fact(_ id: String) -> DebriefFact? { facts.first { $0.id == id } }

    /// Upper bound of `DecouplingClass.good` and of `.moderate` (SPEC 3.3, Friel).
    public static let decouplingGoodLimit = 5.0
    public static let decouplingHighLimit = 10.0

    /// Facts for a run the adaptation engine has processed.
    ///
    /// - Parameters:
    ///   - planned: the session the run was for, as planned before the run
    ///     (the engine removes it from the plan). Its targets are used only
    ///     when it is the session the outcome's assessment names; otherwise
    ///     the debrief states no target rather than compare with the wrong one.
    ///   - outcome: `AdaptationEngine.processRun`'s result for this run. Its
    ///     changes are "what changes this week".
    ///   - previousOutcome: the engine's outcome for the event before this
    ///     run. A `holdShortfall` is repeated on every event while it lasts,
    ///     so one already in the previous outcome is not stated again.
    public static func build(run: CompletedRun, planned: PlannedWorkout?, outcome: AdaptationOutcome?,
                             previousOutcome: AdaptationOutcome?, context: AdaptationContext,
                             heuristics: DebriefHeuristics = .default) -> DebriefFacts {
        make(run: run, planned: planned, zones: context.zones, timeZone: context.timeZone, limits: context.limits,
             measure: context.guardrails.measure, outcome: outcome, previousOutcome: previousOutcome,
             heuristics: heuristics)
    }

    /// Facts for a run without an adaptation outcome, for example before the
    /// runner has zones (cold start, section 2): no zone, band or plan change.
    public static func build(run: CompletedRun, planned: PlannedWorkout?, zones: HRZones?, timeZone: TimeZone,
                             limits: AdaptationLimits = .default,
                             heuristics: DebriefHeuristics = .default) -> DebriefFacts {
        make(run: run, planned: planned, zones: zones, timeZone: timeZone, limits: limits, measure: .time,
             outcome: nil, previousOutcome: nil, heuristics: heuristics)
    }

    // MARK: - Building

    static func make(run: CompletedRun, planned: PlannedWorkout?, zones: HRZones?, timeZone: TimeZone,
                     limits: AdaptationLimits, measure: VolumeMeasure, outcome: AdaptationOutcome?,
                     previousOutcome: AdaptationOutcome?, heuristics: DebriefHeuristics) -> DebriefFacts {
        let activity = run.activity
        guard activity.sport == .run else { return DebriefFacts(activityID: activity.id, facts: [], timeZone: timeZone) }

        // Prefer the engine's own reading of the run, so the debrief and the plan change agree.
        let fromOutcome = outcome?.assessment.flatMap { $0.activityID == activity.id ? $0 : nil }
        var session = planned
        if let a = fromOutcome, a.plannedWorkoutID != planned?.id { session = nil }
        let assessment = fromOutcome ?? zones.map { RunClassifier.assess(run, planned: session, zones: $0, limits: limits) }
        let m = assessment?.metrics ?? RunMetrics.measure(run, planned: session, limits: limits)
        let expected = session.flatMap { expectation($0, zones: zones) }
        let scope: DebriefScope = m.plannedKeySeconds == nil ? .afterWarmUp
            : (expected?.isContinuous ?? true) ? .mainPart : .reps

        var facts: [DebriefFact] = []

        // Time and distance.
        let samples = MovingTime.ordered(activity.samples).count
        var timeValue: DebriefValue?
        if samples >= 2, finitePositive(m.movingSeconds) {
            timeValue = DebriefValue(name: .movingTime, value: m.movingSeconds, unit: .seconds)
        } else if samples < 2, finitePositive(activity.durationSeconds) {
            timeValue = DebriefValue(name: .elapsedTime, value: activity.durationSeconds, unit: .seconds)
        }
        let distance = [activity.distanceMeters].compactMap { $0 }.first(where: finitePositive)
            ?? activity.samples.compactMap { StreamKind.distance.value(in: $0) }.filter(finitePositive).max()
        if let timeValue {
            var values = [timeValue]
            if let d = distance { values.append(DebriefValue(name: .distance, value: d, unit: .meters)) }
            // The kind of the session the engine matched, even when `planned` was not passed.
            let plannedKind = fromOutcome.map { $0.plannedWorkoutID == nil ? nil : $0.kind } ?? session?.kind
            facts.append(DebriefFact(id: "run", kind: .run(planned: plannedKind), values: values,
                                     source: "RunMetrics.movingSeconds, Activity.distanceMeters"))
        }
        let moving = m.movingSeconds.isFinite ? m.movingSeconds : 0
        let tooShort = moving > 0 && moving < heuristics.minimumMovingSeconds

        // Pace.
        let present = activity.presentStreams
        var missing: [DebriefStream] = [], patchy: [DebriefStream] = []
        func gap(_ s: DebriefStream, recorded: Bool) { if recorded { patchy.append(s) } else { missing.append(s) } }
        let keySpeed = m.key?.speed.flatMap { finitePositive($0) ? $0 : nil }
        if m.paceNotComparableReason != nil, let speed = keySpeed {
            if run.isTreadmill {
                facts.append(DebriefFact(id: "pace", kind: .paceNotCompared(.treadmill), values: [],
                                         source: "CompletedRun.isTreadmill (SPEC 3.8)"))
            } else if let gap = m.gradeAdjusted, finitePositive(gap.paceSecondsPerKm) {
                // Hilly: the same classifier and tolerance as a flat run, on grade-adjusted pace (F7 part 1).
                var values = [DebriefValue(name: .pace, value: gap.paceSecondsPerKm, unit: .secondsPerKm)]
                if let c = m.climbMetersPerKm, c.isFinite { values.append(DebriefValue(name: .climb, value: c, unit: .metersPerKm)) }
                var comparison: DebriefComparison?
                if let t = expected?.pace, finitePositive(t.fastestSecondsPerKm), finitePositive(t.slowestSecondsPerKm),
                   limits.paceTolerance.isFinite, limits.paceTolerance >= 0 {
                    values += [DebriefValue(name: .targetFastest, value: t.fastestSecondsPerKm, unit: .secondsPerKm),
                               DebriefValue(name: .targetSlowest, value: t.slowestSecondsPerKm, unit: .secondsPerKm),
                               DebriefValue(name: .paceTolerance, value: limits.paceTolerance, unit: .fraction)]
                    comparison = paceComparison(gap.paceSecondsPerKm, t, tolerance: limits.paceTolerance)
                }
                facts.append(DebriefFact(id: "pace", kind: .paceGradeAdjusted(scope), values: values, comparison: comparison,
                                         source: "RunMetrics.gradeAdjusted (RecordedGAP) against the planned PaceTarget (SPEC 3.6, F7)"))
            } else {
                var values = [DebriefValue(name: .pace, value: 1000 / speed, unit: .secondsPerKm)]
                if let c = m.climbMetersPerKm, c.isFinite { values.append(DebriefValue(name: .climb, value: c, unit: .metersPerKm)) }
                facts.append(DebriefFact(id: "pace", kind: .paceNotCompared(.hilly), values: values,
                                         source: "RunMetrics.key.speed, RunMetrics.climbMetersPerKm (SPEC 3.6)"))
            }
        } else if let pace = m.paceSecondsPerKm, finitePositive(pace) {
            var values = [DebriefValue(name: .pace, value: pace, unit: .secondsPerKm)]
            var comparison: DebriefComparison?
            if let t = expected?.pace, finitePositive(t.fastestSecondsPerKm), finitePositive(t.slowestSecondsPerKm),
               limits.paceTolerance.isFinite, limits.paceTolerance >= 0 {
                values += [DebriefValue(name: .targetFastest, value: t.fastestSecondsPerKm, unit: .secondsPerKm),
                           DebriefValue(name: .targetSlowest, value: t.slowestSecondsPerKm, unit: .secondsPerKm),
                           DebriefValue(name: .paceTolerance, value: limits.paceTolerance, unit: .fraction)]
                comparison = paceComparison(pace, t, tolerance: limits.paceTolerance)
            }
            facts.append(DebriefFact(id: "pace", kind: .pace(scope), values: values, comparison: comparison,
                                     source: "RunMetrics.paceSecondsPerKm against the planned PaceTarget"))
        } else if !run.isTreadmill, timeValue != nil {
            gap(.pace, recorded: present.contains(.speed))
        }

        if tooShort {
            facts.append(DebriefFact(id: "tooShort", kind: .tooShort, values: [
                DebriefValue(name: .movingTime, value: moving, unit: .seconds),
                DebriefValue(name: .minimumTime, value: heuristics.minimumMovingSeconds, unit: .seconds),
            ], comparison: .below, source: "RunMetrics.movingSeconds against DebriefHeuristics.minimumMovingSeconds"))
        } else if moving > 0 {
            // Heart rate.
            if let hr = m.key?.heartRate, hr.isFinite, RunMetrics.plausibleHeartRate.contains(hr) {
                var values = [DebriefValue(name: .heartRate, value: hr, unit: .bpm)]
                if let z = zones?.zone(for: hr) { values.append(DebriefValue(name: .zone, value: Double(z.rawValue), unit: .zone)) }
                var comparison: DebriefComparison?
                var source = "RunMetrics.key.heartRate against the planned HeartRateTarget and HRZones"
                // The band the classifier judged the run by (its floor falls back to
                // the top zone's lower bound when the target has none), so the
                // debrief and the engine agree; else the prescription's own band.
                let judged = session == nil ? nil
                    : assessment?.triggers.first { $0.metric == .heartRate && $0.sourceID == activity.id }
                if judged != nil { source = "RunMetrics.key.heartRate against the band in RunAssessment.triggers (heartRate) and HRZones" }
                let bandEnds: (Double?, Double?)? = judged.map { ($0.expectedLow, $0.expectedHigh) }
                    ?? expected.map { ($0.heartRate.floorBPM, $0.heartRate.ceilingBPM) }
                if let ends = bandEnds {
                    let floor = ends.0.flatMap { finitePositive($0) ? $0 : nil }
                    let ceiling = ends.1.flatMap { finitePositive($0) ? $0 : nil }
                    if let f = floor { values.append(DebriefValue(name: .bandFloor, value: f, unit: .bpm)) }
                    if let c = ceiling { values.append(DebriefValue(name: .bandCeiling, value: c, unit: .bpm)) }
                    if floor != nil || ceiling != nil {
                        if let c = ceiling, hr >= c { comparison = .above }
                        else if let f = floor, hr < f { comparison = .below }
                        else { comparison = .within }
                    }
                }
                facts.append(DebriefFact(id: "heartRate", kind: .heartRate(scope), values: values, comparison: comparison,
                                         source: source))
            } else {
                gap(.heartRate, recorded: present.contains(.heartRate))
            }

            // Drift (3.3): steady runs over 40 minutes only, as RunMetrics keeps it.
            if let d = m.decoupling ?? m.powerDecoupling, d.percent.isFinite {
                let cls = DecouplingClass(percent: d.percent)
                let comparison: DebriefComparison = cls == .good ? .below : cls == .moderate ? .within : .above
                facts.append(DebriefFact(id: "drift", kind: .decoupling(d.basis, cls), values: [
                    DebriefValue(name: .decoupling, value: d.percent, unit: .percent),
                    DebriefValue(name: .goodLimit, value: decouplingGoodLimit, unit: .percent),
                    DebriefValue(name: .highLimit, value: decouplingHighLimit, unit: .percent),
                ], comparison: comparison, source: d.basis == .pace ? "RunMetrics.decoupling" : "RunMetrics.powerDecoupling"))
            }

            // Cadence.
            if let c = m.key?.cadence, c.isFinite, heuristics.plausibleCadence.contains(c) {
                var values = [DebriefValue(name: .cadence, value: c, unit: .stepsPerMinute)]
                var comparison: DebriefComparison?
                if expected?.isContinuous ?? true, let fade = m.cadenceFadePercent, fade.isFinite,
                   limits.strainCadenceFadePercent.isFinite {
                    values += [DebriefValue(name: .cadenceFade, value: fade, unit: .percent),
                               DebriefValue(name: .fadeLimit, value: limits.strainCadenceFadePercent, unit: .percent)]
                    comparison = fade >= limits.strainCadenceFadePercent ? .above : .within
                }
                facts.append(DebriefFact(id: "cadence", kind: .cadence(scope), values: values, comparison: comparison,
                                         source: "RunMetrics.key.cadence, RunMetrics.cadenceFadePercent"))
            } else {
                gap(.cadence, recorded: present.contains(.cadence))
            }
        } else {
            // No moving time to read streams over.
            gap(.heartRate, recorded: present.contains(.heartRate))
            gap(.cadence, recorded: present.contains(.cadence))
        }
        if !missing.isEmpty {
            facts.append(DebriefFact(id: "missing", kind: .missing(missing), values: [], source: "Activity.presentStreams"))
        }
        if !patchy.isEmpty {
            facts.append(DebriefFact(id: "patchy", kind: .patchy(patchy), values: [],
                                     source: "RunMetrics.key coverage (RunMetrics.minimumCoverage)"))
        }

        // The engine's reading and what changes.
        if let s = assessment?.signal {
            facts.append(DebriefFact(id: "assessment", kind: .assessment(s), values: [], source: "RunAssessment.signal"))
        }
        if let outcome {
            facts += changeFacts(outcome, previous: previousOutcome, limits: limits, measure: measure, heuristics: heuristics)
        }
        return DebriefFacts(activityID: activity.id, facts: facts, timeZone: timeZone)
    }

    static func finitePositive(_ x: Double) -> Bool { x.isFinite && x > 0 }

    /// What the plan expected of the session's key part. With zones this is
    /// the classifier's own expectation; without them, the prescription's.
    static func expectation(_ w: PlannedWorkout, zones: HRZones?) -> RunClassifier.Expectation? {
        if let zones { return RunClassifier.expectation(w, zones: zones) }
        guard let p = w.prescription, let i = RunMetrics.keyIntensity(p),
              let seg = p.segments.first(where: { $0.intensity == i && RunMetrics.isKeyRole($0.role, intensity: i) })
        else { return nil }
        return RunClassifier.Expectation(intensity: i, heartRate: seg.target.heartRate, pace: seg.target.pace,
                                         isContinuous: p.segments.filter { $0.role == .work }.count <= 1)
    }

    /// Pace against the target the way the classifier judges it: inside the
    /// range, within `tolerance` of it, or faster (`below`) or slower (`above`).
    static func paceComparison(_ pace: Double, _ t: PaceTarget, tolerance: Double) -> DebriefComparison {
        if pace >= t.fastestSecondsPerKm && pace <= t.slowestSecondsPerKm { return .within }
        let d = pace < t.fastestSecondsPerKm ? pace / t.fastestSecondsPerKm - 1 : pace / t.slowestSecondsPerKm - 1
        if abs(d) <= tolerance { return .withinTolerance }
        return d < 0 ? .below : .above
    }

    // MARK: - Plan changes

    static func changeFacts(_ outcome: AdaptationOutcome, previous: AdaptationOutcome?, limits: AdaptationLimits,
                            measure: VolumeMeasure, heuristics: DebriefHeuristics) -> [DebriefFact] {
        // A shortfall already reported by the previous event says nothing new.
        let old = previous?.changes.filter { $0.kind == .holdShortfall } ?? []
        let changes = outcome.changes.filter { $0.kind != .holdShortfall || !old.contains($0) }
        guard !changes.isEmpty else {
            return [DebriefFact(id: "noChange", kind: .noChange, values: [], source: "AdaptationOutcome.changes")]
        }
        let volumeUnit: DebriefValue.Unit = measure == .time ? .seconds : .meters
        let kinds = PlanChange.Kind.allCases.filter { k in changes.contains { $0.kind == k } }
        var out: [DebriefFact] = []
        for kind in kinds {
            let group = changes.filter { $0.kind == kind }
            let ids = Set(group.flatMap(\.workoutIDs))
            var values: [DebriefValue] = []
            var comparison: DebriefComparison?
            func add(_ name: DebriefValue.Name, _ v: Double?, _ unit: DebriefValue.Unit) {
                if let v, v.isFinite { values.append(DebriefValue(name: name, value: v, unit: unit)) }
            }
            switch kind {
            case .paceTargetsFaster, .paceTargetsSlower:
                add(.paceStep, limits.paceStep, .fraction)
                add(.sessions, Double(ids.count), .count)
            case .volumeHeld:
                if let hold = outcome.state.holds.max(by: { $0.interval.start < $1.interval.start }) {
                    add(.heldLevel, hold.level, volumeUnit)
                    add(.holdEnd, hold.interval.end.timeIntervalSince1970, .date)
                }
            case .easyPaceSlower:
                if let t = group.first?.triggers.first(where: { $0.metric == .heartRate && $0.sourceID == nil }),
                   t.value.isFinite, let cap = t.expectedHigh, cap.isFinite {
                    add(.easyMeanHeartRate, t.value, .bpm)
                    add(.easyCap, cap, .bpm)
                    comparison = t.value >= cap ? .above : .within
                }
                add(.sessions, Double(ids.count), .count)
                if !ids.isEmpty { add(.paceStep, limits.paceStep, .fraction) }
            case .longRunHeld:
                if let c = group.first, let t = c.triggers.first(where: { $0.metric == .longRunDuration && $0.sourceID == c.workoutIDs.first }),
                   let allowed = t.expectedHigh {
                    add(.allowedTime, allowed, .seconds)
                    add(.plannedTime, t.value, .seconds)
                    if allowed.isFinite, t.value.isFinite { comparison = allowed < t.value ? .below : .within }
                }
            case .painVolumeFreeze:
                if let score = group.first?.triggers.first(where: { $0.metric == .painScore })?.value {
                    add(.painScore, score, .painScore)
                    add(.painScaleMax, Double(PainCheckIn.validScores.upperBound), .painScore)
                }
            case .returnPaces, .qualitySwappedToEasy, .longRunSwappedToEasy, .sessionShortened, .sessionRested, .sessionRegrown:
                add(.sessions, Double(ids.count), .count)
            case .painStop:
                if let stop = outcome.state.painStop { add(.stopSince, stop.since.timeIntervalSince1970, .date) }
            case .painTestRun, .painTestRunFailed, .painTestRunWithdrawn, .painTestRunRoom, .painStopEnded, .painReturnStep,
                 .painReturnRepeated:
                break
            case .sessionMoved, .sessionDropped:
                add(.sessions, Double(group.count), .count)
            case .holdShortfall:
                // Weeks measured over the level, and weeks whose volume is unknown (one trigger, no remainder).
                let overs = group.compactMap { c -> Double? in
                    guard c.triggers.count >= 2, let last = c.triggers.last, let level = last.expectedHigh else { return nil }
                    let r = last.value - level
                    return r.isFinite && r > 0 ? r : nil
                }
                let unknown = group.filter { $0.triggers.count < 2 }.count
                if !overs.isEmpty { add(.weeks, Double(overs.count), .count) }
                add(.overHeldLevel, overs.max(), volumeUnit)
                if unknown > 0 { add(.uncheckedWeeks, Double(unknown), .count) }
            }
            out.append(DebriefFact(id: "change.\(kind.rawValue)", kind: .change(kind), values: values, comparison: comparison,
                                   source: "AdaptationOutcome.changes (\(kind.rawValue))"))
        }
        let n = max(0, heuristics.maximumChangeClauses)
        if out.count > n {
            let rest = out[n...].compactMap { f -> Int? in
                guard case .change(let k) = f.kind else { return nil }
                return changes.filter { $0.kind == k }.count
            }.reduce(0, +)
            out = Array(out.prefix(n))
            out.append(DebriefFact(id: "moreChanges", kind: .moreChanges,
                                   values: [DebriefValue(name: .count, value: Double(rest), unit: .count)],
                                   source: "AdaptationOutcome.changes"))
        }
        return out
    }
}
