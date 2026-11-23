import Foundation

/// Which output is set against heart rate (SPEC.md 3.3).
public enum DecouplingBasis: Equatable, Sendable {
    /// Pace-to-HR: speed (m/s) divided by heart rate.
    case pace
    /// Power-to-HR: running power (W) divided by heart rate.
    case power
}

/// What a decoupling percentage says about the run (SPEC.md 3.3, Friel).
public enum DecouplingClass: Equatable, Sendable {
    /// Under 5%: good aerobic endurance at that intensity.
    case good
    /// 5 to 10% inclusive: moderate.
    case moderate
    /// Over 10%: the effort was above aerobic threshold.
    case aboveAerobicThreshold

    public init(percent: Double) {
        if percent < 5 {
            self = .good
        } else if percent <= 10 {
            self = .moderate
        } else {
            self = .aboveAerobicThreshold
        }
    }
}

/// Aerobic decoupling of one run (SPEC.md 3.3, F1 baseline, F4, F13).
public struct DecouplingResult: Equatable, Sendable {
    public let basis: DecouplingBasis
    /// (EF first half - EF second half) / EF first half * 100. Negative when
    /// efficiency improved in the second half.
    public let percent: Double
    public let classification: DecouplingClass
    /// Efficiency factor (output per beat) of the first half of the analyzed window.
    public let firstHalfEF: Double
    /// Efficiency factor of the second half of the analyzed window.
    public let secondHalfEF: Double
    /// Moving time of the whole run, in seconds.
    public let movingSeconds: Double
    /// Moving time that was split into halves (moving time after the warm-up).
    public let analyzedSeconds: Double
    /// Share of each half's moving time with a usable heart rate, 0 to 1.
    public let firstHalfHRCoverage: Double
    public let secondHalfHRCoverage: Double
    /// Time-weighted coefficient of variation of moving speed after the warm-up,
    /// or nil without enough speed data (see `Decoupling.speedCoefficientOfVariation`).
    public let speedCoefficientOfVariation: Double?
    /// Whether the run passed the steady-run heuristic (`DecouplingOptions.maximumSpeedCV`),
    /// or nil without enough speed data. `compute` reports this but never refuses
    /// on it: SPEC 3.3 applies decoupling to steady runs, so callers that track
    /// the trend (F1 baseline, F4, F13) should keep only results where this is true.
    public let isSteady: Bool?
}

/// Why decoupling was not computed. CoachCore refuses rather than guesses.
public enum DecouplingRefusal: Error, Equatable, Sendable {
    /// Moving time is under `DecouplingOptions.minimumMovingSeconds`.
    case tooShort(movingSeconds: Double)
    /// Too little usable heart rate in one half; `coverage` is the worse half's share.
    case insufficientHeartRate(coverage: Double)
    /// Too little usable speed (pace basis) or power (power basis) alongside heart
    /// rate in one half; `coverage` is the worse half's share.
    case insufficientOutput(coverage: Double)
    /// An option is non-finite or out of range (negative time, coverage outside 0...1).
    case invalidOptions
}

/// Tunable thresholds. Every default is a heuristic, labeled as such, and none
/// stands for a particular runner.
public struct DecouplingOptions: Equatable, Sendable {
    /// SPEC.md 3.3: decoupling is computed only on runs *over* 40 minutes of
    /// moving time, so exactly this much is refused.
    public var minimumMovingSeconds: Double
    /// Heuristic: moving time skipped at the start before the halves are taken,
    /// because heart rate lags effort for the first few minutes and would make
    /// the first half look more efficient than it was. Default 5 minutes; 0
    /// gives the plain whole-run split. Must be finite and at least 0, or
    /// `compute` refuses with `.invalidOptions`.
    public var warmUpSeconds: Double
    /// Heuristic: each half needs at least this share of its moving time with a
    /// usable heart rate (and, separately, with usable heart rate and output
    /// together). Default 0.8 (80%).
    public var minimumCoverage: Double
    /// Heuristic: each stream (heart rate, and speed or power) carries its own
    /// last usable reading forward for at most this many seconds, so streams
    /// recorded at different rates or offset timestamps still line up. After
    /// that the stream counts as missing until its next usable reading, which
    /// lowers coverage. Default 30 s.
    ///
    /// The same limit bounds a silent stretch that ends in a pause: when no
    /// sample arrives for longer than this and the next sample is paused, only
    /// this much of the stretch counts as moving time. A silent stretch with
    /// moving samples on both sides is all moving time.
    public var maximumHoldSeconds: Double
    /// Heart rates outside this range are treated as sensor errors and ignored.
    public var plausibleHeartRate: ClosedRange<Double>
    /// Heuristic steady-run limit on the coefficient of variation of moving speed
    /// (see `Decoupling.defaultMaximumSpeedCV`).
    public var maximumSpeedCV: Double

    public init(minimumMovingSeconds: Double = 40 * 60,
                warmUpSeconds: Double = 5 * 60,
                minimumCoverage: Double = 0.8,
                maximumHoldSeconds: Double = 30,
                plausibleHeartRate: ClosedRange<Double> = 30...250,
                maximumSpeedCV: Double = Decoupling.defaultMaximumSpeedCV) {
        self.minimumMovingSeconds = minimumMovingSeconds
        self.warmUpSeconds = warmUpSeconds
        self.minimumCoverage = minimumCoverage
        self.maximumHoldSeconds = maximumHoldSeconds
        self.plausibleHeartRate = plausibleHeartRate
        self.maximumSpeedCV = maximumSpeedCV
    }

    /// True when every option is finite and in range. `maximumHoldSeconds`
    /// must be positive: with a zero hold no reading would count for any time,
    /// so every run would refuse as insufficient heart rate and nothing would
    /// point at the bad option.
    public var isValid: Bool {
        let times = [minimumMovingSeconds, warmUpSeconds]
        return times.allSatisfy { $0.isFinite && $0 >= 0 }
            && maximumHoldSeconds.isFinite && maximumHoldSeconds > 0
            && minimumCoverage.isFinite && (0...1).contains(minimumCoverage)
            && plausibleHeartRate.lowerBound.isFinite && plausibleHeartRate.upperBound.isFinite
            && maximumSpeedCV.isFinite && maximumSpeedCV >= 0
    }

    public static let `default` = DecouplingOptions()
}

/// Aerobic decoupling between the first and second halves of a steady run's
/// moving time (SPEC.md 3.3, Friel / TrainingPeaks):
///
///     EF = time-weighted mean output / time-weighted mean heart rate
///     decoupling % = (EF first half - EF second half) / EF first half * 100
///
/// How samples become time:
/// - Samples with a non-finite `t` are dropped. Samples sharing a timestamp are
///   merged first, independent of input order: the merged point is paused if any
///   of them is paused, and each stream takes the mean of their usable values.
/// - Points are taken in time order. The time from one point to the next is
///   moving time when the first point is moving (see `maximumHoldSeconds` for a
///   silent stretch that ends in a pause); the last point adds no time.
/// - An interval that starts at a paused point (`isMoving == false`) is excluded
///   entirely: it is neither moving time nor data. A pause also ends every hold,
///   so a reading from before a pause never carries over into the run after it.
/// - Heart rate and output are carried forward separately, each from its own
///   last usable reading on a moving point, for at most `maximumHoldSeconds`.
/// - The halves are split on the moving-time clock, after skipping
///   `warmUpSeconds`; an interval that straddles the midpoint is split by time.
/// - Each ratio uses only time where both heart rate and the output are usable:
///   finite, heart rate within `plausibleHeartRate`, output above zero.
///
/// `compute` does not refuse unsteady runs; it reports the steady-run check in
/// `DecouplingResult.isSteady` and leaves the choice to the caller.
public enum Decoupling {

    /// Computes decoupling, or says why it can't.
    public static func compute(
        _ samples: [StreamSample],
        basis: DecouplingBasis = .pace,
        options: DecouplingOptions = .default
    ) -> Result<DecouplingResult, DecouplingRefusal> {
        guard options.isValid else { return .failure(.invalidOptions) }
        let timeline = movingIntervals(samples, basis: basis, options: options)
        let moving = timeline.last?.end ?? 0
        let warmUp = options.warmUpSeconds
        guard moving > options.minimumMovingSeconds, moving > warmUp else {
            return .failure(.tooShort(movingSeconds: moving))
        }
        let mid = warmUp + (moving - warmUp) / 2
        let first = accumulate(timeline, from: warmUp, to: mid)
        let second = accumulate(timeline, from: mid, to: moving)

        let hrCoverage = min(first.hrCoverage, second.hrCoverage)
        guard hrCoverage >= options.minimumCoverage else {
            return .failure(.insufficientHeartRate(coverage: hrCoverage))
        }
        let pairCoverage = min(first.pairCoverage, second.pairCoverage)
        guard pairCoverage >= options.minimumCoverage,
              let ef1 = first.efficiency, let ef2 = second.efficiency else {
            return .failure(.insufficientOutput(coverage: pairCoverage))
        }
        let percent = (ef1 - ef2) / ef1 * 100
        let cv = speedCV(basis == .pace ? timeline : movingIntervals(samples, basis: .pace, options: options),
                         warmUp: warmUp)
        return .success(DecouplingResult(
            basis: basis,
            percent: percent,
            classification: DecouplingClass(percent: percent),
            firstHalfEF: ef1,
            secondHalfEF: ef2,
            movingSeconds: moving,
            analyzedSeconds: moving - warmUp,
            firstHalfHRCoverage: first.hrCoverage,
            secondHalfHRCoverage: second.hrCoverage,
            speedCoefficientOfVariation: cv,
            isSteady: cv.map { $0 <= options.maximumSpeedCV }))
    }

    // MARK: Steady-run check

    /// Heuristic: a run is steady when the time-weighted coefficient of variation
    /// (standard deviation / mean) of its moving speed after the warm-up is at
    /// most this. 0.10 tolerates normal drift, gentle terrain and GPS noise but
    /// rejects intervals, fartlek and stop-start runs. Hilly routes can fail it
    /// on raw speed; grade-adjusted pace (3.6) is a later refinement.
    public static let defaultMaximumSpeedCV = 0.10

    /// Time-weighted coefficient of variation of moving speed after the warm-up,
    /// or nil when under half of that time has a usable speed or the options are invalid.
    public static func speedCoefficientOfVariation(
        _ samples: [StreamSample],
        options: DecouplingOptions = .default
    ) -> Double? {
        guard options.isValid else { return nil }
        return speedCV(movingIntervals(samples, basis: .pace, options: options), warmUp: options.warmUpSeconds)
    }

    /// Whether the run is steady enough for decoupling to mean something
    /// (heuristic: speed CV at most `options.maximumSpeedCV`), or nil without
    /// enough speed data.
    public static func isSteady(
        _ samples: [StreamSample],
        options: DecouplingOptions = .default
    ) -> Bool? {
        speedCoefficientOfVariation(samples, options: options).map { $0 <= options.maximumSpeedCV }
    }

    static func speedCV(_ timeline: [Interval], warmUp: Double) -> Double? {
        let moving = timeline.last?.end ?? 0
        guard moving > warmUp else { return nil }
        var w = 0.0, sum = 0.0, sumSq = 0.0
        for iv in timeline {
            guard let v = iv.output else { continue }
            let overlap = max(0, min(iv.end, moving) - max(iv.start, warmUp))
            guard overlap > 0 else { continue }
            w += overlap; sum += v * overlap; sumSq += v * v * overlap
        }
        guard w >= 0.5 * (moving - warmUp), w > 0 else { return nil }
        let mean = sum / w
        guard mean > 0 else { return nil }
        let variance = max(0, sumSq / w - mean * mean)
        let cv = variance.squareRoot() / mean
        return cv.isFinite ? cv : nil
    }

    // MARK: Internals

    /// A stretch of moving time on the moving clock, with the values held over it
    /// (nil when not usable or not recorded).
    struct Interval {
        var start: Double
        var end: Double
        var heartRate: Double?
        var output: Double?
    }

    /// One timestamp after merging duplicate samples.
    struct Point {
        var t: Double
        var isMoving: Bool
        var heartRate: Double?
        var output: Double?
    }

    /// Merges samples that share a timestamp, independent of their input order:
    /// paused if any is paused, each stream the mean of its usable values.
    static func points(_ samples: [StreamSample],
                       basis: DecouplingBasis,
                       options: DecouplingOptions) -> [Point] {
        var byTime: [Double: (moving: Bool, hr: [Double], out: [Double])] = [:]
        for s in samples where s.t.isFinite {
            var e = byTime[s.t] ?? (true, [], [])
            e.moving = e.moving && s.isMoving
            if let v = usableHR(s.heartRate, options) { e.hr.append(v) }
            if let v = usableOutput(basis == .pace ? s.speed : s.power) { e.out.append(v) }
            byTime[s.t] = e
        }
        func mean(_ xs: [Double]) -> Double? {
            xs.isEmpty ? nil : xs.sorted().reduce(0, +) / Double(xs.count)
        }
        return byTime.keys.sorted().map { t in
            let e = byTime[t]!
            return Point(t: t, isMoving: e.moving, heartRate: mean(e.hr), output: mean(e.out))
        }
    }

    /// Builds the moving-time timeline. Moving time is the time from each moving
    /// point to the next point. A silent stretch (no samples) with moving
    /// samples on both sides counts in full as moving time, because nothing says
    /// the runner stopped. Importers (HealthKit, Strava) must therefore emit
    /// pause events as `isMoving == false` samples; a watch that stops
    /// recording during auto-pause without a paused sample would count the gap
    /// as moving time and lower heart-rate coverage.
    static func movingIntervals(_ samples: [StreamSample],
                                basis: DecouplingBasis,
                                options: DecouplingOptions) -> [Interval] {
        let pts = points(samples, basis: basis, options: options)
        guard pts.count >= 2 else { return [] }
        let hold = options.maximumHoldSeconds
        var clock = 0.0
        var lastHR: (t: Double, v: Double)?
        var lastOut: (t: Double, v: Double)?
        var out: [Interval] = []
        out.reserveCapacity(pts.count)
        for i in 0..<(pts.count - 1) {
            let p = pts[i], next = pts[i + 1]
            guard p.isMoving else {
                lastHR = nil; lastOut = nil
                continue
            }
            if let v = p.heartRate { lastHR = (p.t, v) }
            if let v = p.output { lastOut = (p.t, v) }
            let dt = next.t - p.t
            let duration = next.isMoving ? dt : min(dt, hold)
            guard duration > 0 else { continue }
            let end = p.t + duration
            // Each stream is usable up to its own hold limit.
            let hrUntil = lastHR.map { $0.t + hold } ?? -Double.infinity
            let outUntil = lastOut.map { $0.t + hold } ?? -Double.infinity
            var cuts = [p.t, end]
            for c in [hrUntil, outUntil] where c > p.t && c < end { cuts.append(c) }
            cuts.sort()
            for j in 0..<(cuts.count - 1) where cuts[j + 1] > cuts[j] {
                let a = cuts[j], b = cuts[j + 1]
                out.append(Interval(start: clock + (a - p.t), end: clock + (b - p.t),
                                    heartRate: a < hrUntil ? lastHR?.v : nil,
                                    output: a < outUntil ? lastOut?.v : nil))
            }
            clock += duration
        }
        return out
    }

    static func usableHR(_ v: Double?, _ options: DecouplingOptions) -> Double? {
        guard let v, v.isFinite, options.plausibleHeartRate.contains(v) else { return nil }
        return v
    }

    static func usableOutput(_ v: Double?) -> Double? {
        guard let v, v.isFinite, v > 0 else { return nil }
        return v
    }

    struct Half {
        var seconds = 0.0
        var hrSeconds = 0.0
        var pairSeconds = 0.0
        var hrSum = 0.0
        var outputSum = 0.0

        var hrCoverage: Double { seconds > 0 ? hrSeconds / seconds : 0 }
        var pairCoverage: Double { seconds > 0 ? pairSeconds / seconds : 0 }
        /// Mean output over mean heart rate, both over the paired time only.
        var efficiency: Double? {
            guard pairSeconds > 0, hrSum > 0 else { return nil }
            let ef = (outputSum / pairSeconds) / (hrSum / pairSeconds)
            return ef.isFinite && ef > 0 ? ef : nil
        }
    }

    static func accumulate(_ timeline: [Interval], from lo: Double, to hi: Double) -> Half {
        var h = Half()
        for iv in timeline {
            let overlap = min(iv.end, hi) - max(iv.start, lo)
            guard overlap > 0 else { continue }
            h.seconds += overlap
            if iv.heartRate != nil { h.hrSeconds += overlap }
            if let hr = iv.heartRate, let x = iv.output {
                h.pairSeconds += overlap
                h.hrSum += hr * overlap
                h.outputSum += x * overlap
            }
        }
        return h
    }
}
