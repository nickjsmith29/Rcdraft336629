import Foundation

/// Tuning for `GradeEstimator`. **Every number is a heuristic** (SPEC.md 3.6,
/// F11), chosen against synthetic altitude noise; none stands for a runner.
public struct GradeEstimatorConfig: Equatable, Sendable {
    /// Length of the trailing window the slope is fitted over, in metres of
    /// distance run. Heuristic. Smoothing over distance (not time) keeps the
    /// grade steady when the runner slows on a climb. 90 m is about 30 s at
    /// 3 m/s: with 0.4 m altitude noise the fitted grade of a steady climb
    /// stays within 1.5 percentage points (tested), and a turn from climb to
    /// descent flips the sign in about 15 s. The lag of the fit at a hill's
    /// start or end is what `CueEngine` handles with its grade-change hold.
    public var windowMeters: Double = 90
    /// The slope is reported only once the samples span at least this many
    /// metres. Heuristic (half the window).
    public var minSpanMeters: Double = 45
    /// ... and there are at least this many samples. Heuristic.
    public var minSamples: Int = 8
    /// A sample is kept only when the runner has moved at least this far
    /// (metres) since the last kept one, so standing still adds nothing and
    /// noise does not pile up at one distance. Heuristic.
    public var minSampleSpacingMeters: Double = 2
    /// With no altitude reading for this many seconds the grade is nil
    /// ("altitude is missing"). Heuristic.
    public var maxAltitudeAgeSeconds: Double = 10
    /// Grades are clamped to this magnitude, as in SPEC 3.6.
    public var maxAbsGrade: Double = DefaultGradePaceCurve.gradeLimit

    public init() {}
}

/// A smoothed grade.
public struct GradeEstimate: Equatable, Sendable {
    /// Time of the reading the estimate was made at (seconds since start).
    public let time: Double
    /// Smoothed grade as a fraction (0.05 = 5% uphill).
    public let grade: Double
    /// Distance the fit spans, metres.
    public let spanMeters: Double
}

/// Live grade from altitude and distance (SPEC.md 3.6, F11).
///
/// A least-squares line through altitude against distance over the last
/// `windowMeters` of running (a streaming, trailing window; heuristic). The
/// distance is the caller's: the `CueEngine` integrates its pace estimate,
/// a caller may use GPS distance instead. Readings without a finite altitude
/// add nothing; after `maxAltitudeAgeSeconds` without one the grade is nil
/// and the cue engine falls back to flat targets (f = 1) and says so.
public struct GradeEstimator: Sendable {
    public let config: GradeEstimatorConfig
    public private(set) var estimate: GradeEstimate?

    private var samples: [(d: Double, a: Double)] = []
    private var lastAltitudeTime: Double?
    private var lastTime: Double?

    public init(config: GradeEstimatorConfig = GradeEstimatorConfig()) {
        self.config = config
    }

    public mutating func reset() { self = GradeEstimator(config: config) }

    /// Take one reading: its time, the distance run so far (metres) and its
    /// altitude (metres, nil when missing). Returns the grade after it, or nil
    /// when altitude is missing or there is not yet enough run to fit.
    @discardableResult
    public mutating func ingest(time: Double, distance: Double, altitude: Double?) -> GradeEstimate? {
        guard time.isFinite, lastTime.map({ time > $0 }) ?? true else { return estimate }
        lastTime = time
        if let a = altitude, a.isFinite, distance.isFinite {
            lastAltitudeTime = time
            if let last = samples.last, distance < last.d {
                // Distance went backwards (a reset): start over.
                samples.removeAll()
            }
            if samples.last.map({ distance - $0.d >= config.minSampleSpacingMeters }) ?? true {
                samples.append((distance, a))
                var drop = 0
                while drop < samples.count, distance - samples[drop].d > config.windowMeters { drop += 1 }
                if drop > 0 { samples.removeFirst(drop) }
            }
        }
        estimate = fit(at: time)
        return estimate
    }

    private func fit(at time: Double) -> GradeEstimate? {
        guard let seen = lastAltitudeTime, time - seen <= config.maxAltitudeAgeSeconds,
              samples.count >= config.minSamples,
              let first = samples.first, let last = samples.last,
              last.d - first.d >= config.minSpanMeters else { return nil }
        // Least squares in one pass, around the first sample's values for numerical safety.
        let d0 = first.d, a0 = first.a
        var sd = 0.0, sa = 0.0, sdd = 0.0, sda = 0.0
        for s in samples {
            let x = s.d - d0, y = s.a - a0
            sd += x; sa += y; sdd += x * x; sda += x * y
        }
        let n = Double(samples.count)
        let sxx = sdd - sd * sd / n
        let sxy = sda - sd * sa / n
        guard sxx > 1e-9 else { return nil }
        let slope = min(max(sxy / sxx, -config.maxAbsGrade), config.maxAbsGrade)
        return GradeEstimate(time: time, grade: slope, spanMeters: last.d - first.d)
    }
}
