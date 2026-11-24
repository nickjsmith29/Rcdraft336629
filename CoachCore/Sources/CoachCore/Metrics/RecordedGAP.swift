import Foundation

/// Tuning for `RecordedGAP`. **Every number is a heuristic** (SPEC.md 3.6, F7),
/// chosen against synthetic altitude noise; none stands for a runner.
public struct RecordedGAPOptions: Equatable, Sendable {
    /// How the grade is fitted. The default is the live coach's own
    /// `GradeEstimatorConfig` (90 m of distance, clamp at 45%, minimum span
    /// and sample count) so the live and the post-run grade agree. The
    /// recorded fit is centred on each sample instead of trailing it, because
    /// the whole run is known: the live fit's lag at a hill's start or end
    /// (see `GradeEstimatorConfig.windowMeters`) is not needed afterwards.
    /// One difference: `minSamples` is 4, not the live 8, because a recorded
    /// run may be sampled every 5 s (about 18 m apart at 3.7 m/s, so 5 or 6
    /// samples in 90 m) where the live coach reads about once a second.
    /// Heuristic.
    public var grade: GradeEstimatorConfig
    /// Heuristic: GAP is reported only when at least this share of the moving
    /// time in scope has both a speed and a fitted grade. The same share
    /// `RunMetrics.minimumCoverage` asks of every other stream mean.
    public var minimumCoverage = RunMetrics.minimumCoverage
    /// Heuristic spike filter: an altitude is compared with the median of the
    /// `spikeWindowSamples` samples around it (by distance). Odd, default 7.
    public var spikeWindowSamples = 7
    /// ... and dropped when it is further from that median than the steepest
    /// grade allows over the distance between them (`grade.maxAbsGrade` times
    /// that distance) plus this many metres of sensor noise. Heuristic, 3 m.
    /// It catches single or double jumps of a barometer or a GPS-only
    /// altitude; a glitch lasting more than half the window is not caught.
    public var spikeToleranceMeters = 3.0
    /// A speed or grade reading is carried over a gap in the stream for at
    /// most this long, as `MovingTime` does for every other stream.
    public var maximumHoldSeconds = MovingTime.defaultMaximumHoldSeconds

    public init() {
        var g = GradeEstimatorConfig()
        g.minSamples = 4
        grade = g
    }
}

/// Grade-adjusted pace of a recorded run (SPEC.md F7 part 1, 3.6, section 8 metrics).
///
/// The pace the runner would have held on flat ground for the same effort,
/// by the default curve of 3.6 (`DefaultGradePaceCurve`): in each stretch
/// `GAP pace = raw pace / f(grade)`, so a slow climb maps to a faster GAP.
/// It is the time-weighted mean of the flat-equivalent speed `v * f(grade)`
/// over the moving time in scope, the way `RunMetrics` weights raw speed.
///
/// This is the default curve, not a personal one (the personal curve is
/// Phase 3), so it is a heuristic comparison with a target, not a measurement
/// of effort. It never reports a guess: with no usable altitude, or under
/// `RecordedGAPOptions.minimumCoverage`, `measure` returns nil.
public struct RecordedGAP: Equatable, Sendable, Codable {
    /// Grade-adjusted pace over the covered stretches, seconds per km. Always finite and above 0.
    public let paceSecondsPerKm: Double
    /// Raw pace over the same stretches (so it is comparable with `paceSecondsPerKm`).
    public let rawPaceSecondsPerKm: Double
    /// Share (0 to 1) of the moving time in scope that had both a speed and a grade.
    public let coverage: Double
    /// Moving seconds the pace is averaged over.
    public let coveredSeconds: Double

    /// Grade-adjusted pace of `activity`.
    ///
    /// - Parameters:
    ///   - windows: the stretches to average over, in seconds on the moving
    ///     clock (pauses left out, as `RunMetrics.key` uses). Nil means the
    ///     whole run. Stretches past the end of the run are clipped.
    ///   - curve: grade to pace factor (3.6); the default curve unless a
    ///     personal one exists.
    /// - Returns: nil when the run has no usable altitude or distance, no
    ///   moving time in scope, or under `options.minimumCoverage` of it has a
    ///   speed and a grade.
    public static func measure(_ activity: Activity, windows: [ClosedRange<Double>]? = nil,
                               curve: any GradePaceCurve = DefaultGradePaceCurve(),
                               options: RecordedGAPOptions = RecordedGAPOptions()) -> RecordedGAP? {
        let points = MovingTime.merged(activity.samples, streams: [
            .speed: { $0 > 0 },
            .altitude: { _ in true },
            .distance: { $0 >= 0 },
        ])
        guard points.count >= 2 else { return nil }
        let hold = options.maximumHoldSeconds.isFinite ? max(0, options.maximumHoldSeconds)
            : MovingTime.defaultMaximumHoldSeconds

        let distances = runDistances(points, hold: hold)
        let series = altitudeSeries(points, distances, options)
        let grades = fittedGrades(distances, series, options)

        // Walk the moving clock exactly as `MovingTime.held` does, carrying
        // the last speed and the last grade for at most `hold` seconds.
        var clock = 0.0
        var speed: (t: Double, v: Double)?, grade: (t: Double, g: Double)?
        var pieces: [(start: Double, end: Double, speed: Double?, factor: Double?)] = []
        for i in 0..<(points.count - 1) {
            let p = points[i], next = points[i + 1]
            guard p.isMoving else { speed = nil; grade = nil; continue }
            if let v = p.values[.speed] { speed = (p.t, v) }
            if let g = grades[i] { grade = (p.t, g) }
            let dt = next.t - p.t
            let duration = next.isMoving ? dt : min(dt, hold)
            guard duration > 0 else { continue }
            let end = p.t + duration
            var cuts = [p.t, end]
            for expiry in [speed.map { $0.t + hold }, grade.map { $0.t + hold }] {
                if let e = expiry, e > p.t, e < end { cuts.append(e) }
            }
            cuts.sort()
            for j in 0..<(cuts.count - 1) where cuts[j + 1] > cuts[j] {
                let a = cuts[j], b = cuts[j + 1]
                let v = speed.flatMap { a < $0.t + hold ? $0.v : nil }
                let f = grade.flatMap { a < $0.t + hold ? curve.factor(grade: $0.g) : nil }
                pieces.append((clock + (a - p.t), clock + (b - p.t), v, f))
            }
            clock += duration
        }

        let scope = windows ?? [0...clock]
        let total = scope.reduce(0) { $0 + max(0, min($1.upperBound, clock) - $1.lowerBound) }
        guard total > 0 else { return nil }
        var covered = 0.0, flatSpeed = 0.0, rawSpeed = 0.0
        for piece in pieces {
            guard let v = piece.speed, let f = piece.factor, f.isFinite, f > 0 else { continue }
            for w in scope {
                let overlap = min(piece.end, w.upperBound) - max(piece.start, w.lowerBound)
                guard overlap > 0 else { continue }
                covered += overlap
                flatSpeed += v * f * overlap
                rawSpeed += v * overlap
            }
        }
        guard covered > 0, covered >= options.minimumCoverage * total else { return nil }
        let gapPace = 1000 * covered / flatSpeed, rawPace = 1000 * covered / rawSpeed
        guard gapPace.isFinite, gapPace > 0, rawPace.isFinite, rawPace > 0 else { return nil }
        return RecordedGAP(paceSecondsPerKm: gapPace, rawPaceSecondsPerKm: rawPace,
                           coverage: min(1, covered / total), coveredSeconds: covered)
    }

    // MARK: - Distance, altitude and grade

    /// The distance run at each point (metres), nil where unknown. Uses the
    /// distance stream, ignoring a reading that falls below an earlier one (a
    /// glitch or reset). A run with fewer than two distance readings has the
    /// speed stream integrated over moving time instead.
    static func runDistances(_ points: [MovingTime.Point], hold: Double) -> [Double?] {
        let recorded = points.filter { $0.values[.distance] != nil }.count
        if recorded >= 2 {
            var highest = -Double.infinity
            return points.map { p in
                guard let d = p.values[.distance], d >= highest else { return nil }
                highest = d
                return d
            }
        }
        var out: [Double?] = []
        var total = 0.0
        var speed: (t: Double, v: Double)?
        for (i, p) in points.enumerated() {
            out.append(total)
            guard p.isMoving, i + 1 < points.count else { speed = nil; continue }
            if let v = p.values[.speed] { speed = (p.t, v) }
            let dt = points[i + 1].t - p.t
            let duration = points[i + 1].isMoving ? dt : min(dt, hold)
            if let s = speed, duration > 0 {
                total += s.v * max(0, min(duration, s.t + hold - p.t))
            }
        }
        return out
    }

    /// (distance, altitude) of the moving points, at least
    /// `minSampleSpacingMeters` apart, with altitude spikes removed.
    static func altitudeSeries(_ points: [MovingTime.Point], _ distances: [Double?],
                               _ options: RecordedGAPOptions) -> [(d: Double, a: Double)] {
        var raw: [(d: Double, a: Double)] = []
        for (i, p) in points.enumerated() where p.isMoving {
            guard let a = p.values[.altitude], let d = distances[i] else { continue }
            if let last = raw.last, d - last.d < options.grade.minSampleSpacingMeters { continue }
            raw.append((d, a))
        }
        let half = max(1, options.spikeWindowSamples / 2)
        guard raw.count > 2 * half else { return raw }
        return raw.enumerated().compactMap { i, s in
            let near = raw[max(0, i - half)...min(raw.count - 1, i + half)]
            let medianA = median(near.map(\.a)), medianD = median(near.map(\.d))
            let allowed = options.grade.maxAbsGrade * abs(s.d - medianD) + options.spikeToleranceMeters
            return abs(s.a - medianA) > allowed ? nil : s
        }
    }

    /// The grade at each point: the shared fit (`GradeEstimator.fitGrade`) over
    /// a window of `grade.windowMeters` centred on the point, slid inwards at
    /// the run's ends so it stays full. Nil where the point has no distance or
    /// the window holds too few altitude samples (a gap in altitude).
    static func fittedGrades(_ distances: [Double?], _ series: [(d: Double, a: Double)],
                             _ options: RecordedGAPOptions) -> [Double?] {
        guard let first = series.first?.d, let last = series.last?.d else { return distances.map { _ in nil } }
        let width = options.grade.windowMeters
        return distances.map { distance in
            guard let d = distance, d >= first - width / 2, d <= last + width / 2 else { return nil }
            var lo = d - width / 2, hi = d + width / 2
            if lo < first { hi += first - lo; lo = first }
            if hi > last { lo -= hi - last; hi = last }
            lo = max(lo, first)
            let from = lowerBound(series, lo), to = lowerBound(series, hi.nextUp)
            guard from < to else { return nil }
            return GradeEstimator.fitGrade(series[from..<to], config: options.grade)?.grade
        }
    }

    /// Index of the first element with distance at least `x`.
    private static func lowerBound(_ s: [(d: Double, a: Double)], _ x: Double) -> Int {
        var lo = 0, hi = s.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if s[mid].d < x { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    private static func median(_ xs: [Double]) -> Double {
        let s = xs.sorted()
        let n = s.count
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
    }
}
