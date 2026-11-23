import Foundation

/// Tuning for `CueEngine`. **Every number is a heuristic** (SPEC.md F11 gives
/// ranges, not values); none stands for a particular runner.
public struct CueEngineConfig: Equatable, Sendable {
    /// A deviation must last this long before it is cued, and a return to
    /// the band must last this long before the engine counts the runner as
    /// back in it. F11 says "for example 20 to 30 seconds"; 25 s is the
    /// middle. It is the main defence against the pace estimate's lag and noise.
    public var sustainSeconds: Double = 25
    /// "Lasts" allows brief dips: within the sustained stretch (which must start
    /// and end with a reading on the deviating side) at least this share of the
    /// pace readings must be on that side. Heuristic: a smoothed estimate that carries
    /// correlated GPS error crosses a band edge for a second or two even when
    /// the runner is truly outside it, and a strict "every reading" rule would
    /// then miss real drifts (about half of 15 s/mile drifts in the replay).
    public var sustainFraction: Double = 0.8
    /// No cue in the first this-many seconds of a segment (F11: "never in the
    /// first 60 seconds of a rep"). Applied to every segment, not only reps,
    /// and the sustained window starts only after it. Spec value.
    public var startupSeconds: Double = 60
    /// Minimum seconds between any two cues. Heuristic: long enough to be
    /// heard and acted on, short enough not to feel ignored.
    public var minimumGapSeconds: Double = 30
    /// A runner who stays out of the band (or over the ceiling) is cued again
    /// after this many seconds. Heuristic.
    public var repeatSeconds: Double = 60
    /// Hysteresis margin: to count as outside the band the pace must pass
    /// the band edge by this fraction of the edge pace (the *leaving* edge is
    /// that far outside the band), but the runner counts as back in only at the
    /// band edge itself, so the two edges differ by this margin. 0.005 is about
    /// 2.7 s/mile at 8:50/mile. Heuristic.
    public var leaveMarginFraction: Double = 0.005
    /// The live grade carries altitude noise, so the band is widened to cover
    /// the grades within this much (as a fraction, 0.005 = half a percentage
    /// point) of the smoothed grade: the slow edge uses f(g + this), the fast
    /// edge f(g - this) (the wider of that and f(g)). Heuristic.
    public var gradeUncertainty: Double = 0.005
    /// While the smoothed grade has moved by more than `gradeChangeHold` in
    /// the last this-many seconds, the terrain is changing: the live grade and
    /// the pace estimate both lag a hill's start or end, so pace deviations are
    /// not counted then (cues already owed still go out). Heuristic: this is
    /// what keeps false "speed up" cues on rolling hills below one per mile.
    public var gradeChangeWindowSeconds: Double = 30
    /// The grade change (fraction, 0.02 = 2 percentage points) that counts as
    /// the terrain changing. Heuristic.
    public var gradeChangeHold: Double = 0.02
    /// Heart-rate hysteresis: after going over the ceiling, HR must fall this
    /// many bpm below it (for the sustained window) to count as back under.
    /// Heuristic.
    public var heartRateReentryMarginBPM: Double = 3
    /// **Pending owner decision #83.** While the smoothed grade is below this
    /// (a small negative fraction), "speed up" is never cued; only "slow down"
    /// and "ease off" are. Heuristic placeholder for the conservative option.
    public var descentGradeThreshold: Double = -0.02
    /// A pace or grade estimate older than this many seconds is ignored.
    /// Heuristic.
    public var maxEstimateAgeSeconds: Double = 10
    /// Settings for the pace estimator the engine owns.
    public var pace = PaceEstimatorConfig()
    /// Settings for the live grade estimator the engine owns.
    public var grade = GradeEstimatorConfig()

    public init() {}
}

/// The voice coach's decision logic (SPEC.md F11): for the active
/// `WorkoutSegment`, at each reading, say nothing, "speed up", "slow down" or
/// "ease off". Deterministic: the same readings always give the same decisions.
/// No LLM; the only words are the fixed phrases of `CueAction`.
///
/// **Rules**
/// - The pace band is the segment's `PaceTarget` times the grade factor
///   `f(grade)` (3.6; flat targets, f = 1, when the live grade is nil, which
///   every decision's reason reports as `usedFlatFallback`).
/// - Easy and recovery segments, and any segment whose target is heart-rate
///   primary, hold the HR ceiling: HR above `HeartRateTarget.ceilingBPM`
///   (strictly above, as the brief words it) for the sustained window cues
///   "ease off" even when pace is on target.
/// - "Speed up" is never cued on a heart-rate-primary segment. A pace band
///   on such a segment still cues "slow down" when the runner is faster.
/// - **Pending owner decision #83:** "speed up" is never cued while the
///   smoothed grade is below `descentGradeThreshold`.
/// - A deviation is cued only after it has lasted `sustainSeconds` (brief
///   dips tolerated, see `sustainFraction`) and passed the band edge by
///   `leaveMarginFraction`; the return counts only after `sustainSeconds`
///   at the band edge itself (a Schmitt trigger), so a runner on a band edge
///   is not flip-flopped.
/// - The band is widened by `gradeUncertainty` of grade, and deviations are not
///   counted while the smoothed grade is changing (`gradeChangeWindowSeconds`),
///   because the live grade and the pace estimate lag a hill's start and end.
/// - Nothing in the first `startupSeconds` of a segment, and at least
///   `minimumGapSeconds` between cues. A deviation that goes on is cued again
///   every `repeatSeconds`.
/// - Missing, NaN, stale or stopped inputs give no cue and restart the
///   sustained windows (continuity cannot be confirmed).
///
/// The engine owns a `PaceEstimator` and a `GradeEstimator`; feed readings to
/// `ingest(_:)`. `evaluate(time:pace:grade:heartRate:)` is the same decision
/// from already-smoothed inputs, for callers and tests that have their own.
public struct CueEngine: Sendable {
    public let config: CueEngineConfig
    public private(set) var segment: WorkoutSegment?
    /// The estimator's latest pace estimate.
    public var paceEstimate: PaceEstimate? { paceEstimator.estimate }
    /// The latest smoothed grade; nil when altitude is missing.
    public private(set) var gradeEstimate: GradeEstimate?

    private let curve: any GradePaceCurve
    private var paceEstimator: PaceEstimator
    private var gradeEstimator: GradeEstimator
    private var distance = 0.0
    private var lastIngestTime: Double?

    private enum Side { case inBand, tooSlow, tooFast }

    /// The latest readings, each with the value it voted for.
    private struct Window<Value: Equatable> {
        var samples: [(time: Double, value: Value)] = []

        mutating func clear() { samples.removeAll() }

        mutating func add(_ time: Double, _ value: Value, keep: Double) {
            samples.append((time, value))
            samples.removeAll { time - $0.time > keep }
        }

        /// The latest reading's value and how long it has been "held": the
        /// longest stretch ending now that starts with a reading of that value
        /// and in which at least `fraction` of the readings have it (brief dips
        /// are tolerated, but the stretch cannot start with one).
        func held(now: Double, fraction: Double) -> (value: Value, seconds: Double)? {
            guard let last = samples.last else { return nil }
            var agree = 0, total = 0
            var start = last.time
            for s in samples.reversed() {
                total += 1
                if s.value == last.value {
                    agree += 1
                    if Double(agree) >= fraction * Double(total) { start = s.time }
                }
            }
            return (last.value, now - start)
        }
    }

    private var gradeHistory: [(time: Double, grade: Double)] = []
    private var segmentStart = 0.0
    private var lastTime: Double?
    private var lastCue: Double?

    private var paceSide = Side.inBand
    private var paceWindow = Window<Side>()
    private var paceOwed: CueAction?
    private var lastPaceCue: Double?

    private var hrOver = false
    private var hrWindow = Window<Bool>()
    private var hrOwed = false
    private var lastHRCue: Double?

    public init(segment: WorkoutSegment? = nil, startTime: Double = 0, config: CueEngineConfig = CueEngineConfig(),
                curve: any GradePaceCurve = DefaultGradePaceCurve()) {
        self.config = config
        self.curve = curve
        self.segment = segment
        self.segmentStart = startTime
        self.paceEstimator = PaceEstimator(config: config.pace)
        self.gradeEstimator = GradeEstimator(config: config.grade)
    }

    /// Make `segment` the active one from `time`: the startup window and the
    /// deviation windows restart. The minimum gap since the last cue carries
    /// over, and so do the pace and grade estimators.
    public mutating func startSegment(_ segment: WorkoutSegment, at time: Double) {
        self.segment = segment
        segmentStart = time.isFinite ? time : segmentStart
        resetTracking()
    }

    /// Take one watch reading: update the pace and grade estimates, then decide.
    public mutating func ingest(_ r: LiveReading) -> CueDecision {
        let est = paceEstimator.ingest(r)
        if r.time.isFinite, lastIngestTime.map({ r.time > $0 }) ?? true {
            if let e = est, let last = lastIngestTime, e.speed.isFinite {
                distance += e.speed * min(max(r.time - last, 0), 5)
            }
            lastIngestTime = r.time
            gradeEstimate = gradeEstimator.ingest(time: r.time, distance: distance, altitude: r.altitude)
        }
        return evaluate(time: r.time, pace: est, grade: gradeEstimate, heartRate: r.heartRate)
    }

    /// Decide from a smoothed pace estimate, a smoothed grade (nil: flat) and
    /// the heart rate, at `time`. Times must increase; a reading not after
    /// the previous one gives `.invalidInput` and changes nothing.
    public mutating func evaluate(time: Double, pace: PaceEstimate?, grade: GradeEstimate?,
                                  heartRate: Double?) -> CueDecision {
        let cfg = config
        guard time.isFinite, lastTime.map({ time > $0 }) ?? true else {
            return CueDecision(time: time.isFinite ? time : (lastTime ?? 0), action: .none,
                               reason: CueReason(rule: .invalidInput))
        }
        lastTime = time
        let seg = time - segmentStart
        let keep = cfg.sustainSeconds + 1.5

        // Inputs, validated.
        let gradeValue: Double? = grade.flatMap { g in
            g.grade.isFinite && time - g.time <= cfg.maxEstimateAgeSeconds ? g.grade : nil
        }
        let f = gradeValue.map { sanitized(curve.factor(grade: $0)) } ?? 1
        gradeHistory.removeAll { time - $0.time > cfg.gradeChangeWindowSeconds }
        if let g = gradeValue { gradeHistory.append((time, g)) }
        var gradeChanging = false
        if let first = gradeHistory.first {
            var lo = first.grade, hi = first.grade
            for h in gradeHistory { lo = min(lo, h.grade); hi = max(hi, h.grade) }
            gradeChanging = hi - lo > cfg.gradeChangeHold
        }
        let target = segment?.target
        // The nominal band (segment target times f) and the wider one the
        // decisions use (see `gradeUncertainty`).
        let bands: (nominal: (fast: Double, slow: Double), wide: (fast: Double, slow: Double))? =
            target?.pace.flatMap { p in
                guard p.fastestSecondsPerKm.isFinite, p.slowestSecondsPerKm.isFinite,
                      p.fastestSecondsPerKm > 0 else { return nil }
                let fHigh = gradeValue.map { sanitized(curve.factor(grade: $0 + cfg.gradeUncertainty)) } ?? 1
                let fLow = gradeValue.map { sanitized(curve.factor(grade: $0 - cfg.gradeUncertainty)) } ?? 1
                return ((p.fastestSecondsPerKm * f, p.slowestSecondsPerKm * f),
                        (p.fastestSecondsPerKm * min(f, fLow), p.slowestSecondsPerKm * max(f, fHigh)))
            }
        let band = bands?.wide
        let paceValue: Double? = pace.flatMap { e in
            guard e.speed.isFinite, time - e.time <= cfg.maxEstimateAgeSeconds, let p = e.secondsPerKm,
                  p.isFinite, p > 0 else { return nil }
            return p
        }
        let hr: Double? = heartRate.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let hrPrimary = target?.primary == .heartRate
        let usesHRCeiling = (segment?.intensity.isBelowAerobicThreshold ?? false) || hrPrimary
        let ceiling: Double? = usesHRCeiling ? target?.heartRate.ceilingBPM.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } : nil

        func reason(_ rule: CueReason.Rule, deviation: Double? = nil) -> CueReason {
            CueReason(rule: rule, paceSecondsPerKm: paceValue, bandFastestSecondsPerKm: bands?.nominal.fast,
                      bandSlowestSecondsPerKm: bands?.nominal.slow,
                      fastTriggerSecondsPerKm: band.map { $0.fast * (1 - cfg.leaveMarginFraction) },
                      slowTriggerSecondsPerKm: band.map { $0.slow * (1 + cfg.leaveMarginFraction) },
                      grade: gradeValue, gradeFactor: f,
                      usedFlatFallback: gradeValue == nil, heartRate: hr, heartRateCeiling: ceiling,
                      deviationSeconds: deviation, segmentSeconds: seg)
        }
        func none(_ rule: CueReason.Rule, deviation: Double? = nil) -> CueDecision {
            CueDecision(time: time, action: .none, reason: reason(rule, deviation: deviation))
        }

        if band == nil && ceiling == nil { resetTracking(); return none(.noTarget) }
        if seg < cfg.startupSeconds { resetTracking(); return none(.startupWindow) }

        // Pace band.
        var blockedRule: CueReason.Rule?
        var paceFiredSeconds: Double?
        var paceHeld: (value: Side, seconds: Double)?
        if let b = band, let p = paceValue, !gradeChanging {
            let slowLeave = b.slow * (1 + cfg.leaveMarginFraction)
            let fastLeave = b.fast * (1 - cfg.leaveMarginFraction)
            let slowThreshold = paceSide == .tooSlow ? b.slow : slowLeave
            let fastThreshold = paceSide == .tooFast ? b.fast : fastLeave
            var observed = Side.inBand
            if p > slowThreshold { observed = .tooSlow } else if p < fastThreshold { observed = .tooFast }
            if observed == .tooSlow {
                if hrPrimary {
                    blockedRule = .heartRatePrimaryNoSpeedUp
                } else if let g = gradeValue, g < cfg.descentGradeThreshold {
                    blockedRule = .descentNoSpeedUp  // pending owner decision #83
                }
                if blockedRule != nil { observed = .inBand }
            }
            paceWindow.add(time, observed, keep: keep)
            paceHeld = paceWindow.held(now: time, fraction: cfg.sustainFraction)
            if let held = paceHeld, held.seconds >= cfg.sustainSeconds {
                let side = held.value
                if side != paceSide {
                    paceFiredSeconds = held.seconds
                    paceSide = side
                    paceHeld = nil
                    paceWindow.clear()
                    paceOwed = side == .tooSlow ? .speedUp : (side == .tooFast ? .slowDown : nil)
                } else if side != .inBand, lastPaceCue.map({ time - $0 >= cfg.repeatSeconds }) ?? true {
                    paceFiredSeconds = held.seconds
                    paceOwed = side == .tooSlow ? .speedUp : .slowDown
                }
            }
        } else {
            // Not judged this reading (no estimate, or the terrain is changing):
            // continuity cannot be confirmed, so the sustained window starts again.
            paceWindow.clear()
        }

        // Heart-rate ceiling.
        var hrFiredSeconds: Double?
        var hrHeld: (value: Bool, seconds: Double)?
        if let c = ceiling, let h = hr {
            let threshold = hrOver ? c - cfg.heartRateReentryMarginBPM : c
            hrWindow.add(time, h > threshold, keep: keep)
            hrHeld = hrWindow.held(now: time, fraction: cfg.sustainFraction)
            if let held = hrHeld, held.seconds >= cfg.sustainSeconds {
                let over = held.value
                if over != hrOver {
                    hrFiredSeconds = held.seconds
                    hrOver = over
                    hrHeld = nil
                    hrWindow.clear()
                    hrOwed = over
                } else if over, h > c, lastHRCue.map({ time - $0 >= cfg.repeatSeconds }) ?? true {
                    hrFiredSeconds = held.seconds
                    hrOwed = true
                }
            }
        } else {
            hrWindow.clear()
        }

        if (band == nil || paceValue == nil) && (ceiling == nil || hr == nil) {
            return none(.insufficientData)
        }
        if paceSide == .inBand { paceOwed = nil }
        if !hrOver { hrOwed = false }

        // Fire, subject to the minimum gap. Heart rate first.
        let gapOK = lastCue.map { time - $0 >= cfg.minimumGapSeconds } ?? true
        if gapOK {
            if hrOwed {
                hrOwed = false
                lastCue = time
                lastHRCue = time
                if paceOwed != nil { paceOwed = nil; lastPaceCue = time }
                return CueDecision(time: time, action: .easeOff,
                                   reason: reason(.sustainedHeartRateOverCeiling, deviation: hrFiredSeconds ?? cfg.sustainSeconds))
            }
            if let action = paceOwed {
                paceOwed = nil
                lastCue = time
                lastPaceCue = time
                return CueDecision(time: time, action: action,
                                   reason: reason(action == .speedUp ? .sustainedTooSlow : .sustainedTooFast,
                                                  deviation: paceFiredSeconds ?? cfg.sustainSeconds))
            }
        } else if hrOwed || paceOwed != nil {
            return none(.minimumGap)
        }

        if let rule = blockedRule { return none(rule) }
        if gradeChanging && band != nil { return none(.gradeChanging) }
        if let held = paceHeld, held.value != paceSide {
            return none(held.value == .inBand ? .alreadyCued : .deviationPending, deviation: held.seconds)
        }
        if let held = hrHeld, held.value != hrOver {
            return none(held.value ? .deviationPending : .alreadyCued, deviation: held.seconds)
        }
        if paceSide != .inBand || hrOver { return none(.alreadyCued) }
        return none(.withinTarget)
    }

    private mutating func resetTracking() {
        paceSide = .inBand
        paceWindow.clear()
        paceOwed = nil
        hrOver = false
        hrWindow.clear()
        hrOwed = false
    }

    private func sanitized(_ factor: Double) -> Double { factor.isFinite && factor > 0 ? factor : 1 }
}
