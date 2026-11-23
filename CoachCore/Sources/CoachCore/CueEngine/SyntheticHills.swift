import Foundation

/// One stretch of a synthetic hilly route: how long and on what grade.
public struct GradeStretch: Equatable, Sendable {
    public var seconds: Double
    /// Grade as a fraction (0.05 = 5% uphill).
    public var grade: Double

    public init(seconds: Double, grade: Double) {
        self.seconds = seconds
        self.grade = grade
    }
}

extension SyntheticRun {
    /// A rolling route: climbs and descents alternate (starting with a
    /// seeded choice), each with a grade magnitude drawn uniformly from
    /// `gradeRange` and a length from `stretchSeconds`, until `totalSeconds`
    /// is covered. Synthetic test data only; the grade stream uses its own
    /// seeded generator so it does not disturb the run's noise stream.
    public static func rollingGrades(totalSeconds: Double, gradeRange: ClosedRange<Double> = 0.03...0.08,
                                     stretchSeconds: ClosedRange<Double> = 45...120,
                                     seed: UInt64) -> [GradeStretch] {
        var rng = SplitMix64(seed: seed ^ 0xA5A5_5A5A_1234_8765)
        var up = rng.unit() < 0.5
        var out: [GradeStretch] = []
        var covered = 0.0
        while covered < totalSeconds {
            let length = min(rng.uniform(stretchSeconds.lowerBound, stretchSeconds.upperBound), totalSeconds - covered)
            let g = rng.uniform(gradeRange.lowerBound, gradeRange.upperBound)
            out.append(GradeStretch(seconds: length, grade: up ? g : -g))
            covered += length
            up.toggle()
        }
        return out
    }

    /// A run in which the runner **holds the true grade-adjusted target pace**
    /// on every stretch: the true pace is the flat pace at `bandPosition`
    /// within `target` (0 = fast edge, 0.5 = middle, 1 = slow edge) times the
    /// curve's factor for that stretch's grade (3.6), so a climb really is on
    /// target and the true pace always lies inside the grade-adjusted band.
    /// Altitude truth follows the stretch grades (see `SyntheticSegment`).
    public static func holdingTarget(_ target: PaceTarget, bandPosition: Double = 0.5, stretches: [GradeStretch],
                                     curve: any GradePaceCurve = DefaultGradePaceCurve(), seed: UInt64,
                                     noise: SyntheticNoise = .forCueTests) -> SyntheticRun {
        let position = min(max(bandPosition, 0), 1)
        let flat = target.fastestSecondsPerKm + position * (target.slowestSecondsPerKm - target.fastestSecondsPerKm)
        let segments = stretches.map {
            SyntheticSegment(duration: $0.seconds, paceSecondsPerKm: flat * curve.factor(grade: $0.grade),
                             grade: $0.grade)
        }
        return SyntheticRun(segments: segments, seed: seed, noise: noise)
    }
}
