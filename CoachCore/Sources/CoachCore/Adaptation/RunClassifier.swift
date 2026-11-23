import Foundation

/// The engine's reading of one run against its planned session (SPEC.md F4,
/// section 8 `classify(m, e)`).
public struct RunAssessment: Equatable, Sendable {
    public let activityID: String
    /// The planned session it was compared with, or nil for an unplanned run.
    public let plannedWorkoutID: String?
    public let kind: PlannedWorkout.Kind
    public let date: Date
    public let metrics: RunMetrics
    /// Nil when the run can't be judged; `unclassifiedReason` says why.
    public let signal: RunSignal?
    public let unclassifiedReason: String?
    /// The metrics the signal rests on (pace and heart rate against the
    /// target, then any strain markers), so a change built on it can cite them.
    public let triggers: [TriggerMetric]
}

/// Classifies a run as ahead, on track, behind or overreached. **Heuristics**
/// (SPEC.md F4, section 8; thresholds in `AdaptationLimits`):
///
/// - Pace is compared with the key segments' pace target, within
///   `paceTolerance`. Heart rate is placed against the target's band: below
///   its floor (or, for a band with no floor such as easy running, below the
///   top zone's lower bound), within, or at or above its ceiling.
/// - Strain markers: decoupling (pace or power) over `strainDecouplingPercent`
///   on a steady run; power-to-HR over the main part `powerToHeartRateDropPercent`
///   or more below the runner's own recent sessions of the same kind
///   (`powerToHeartRateBaseline`); a cadence fade of `strainCadenceFadePercent` or more on a
///   continuous session (not intervals, whose thirds mix reps and jogs); RPE
///   `strainRPEMargin` or more above the range expected for the intensity.
/// - **Overreached:** RPE `overreachedRPEMargin` above the expected range, or
///   heart rate above the band with a strain marker, or two strain markers.
/// - **Behind:** pace slower than the target with heart rate in or above the
///   band, or pace met only with heart rate above the band ("hitting pace at a
///   high HR means it is not", F4).
/// - **Ahead:** pace faster than the target, or on target with heart rate below
///   the band, and no strain marker and heart rate not above the band
///   ("beating pace at a low HR means fitness is ahead", F4).
/// - **On track:** otherwise.
/// - Not classified: no planned session, no target, pace or heart rate missing
///   or not comparable, the key part mostly not run, or pace slow at a low heart
///   rate (the runner ran easier than asked, which says nothing about fitness).
public enum RunClassifier {
    /// - Parameters:
    ///   - history: the runner's earlier assessments, for the power-to-HR
    ///     comparison (`powerToHeartRateBaseline`); empty skips it.
    ///   - units: how paces read in trigger details; the classification is the same in both.
    public static func assess(_ run: CompletedRun, planned: PlannedWorkout?, zones: HRZones,
                              limits: AdaptationLimits = .default, history: [RunAssessment] = [],
                              units: UnitPreference = .metric) -> RunAssessment {
        let m = RunMetrics.measure(run, planned: planned, limits: limits, units: units)
        let kind = planned?.kind ?? run.unplannedKind
        func result(_ signal: RunSignal?, _ reason: String?, _ triggers: [TriggerMetric]) -> RunAssessment {
            RunAssessment(activityID: run.activity.id, plannedWorkoutID: planned?.id, kind: kind, date: run.activity.start,
                          metrics: m, signal: signal, unclassifiedReason: signal == nil ? reason : nil, triggers: triggers)
        }
        guard let planned else { return result(nil, "no planned session to compare with", []) }
        guard let expected = expectation(planned, zones: zones) else {
            return result(nil, "the planned session has no target to compare with", [])
        }

        let id = run.activity.id
        var triggers: [TriggerMetric] = []
        var strain: [TriggerMetric] = []

        // Pace against the target.
        var paceDeviation: Double?
        if let pace = m.paceSecondsPerKm, let target = expected.pace {
            let d: Double
            if pace < target.fastestSecondsPerKm { d = pace / target.fastestSecondsPerKm - 1 }
            else if pace > target.slowestSecondsPerKm { d = pace / target.slowestSecondsPerKm - 1 }
            else { d = 0 }
            paceDeviation = d
            triggers.append(TriggerMetric(metric: .pace, value: pace, expectedLow: target.fastestSecondsPerKm,
                                          expectedHigh: target.slowestSecondsPerKm, unit: .secondsPerKm, sourceID: id,
                                          detail: "pace \(AdaptationFormatting.pace(pace, units)) against a target of \(AdaptationFormatting.paceRange(target, units))"))
        }

        // Heart rate against the band.
        enum Band { case below, within, above }
        var band: Band?
        if let hr = m.key?.heartRate {
            let low = expected.heartRate.floorBPM ?? zones.lowerBound(expected.heartRate.zones.upperBound)
            let high = expected.heartRate.ceilingBPM
            if let high, hr >= high { band = .above } else if hr < low { band = .below } else { band = .within }
            triggers.append(TriggerMetric(metric: .heartRate, value: hr, expectedLow: low, expectedHigh: high, unit: .bpm,
                                          sourceID: id, detail: "heart rate \(AdaptationFormatting.bpm(hr)) against \(AdaptationFormatting.bpmRange(low, high))"))
        }

        // Strain markers.
        for d in [m.decoupling, m.powerDecoupling].compactMap({ $0 }) where d.percent > limits.strainDecouplingPercent {
            strain.append(TriggerMetric(metric: d.basis == .pace ? .decoupling : .powerToHeartRate, value: d.percent,
                                        expectedHigh: limits.strainDecouplingPercent, unit: .percent, sourceID: id,
                                        detail: String(format: "%@ decoupling %.1f%% (over %.0f%% means above aerobic threshold, SPEC 3.3)",
                                                       d.basis == .pace ? "pace-to-HR" : "power-to-HR", d.percent, limits.strainDecouplingPercent)))
        }
        if let key = m.key, let ratio = powerToHeartRate(key),
           let base = powerToHeartRateBaseline(kind: planned.kind, before: run.activity.start, history: history, limits: limits) {
            let drop = (1 - ratio / base.mean) * 100
            if drop.isFinite, drop >= limits.powerToHeartRateDropPercent {
                strain.append(TriggerMetric(
                    metric: .powerToHeartRateDrop, value: drop, expectedHigh: limits.powerToHeartRateDropPercent, unit: .percent,
                    sourceID: id,
                    detail: String(format: "power-to-HR %.2f W/bpm over the main part, %.1f%% below your mean of %.2f over your last %ld sessions of this kind (heuristic)",
                                   ratio, drop, base.mean, base.count)))
            }
        }
        if let fade = m.cadenceFadePercent, expected.isContinuous, fade >= limits.strainCadenceFadePercent {
            strain.append(TriggerMetric(metric: .cadenceFade, value: fade, expectedHigh: limits.strainCadenceFadePercent,
                                        unit: .percent, sourceID: id,
                                        detail: String(format: "cadence fell %.1f%% from the first third to the final third", fade)))
        }
        // nil without an RPE: a run with none is never overreached on RPE, at any margin (#163).
        var rpeOver: Int?
        if let rpe = m.rpe {
            let range = expectedRPE(expected.intensity)
            let over = rpe - range.upperBound
            rpeOver = over
            let t = TriggerMetric(metric: .rpe, value: Double(rpe), expectedLow: Double(range.lowerBound),
                                  expectedHigh: Double(range.upperBound), unit: .rpe, sourceID: id,
                                  detail: "RPE \(rpe) against \(range.lowerBound) to \(range.upperBound) expected for this session")
            if over >= limits.strainRPEMargin { strain.append(t) } else { triggers.append(t) }
        }
        let all = triggers + strain

        if let over = rpeOver, over >= limits.overreachedRPEMargin { return result(.overreached, nil, all) }
        if band == .above, !strain.isEmpty { return result(.overreached, nil, all) }
        if strain.count >= 2 { return result(.overreached, nil, all) }

        if let share = m.key.map({ $0.seconds }), let plannedKey = m.plannedKeySeconds, plannedKey > 0,
           share < limits.minimumKeyShare * plannedKey {
            return result(nil, "the run covered too little of the session's main part to compare", all)
        }
        guard expected.pace != nil else { return result(nil, "the session has no pace target (heart rate governs it)", all) }
        guard let d = paceDeviation else {
            return result(nil, m.paceNotComparableReason ?? "no usable pace over the session's main part", all)
        }
        guard let band else { return result(nil, "no usable heart rate over the session's main part", all) }

        if d > limits.paceTolerance {
            if band == .below { return result(nil, "pace was slow at a low heart rate: the session was run easier than planned", all) }
            return result(.behind, nil, all)
        }
        if band == .above { return result(.behind, nil, all) }
        if strain.isEmpty, d < -limits.paceTolerance || band == .below { return result(.ahead, nil, all) }
        return result(.onTrack, nil, all)
    }

    /// Watts per beat over a stretch, nil without both means or when not finite and positive.
    static func powerToHeartRate(_ k: StreamMeans) -> Double? {
        guard let p = k.power, let hr = k.heartRate, p.isFinite, hr.isFinite, p > 0, hr > 0 else { return nil }
        let r = p / hr
        return r.isFinite && r > 0 ? r : nil
    }

    /// The runner's own power-to-HR level for a session kind (F4 "power-to-HR";
    /// a heuristic like Friel's efficiency factor, SPEC 3.3): the mean ratio
    /// over the main part of the most recent `powerHistoryRuns` planned
    /// sessions of the same kind in the `powerHistoryDays` before `date`. Only
    /// the same kind is compared, because power-to-HR differs with intensity.
    /// Nil with fewer than `powerHistoryMinimumRuns` such sessions. Heat (F8)
    /// is not accounted for yet.
    public static func powerToHeartRateBaseline(kind: PlannedWorkout.Kind, before date: Date, history: [RunAssessment],
                                                limits: AdaptationLimits = .default) -> (mean: Double, count: Int)? {
        let n = limits.powerHistoryRuns, need = max(1, limits.powerHistoryMinimumRuns)
        guard n > 0, limits.powerHistoryDays > 0 else { return nil }
        let earliest = date.addingTimeInterval(-Double(limits.powerHistoryDays) * 86_400)
        let ratios = history
            .filter { $0.plannedWorkoutID != nil && $0.kind == kind && $0.date < date && $0.date >= earliest }
            .sorted { $0.date < $1.date }
            .compactMap { $0.metrics.key.flatMap(powerToHeartRate) }
            .suffix(n)
        guard ratios.count >= need else { return nil }
        let mean = ratios.reduce(0, +) / Double(ratios.count)
        return mean.isFinite && mean > 0 ? (mean, ratios.count) : nil
    }

    struct Expectation {
        let intensity: WorkoutIntensity
        let heartRate: HeartRateTarget
        let pace: PaceTarget?
        /// One continuous effort (not reps), so cadence thirds are comparable.
        let isContinuous: Bool
    }

    /// What the plan expected of the session's key part.
    static func expectation(_ w: PlannedWorkout, zones: HRZones) -> Expectation? {
        if let p = w.prescription, let intensity = RunMetrics.keyIntensity(p),
           let seg = p.segments.first(where: { $0.intensity == intensity && RunMetrics.isKeyRole($0.role, intensity: intensity) }) {
            let reps = p.segments.filter { $0.role == .work }.count
            return Expectation(intensity: intensity, heartRate: seg.target.heartRate, pace: seg.target.pace,
                               isContinuous: reps <= 1)
        }
        switch w.kind {
        case .easy, .long, .recovery:
            // A session made elsewhere: easy by heart rate from the runner's zones (3.1, 3.2).
            return Expectation(intensity: .easy,
                               heartRate: HeartRateTarget(zones: .z1 ... .z2, floorBPM: nil, ceilingBPM: zones.easyCeiling),
                               pace: nil, isContinuous: true)
        case .quality, .race, .rest:
            return nil
        }
    }

    /// Heuristic RPE range (1 to 10) expected for an intensity.
    public static func expectedRPE(_ intensity: WorkoutIntensity) -> ClosedRange<Int> {
        switch intensity {
        case .recovery: return 1...3
        case .easy, .repRecovery: return 2...4
        case .steady: return 4...6
        case .threshold: return 6...8
        case .racePace: return 6...9
        case .vo2max: return 7...9
        case .race: return 8...10
        }
    }
}

/// Locale-free formatting for adaptation explanations.
enum AdaptationFormatting {
    /// "5:31/km" or "8:53/mi" (`UnitFormatting`).
    static func pace(_ secondsPerKm: Double, _ units: UnitPreference = .metric) -> String {
        UnitFormatting.pace(secondsPerKm, units)
    }

    /// "4:27 to 4:35/km" or "7:10 to 7:23/mi".
    static func paceRange(_ p: PaceTarget, _ units: UnitPreference = .metric) -> String {
        UnitFormatting.paceRange(p, units)
    }

    static func bpm(_ x: Double) -> String { "\(Int(x.rounded())) bpm" }

    static func bpmRange(_ low: Double, _ high: Double?) -> String {
        guard let high else { return "\(Int(low.rounded())) bpm or more" }
        return low > 0 ? "\(Int(low.rounded())) to \(Int(high.rounded())) bpm" : "below \(Int(high.rounded())) bpm"
    }

    static func minutes(_ seconds: Double) -> String { PlanFormatting.volume(seconds, .time) }
}
