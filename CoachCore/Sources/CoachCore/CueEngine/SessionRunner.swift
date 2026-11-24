import Foundation

/// Runs a `WorkoutPrescription` live (SPEC.md F11): tracks the active segment
/// by moving time, hands each segment to a `CueEngine`, and returns, at each
/// reading, the ordered list of things to say: the engine's pace or heart-rate
/// cue, segment starts ("rep 3 of 6" and its target), countdowns, rep splits,
/// interval summaries and the workout's end. Deterministic, no LLM; every
/// announcement carries its numbers (`Announcement.content`).
///
/// **Time.** Segments are time-based and run on *moving* time. Segment time
/// stops while the runner is paused (`pause(at:)`/`resume(at:)`, which the
/// watch calls on a workout pause) and, when
/// `SessionRunnerConfig.autoPauseWhenStopped`, while the pace estimate says the
/// runner is stopped. The engine and the pace estimator are fed a clock that
/// leaves explicit pauses out, so a pause inside a rep does not eat the rep's
/// 60-second no-cue startup window.
///
/// **Overrun (the runner keeps going past a segment's time).** The next segment
/// starts on time; the runner is never left in a finished rep until a press.
/// Heuristic, the safer default for a timed rep: a hard rep that runs on silently
/// would break the session's recovery and its intensity share (3.1). After the
/// last segment's time the workout is finished: the runner emits its end, and
/// later readings return nothing (no cues after the planned end).
/// A runner who wants more time ends the workout on the watch and keeps recording.
///
/// **One voice.** Each announcement has a priority (`AnnouncementPriority`).
/// A segment start or the workout's end is spoken at once, with the results
/// (split, summary) of the segment it closes after it, and drops anything waiting.
/// Otherwise at most one announcement is spoken per reading, and only if
/// `minimumGapSeconds` have passed since the last; the highest priority due goes
/// first, the others wait and are dropped when they go stale
/// (`droppedAnnouncements` logs them).
///
/// **Splits and summaries** come from the session's own estimates (the pace
/// and grade estimates the engine owns, the readings' heart rate), never the plan.
/// A `work` segment ends with a `RepSplit`. The last `work` segment of a block (a
/// run of work and jog segments) and any `main` or `finish` segment of at least
/// `minimumSummarySegmentSeconds` end with an `IntervalSummary`. Heart rate
/// skips the lag at the start of a segment, as `RunMetrics.key` does
/// (`min(300, d/4)` s on easy segments, `min(60, d/4)` s otherwise).
public struct SessionRunner: Sendable {
    public enum Phase: Equatable, Sendable {
        case notStarted
        case running
        case finished(SessionEnd.Reason)
    }

    public let prescription: WorkoutPrescription
    public let config: SessionRunnerConfig
    public private(set) var phase = Phase.notStarted
    public private(set) var isPaused = false
    /// Every rep split so far, in order.
    public private(set) var splits: [RepSplit] = []
    /// Every interval summary so far, in order.
    public private(set) var summaries: [IntervalSummary] = []
    /// Announcements that were due but never spoken (held back too long or
    /// replaced by a segment change), for tests and diagnostics.
    public private(set) var droppedAnnouncements: [Announcement] = []
    /// The `CueEngine`'s decision at the latest reading (before the runner
    /// applied priorities and the gap).
    public private(set) var lastDecision: CueDecision?
    /// Total moving seconds so far.
    public private(set) var movingSeconds = 0.0
    /// Moving seconds spent in the active segment.
    public private(set) var segmentSeconds = 0.0

    /// Index of the active segment in `prescription.segments`; nil before
    /// the first reading and after the end.
    public var activeSegmentIndex: Int? { phase == .running ? entries[active].index : nil }
    public var activeSegment: WorkoutSegment? { phase == .running ? entries[active].segment : nil }

    private struct Entry {
        let index: Int
        let segment: WorkoutSegment
        var block: Int?
        var repNumber: Int?
        var repCount: Int?
        var nextRepNumber: Int?
        var lastOfBlock = false
    }

    private struct Accumulator {
        var moving = 0.0
        var covered = 0.0
        var distance = 0.0
        var flat = 0.0
        var gradeSeconds = 0.0
        var hrSeconds = 0.0, hrSum = 0.0
        var firstHalfSeconds = 0.0, firstHalfSum = 0.0
        var secondHalfSeconds = 0.0, secondHalfSum = 0.0
    }

    private struct Sample {
        var speed: Double?
        var factor: Double?
        var heartRate: Double?
    }

    private struct Pending {
        var announcement: Announcement
        /// Latest clock value at which it may still be spoken.
        var expiry: Double
    }

    private struct SegmentResult {
        var moving: Double
        var coveredFraction: Double
        var gradeCoverage: Double
        var distance: Double?
        var pace: Double?
        var gradeAdjusted: Double?
        var heartRate: Double?
        var drift: Double?
    }

    private var entries: [Entry] = []
    private var engine: CueEngine
    private let curve: any GradePaceCurve
    private let maxEstimateAge: Double
    private var active = 0
    private var accumulator = Accumulator()
    private var clock = 0.0
    private var lastTime: Double?
    private var previousStopped = false
    private var lastMeasurement: Double?
    private var lastHeartRate: (value: Double, clock: Double)?
    private var pending: [Pending] = []
    private var lastSpoken: Double?
    private var points: [Double] = []
    private var blockSplits: [Int: [RepSplit]] = [:]
    private var blockSummarized: Set<Int> = []
    private let eps = 1e-9

    public init(prescription: WorkoutPrescription, config: SessionRunnerConfig = SessionRunnerConfig(),
                engineConfig: CueEngineConfig = CueEngineConfig(),
                curve: any GradePaceCurve = DefaultGradePaceCurve()) {
        self.prescription = prescription
        self.config = config
        self.curve = curve
        self.maxEstimateAge = engineConfig.maxEstimateAgeSeconds
        self.engine = CueEngine(segment: nil, startTime: 0, config: engineConfig, curve: curve)

        var list: [Entry] = []
        for (i, s) in prescription.segments.enumerated() where s.durationSeconds.isFinite && s.durationSeconds > 0 {
            list.append(Entry(index: i, segment: s))
        }
        // Blocks: a run of work and jog segments that starts with a work segment.
        var block = -1
        var inBlock = false
        for k in list.indices {
            switch list[k].segment.role {
            case .work:
                if !inBlock { block += 1; inBlock = true }
                list[k].block = block
            case .jog:
                if inBlock { list[k].block = block }
            default:
                inBlock = false
            }
        }
        if block >= 0 {
            for b in 0...block {
                let works = list.indices.filter { list[$0].block == b && list[$0].segment.role == .work }
                for (n, k) in works.enumerated() {
                    list[k].repNumber = n + 1
                    list[k].repCount = works.count
                    list[k].lastOfBlock = n == works.count - 1
                }
            }
        }
        for k in list.indices where list[k].segment.role == .jog && list[k].block != nil && k + 1 < list.count {
            let next = list[k + 1]
            if next.block == list[k].block, next.segment.role == .work { list[k].nextRepNumber = next.repNumber }
        }
        self.entries = list
    }

    // MARK: Readings

    /// Take one live reading and return what to say now, in order (usually
    /// nothing, rarely more than one thing; several only at a segment change).
    /// Readings that are not finite, not after the last one, or arrive while
    /// paused or after the end are ignored.
    @discardableResult
    public mutating func ingest(_ r: LiveReading) -> [Announcement] {
        guard r.time.isFinite, !isPaused else { return [] }
        if case .finished = phase { return [] }
        if let last = lastTime, r.time <= last { return [] }

        var group: [Announcement] = []
        let dt = lastTime.map { r.time - $0 } ?? 0
        if phase == .notStarted {
            guard !entries.isEmpty else { phase = .finished(.completed); return [] }
            phase = .running
            lastTime = r.time
            beginSegment(0, at: r.time, skipped: false, overshoot: 0, into: &group)
        }
        clock += dt
        lastTime = r.time

        var engineReading = r
        engineReading.time = clock
        let decision = engine.ingest(engineReading)
        lastDecision = decision

        if let h = r.heartRate, h.isFinite, h > 0 { lastHeartRate = (h, clock) }
        let hr: Double? = lastHeartRate.flatMap { clock - $0.clock <= maxEstimateAge ? $0.value : nil }
        var speed: Double?
        var stopped = false
        // The estimator coasts through a dropout and stamps the coasted estimate with the
        // reading's time, so staleness is judged from the last reading that held a measurement.
        if r.gpsSpeed.map({ $0.isFinite && $0 >= 0 }) ?? false || r.watchSpeed.map({ $0.isFinite && $0 >= 0 }) ?? false
            || r.cadence.map({ $0.isFinite && $0 > 0 }) ?? false { lastMeasurement = clock }
        if let e = engine.paceEstimate, e.speed.isFinite, let m = lastMeasurement, clock - m <= maxEstimateAge {
            if e.secondsPerKm != nil { speed = e.speed } else { stopped = true }
        }
        var factor: Double?
        if let g = engine.gradeEstimate, g.grade.isFinite, clock - g.time <= maxEstimateAge {
            let f = curve.factor(grade: g.grade)
            factor = f.isFinite && f > 0 ? f : 1
        }
        let autoPaused = config.autoPauseWhenStopped && stopped && previousStopped
        previousStopped = stopped

        advance(wall: dt, moving: autoPaused ? 0 : dt, sample: Sample(speed: speed, factor: factor, heartRate: hr),
                at: r.time, into: &group)

        if !group.isEmpty { return speakGroup(group, at: r.time) }
        guard phase == .running else { return [] }

        var due: [Pending] = []
        if decision.action != .none {
            due.append(Pending(announcement: Announcement(time: r.time, content: .cue(decision)),
                               expiry: clock + config.cueMaxDeferSeconds))
        }
        if let c = countdown(at: r.time) { due.append(c) }
        return schedule(due, at: r.time)
    }

    // MARK: Pause, skip, end

    /// The workout was paused at `time` (a time on the readings' clock). Time up
    /// to `time` counts; readings are ignored until `resume(at:)`. May return
    /// announcements if the pause point is past a segment's end.
    @discardableResult
    public mutating func pause(at time: Double) -> [Announcement] {
        guard phase == .running, !isPaused else { return [] }
        var group: [Announcement] = []
        creditUntil(time, into: &group)
        isPaused = true
        return speakGroup(group, at: time)
    }

    /// The workout resumed at `time`. Moving time continues from there.
    public mutating func resume(at time: Double) {
        guard phase == .running, isPaused else { return }
        isPaused = false
        previousStopped = false
        if time.isFinite, time > (lastTime ?? -.infinity) { lastTime = time }
    }

    /// The runner pressed skip: finish the active segment now (a rep skipped
    /// early gets a partial split) and start the next. Skipping the last segment
    /// ends the workout like `end(at:)`.
    @discardableResult
    public mutating func skipToNextSegment(at time: Double) -> [Announcement] {
        guard phase == .running else { return [] }
        let wasPaused = isPaused
        var group: [Announcement] = []
        creditUntil(time, into: &group)
        guard phase == .running else { return speakGroup(group, at: time) }
        if active + 1 >= entries.count {
            finishSegment(early: true, endedWorkout: true, into: &group)
            finishWorkout(.endedEarly, into: &group)
        } else {
            finishSegment(early: true, endedWorkout: false, into: &group)
            beginSegment(active + 1, at: time, skipped: true, overshoot: 0, into: &group)
        }
        if wasPaused {
            // Same as `resume(at:)`: the pause is not credited to the next segment. `clock`
            // did not advance while paused, so the engine's no-cue window is already intact.
            previousStopped = false
            if time.isFinite, time > (lastTime ?? -.infinity) { lastTime = time }
        }
        isPaused = false
        return speakGroup(group, at: time)
    }

    /// The runner ended the workout early: the active segment is closed (a rep
    /// gets a partial split), the block's summary covers the reps done so far,
    /// and the workout is finished.
    @discardableResult
    public mutating func end(at time: Double) -> [Announcement] {
        switch phase {
        case .finished: return []
        case .notStarted:
            phase = .finished(.endedEarly)
            return [Announcement(time: time, content: .sessionEnd(SessionEnd(reason: .endedEarly, movingSeconds: 0)))]
        case .running:
            var group: [Announcement] = []
            creditUntil(time, into: &group)
            if phase == .running {
                finishSegment(early: true, endedWorkout: true, into: &group)
                finishWorkout(.endedEarly, into: &group)
            }
            isPaused = false
            return speakGroup(group, at: time)
        }
    }

    // MARK: Time

    /// Move the clock to `time` with no reading (a button press or a pause).
    private mutating func creditUntil(_ time: Double, into group: inout [Announcement]) {
        guard time.isFinite, let last = lastTime, time > last, !isPaused else { return }
        let dt = time - last
        clock += dt
        lastTime = time
        advance(wall: dt, moving: dt, sample: Sample(), at: time, into: &group)
    }

    /// Advance segment time by `moving` seconds with one sample of data, closing
    /// every segment whose planned time is reached (the overshoot carries into the next).
    private mutating func advance(wall: Double, moving: Double, sample: Sample, at time: Double,
                                  into group: inout [Announcement]) {
        guard phase == .running else { return }
        var left = moving
        let credit = min(moving, config.maxCreditedGapSeconds)
        while phase == .running {
            let entry = entries[active]
            let room = entry.segment.durationSeconds - segmentSeconds
            let portion = min(left, max(room, 0))
            let scale = moving > 0 ? portion / moving : 0
            accumulate(portion: portion, covered: credit * scale, sample: sample, entry: entry)
            segmentSeconds += portion
            movingSeconds += portion
            left -= portion
            if segmentSeconds < entry.segment.durationSeconds - eps { break }
            finishSegment(early: false, endedWorkout: false, into: &group)
            if active + 1 >= entries.count {
                finishWorkout(.completed, into: &group)
                break
            }
            beginSegment(active + 1, at: time, skipped: false, overshoot: left, into: &group)
            if left <= eps { break }
        }
    }

    private func lag(of segment: WorkoutSegment) -> Double {
        let d = segment.durationSeconds
        return segment.intensity.isBelowAerobicThreshold ? min(300, d / 4) : min(60, d / 4)
    }

    private mutating func accumulate(portion: Double, covered: Double, sample: Sample, entry: Entry) {
        guard portion > 0 else { return }
        accumulator.moving += portion
        if let v = sample.speed, covered > 0 {
            accumulator.covered += covered
            accumulator.distance += v * covered
            accumulator.flat += v * (sample.factor ?? 1) * covered
            if sample.factor != nil { accumulator.gradeSeconds += covered }
        }
        let elapsedAfter = segmentSeconds + portion
        if let h = sample.heartRate, elapsedAfter > lag(of: entry.segment) {
            accumulator.hrSeconds += portion
            accumulator.hrSum += h * portion
            if elapsedAfter <= entry.segment.durationSeconds / 2 {
                accumulator.firstHalfSeconds += portion
                accumulator.firstHalfSum += h * portion
            } else {
                accumulator.secondHalfSeconds += portion
                accumulator.secondHalfSum += h * portion
            }
        }
    }

    // MARK: Segments

    private mutating func beginSegment(_ k: Int, at time: Double, skipped: Bool, overshoot: Double,
                                       into group: inout [Announcement]) {
        active = k
        segmentSeconds = 0
        accumulator = Accumulator()
        let entry = entries[k]
        engine.startSegment(entry.segment, at: clock - max(overshoot, 0))
        let d = entry.segment.durationSeconds
        points = []
        let eligible = entry.segment.role == .work || (entry.segment.role == .jog && entry.nextRepNumber != nil)
        if eligible {
            points = config.countdownSeconds.filter {
                $0.isFinite && $0 > 0 && d - $0 >= config.minimumElapsedBeforeCountdownSeconds
            }.sorted(by: >)
        }
        let start = SegmentStart(segmentIndex: entry.index, role: entry.segment.role, intensity: entry.segment.intensity,
                                 durationSeconds: d, repNumber: entry.repNumber, repCount: entry.repCount,
                                 target: entry.segment.target, startedBySkip: skipped)
        group.append(Announcement(time: time, content: .segmentStart(start)))
    }

    private mutating func finishWorkout(_ reason: SessionEnd.Reason, into group: inout [Announcement]) {
        phase = .finished(reason)
        let time = lastTime ?? 0
        group.append(Announcement(time: time, content: .sessionEnd(SessionEnd(reason: reason, movingSeconds: movingSeconds))))
    }

    /// Close the active segment: a `work` segment gets its split (and the
    /// block's summary when it is the block's last), a long `main` or `finish`
    /// gets a summary. `early` is a skip or an early end; `endedWorkout` also
    /// summarizes the reps so far when the active segment is a jog in a block.
    private mutating func finishSegment(early: Bool, endedWorkout: Bool, into group: inout [Announcement]) {
        let entry = entries[active]
        let time = lastTime ?? 0
        let seg = entry.segment
        let result = makeResult(accumulator, segment: seg)
        let complete = !early || accumulator.moving >= config.completeFraction * seg.durationSeconds
        switch seg.role {
        case .work:
            guard let b = entry.block, let n = entry.repNumber, let of = entry.repCount else { break }
            let split = makeSplit(result, entry: entry, repNumber: n, repCount: of, complete: complete)
            splits.append(split)
            blockSplits[b, default: []].append(split)
            group.append(Announcement(time: time, content: .repSplit(split)))
            if entry.lastOfBlock || endedWorkout { summarizeBlock(b, endedEarly: endedWorkout, into: &group) }
        case .main, .finish:
            if accumulator.moving >= config.minimumSummarySegmentSeconds {
                let split = makeSplit(result, entry: entry, repNumber: 1, repCount: 1, complete: complete)
                let s = IntervalSummary.make(role: seg.role, planned: 1, splits: [split], endedEarly: !complete,
                                             driftOverride: .some(result.drift))
                summaries.append(s)
                group.append(Announcement(time: time, content: .intervalSummary(s)))
            }
        case .jog:
            if endedWorkout, let b = entry.block { summarizeBlock(b, endedEarly: true, into: &group) }
        case .warmUp, .coolDown:
            break
        }
    }

    private mutating func summarizeBlock(_ b: Int, endedEarly: Bool, into group: inout [Announcement]) {
        guard !blockSummarized.contains(b) else { return }
        let reps = blockSplits[b] ?? []
        guard reps.contains(where: \.isComplete) else { return }
        blockSummarized.insert(b)
        let planned = reps.first?.repCount ?? reps.count
        let s = IntervalSummary.make(role: .work, planned: planned, splits: reps, endedEarly: endedEarly, driftOverride: nil)
        summaries.append(s)
        group.append(Announcement(time: lastTime ?? 0, content: .intervalSummary(s)))
    }

    private func makeResult(_ a: Accumulator, segment: WorkoutSegment) -> SegmentResult {
        let cfg = config
        let moving = a.moving
        let coveredFraction = moving > 0 ? a.covered / moving : 0
        let enough = coveredFraction >= cfg.minimumCoverageFraction && a.distance > 0 && a.covered > 0
        let gradeCoverage = a.covered > 0 ? a.gradeSeconds / a.covered : 0
        let pace: Double? = enough ? a.covered / a.distance * 1000 : nil
        let distance: Double? = enough ? a.distance * (moving / a.covered) : nil
        let gap: Double? = enough && gradeCoverage >= cfg.minimumCoverageFraction && a.flat > 0
            ? a.covered / a.flat * 1000 : nil
        let postLag = max(0, moving - lag(of: segment))
        let hr: Double? = postLag > 0 && a.hrSeconds >= cfg.minimumCoverageFraction * postLag && a.hrSeconds > 0
            ? a.hrSum / a.hrSeconds : nil
        var drift: Double?
        let half = segment.durationSeconds / 2
        if a.firstHalfSeconds >= cfg.minimumCoverageFraction * max(half - lag(of: segment), 1),
           a.secondHalfSeconds >= cfg.minimumCoverageFraction * max(min(moving, segment.durationSeconds) - half, 1),
           a.firstHalfSeconds > 0, a.secondHalfSeconds > 0 {
            drift = a.secondHalfSum / a.secondHalfSeconds - a.firstHalfSum / a.firstHalfSeconds
        }
        return SegmentResult(moving: moving, coveredFraction: coveredFraction, gradeCoverage: gradeCoverage,
                             distance: distance, pace: pace, gradeAdjusted: gap, heartRate: hr, drift: drift)
    }

    private func makeSplit(_ r: SegmentResult, entry: Entry, repNumber: Int, repCount: Int, complete: Bool) -> RepSplit {
        let target = entry.segment.target
        let tol = config.inBandToleranceFraction
        var verdict = BandVerdict.unknown
        var basis = VerdictBasis.none
        switch target.primary {
        case .pace:
            if let band = target.pace {
                let value: Double?
                if let g = r.gradeAdjusted { value = g; basis = .gradeAdjustedPace } else if let p = r.pace { value = p; basis = .flatPace } else { value = nil }
                if let v = value {
                    if v < band.fastestSecondsPerKm * (1 - tol) { verdict = .faster }
                    else if v > band.slowestSecondsPerKm * (1 + tol) { verdict = .slower }
                    else { verdict = .inBand }
                }
            }
        case .heartRate:
            if let h = r.heartRate {
                let hrt = target.heartRate
                if let c = hrt.ceilingBPM, c.isFinite, h >= c { verdict = .faster; basis = .heartRate }
                else if let f = hrt.floorBPM, f.isFinite, h < f { verdict = .slower; basis = .heartRate }
                else if (hrt.ceilingBPM?.isFinite ?? false) || (hrt.floorBPM?.isFinite ?? false) { verdict = .inBand; basis = .heartRate }
            }
        }
        return RepSplit(segmentIndex: entry.index, role: entry.segment.role, repNumber: repNumber, repCount: repCount,
                        plannedSeconds: entry.segment.durationSeconds, durationSeconds: r.moving, isComplete: complete,
                        distanceMeters: r.distance, paceSecondsPerKm: r.pace,
                        gradeAdjustedPaceSecondsPerKm: r.gradeAdjusted, averageHeartRate: r.heartRate,
                        verdict: verdict, verdictBasis: basis, coveredFraction: r.coveredFraction,
                        gradeCoverage: r.gradeCoverage, target: target)
    }

    // MARK: Countdown and the one voice

    private mutating func countdown(at time: Double) -> Pending? {
        guard phase == .running, !points.isEmpty else { return nil }
        let entry = entries[active]
        let remaining = entry.segment.durationSeconds - segmentSeconds
        var chosen: (point: Double, late: Double)?
        while let p = points.first, remaining <= p + eps {
            points.removeFirst()
            let late = p - remaining
            if late <= config.countdownLateSeconds { chosen = (p, late) }
        }
        guard let c = chosen else { return nil }
        let content = Countdown(segmentIndex: entry.index, role: entry.segment.role, secondsLeft: c.point,
                                repNumber: entry.repNumber, nextRepNumber: entry.nextRepNumber, repCount: entry.repCount)
        return Pending(announcement: Announcement(time: time, content: .countdown(content)),
                       expiry: clock + config.countdownLateSeconds - c.late)
    }

    /// Everything from one segment change (or press), spoken now in priority
    /// order (stable), ignoring the gap.
    private mutating func speakGroup(_ group: [Announcement], at time: Double) -> [Announcement] {
        guard !group.isEmpty else { return [] }
        dropAll(pending)
        pending.removeAll()
        lastSpoken = clock
        let ordered = group.enumerated().sorted {
            $0.element.priority != $1.element.priority ? $0.element.priority > $1.element.priority : $0.offset < $1.offset
        }.map(\.element)
        return ordered.map { $0.spoken(at: time) }
    }

    private mutating func dropAll(_ items: [Pending]) { droppedAnnouncements.append(contentsOf: items.map(\.announcement)) }

    /// Add `due` to the waiting announcements, drop the stale ones, and speak
    /// the highest priority if the gap allows.
    private mutating func schedule(_ due: [Pending], at time: Double) -> [Announcement] {
        var kept: [Pending] = []
        for p in pending {
            if clock > p.expiry + eps { droppedAnnouncements.append(p.announcement) } else { kept.append(p) }
        }
        pending = kept + due
        guard !pending.isEmpty else { return [] }
        if let last = lastSpoken, clock - last < config.minimumGapSeconds - eps { return [] }
        var best = 0
        for i in pending.indices where pending[i].announcement.priority > pending[best].announcement.priority { best = i }
        let chosen = pending.remove(at: best)
        lastSpoken = clock
        return [chosen.announcement.spoken(at: time)]
    }
}

extension IntervalSummary {
    /// Build a summary from the reps' splits. `driftOverride`: `.some(x)` uses
    /// `x` (a continuous segment's half-to-half drift, possibly nil), nil computes
    /// last-vs-first over the complete reps' heart rates.
    fileprivate static func make(role: WorkoutSegment.Role, planned: Int, splits: [RepSplit], endedEarly: Bool,
                                 driftOverride: Double??) -> IntervalSummary {
        let done = splits.filter(\.isComplete)
        let used = role == .work ? done : splits
        func stats(_ values: [Double]) -> (mean: Double?, spread: Double?) {
            guard let lo = values.min(), let hi = values.max() else { return (nil, nil) }
            return (values.reduce(0, +) / Double(values.count), values.count >= 2 ? hi - lo : nil)
        }
        let gap = stats(used.compactMap(\.gradeAdjustedPaceSecondsPerKm))
        let raw = stats(used.compactMap(\.paceSecondsPerKm))
        var drift: Double?
        if let o = driftOverride {
            drift = o
        } else {
            let hrs = used.compactMap(\.averageHeartRate)
            if hrs.count >= 2, let first = hrs.first, let last = hrs.last { drift = last - first }
        }
        return IntervalSummary(
            role: role, repsPlanned: planned, repsDone: role == .work ? done.count : 1,
            repsPartial: role == .work ? splits.count - done.count : 0, endedEarly: endedEarly,
            averageGradeAdjustedPaceSecondsPerKm: gap.mean,
            repsWithGradeAdjustedPace: used.filter { $0.gradeAdjustedPaceSecondsPerKm != nil }.count,
            gradeAdjustedSpreadSecondsPerKm: gap.spread,
            averagePaceSecondsPerKm: raw.mean, paceSpreadSecondsPerKm: raw.spread,
            repsInBand: used.filter { $0.verdict == .inBand }.count,
            repsFaster: used.filter { $0.verdict == .faster }.count,
            repsSlower: used.filter { $0.verdict == .slower }.count,
            repsUnjudged: used.filter { $0.verdict == .unknown }.count,
            heartRateDriftBPM: drift)
    }
}
