import Foundation

/// The tunable numbers for measuring pace at LTHR (SPEC.md 3.9 threshold
/// method, 3.2 LTHR). **Every default here is a heuristic**: none comes from a
/// study that measured it, none is a validated optimum, and none stands for a
/// particular runner. The runner's LTHR itself is never a default; it is passed
/// in from their own data (`LTHREstimator`).
public struct PaceAtLTHROptions: Equatable, Sendable {
    /// Heuristic: only runs that started in the last `lookbackDays` days
    /// (through `asOf`, both inclusive) count. Default 60, so the pace tracks
    /// current fitness while still reaching back past one training block.
    public var lookbackDays: Int
    /// Heuristic: a moment counts as "at LTHR" when heart rate is within this
    /// fraction of LTHR either side (inclusive). Default 0.03, so 97% to 103%
    /// of LTHR: about Friel's zone 4 top and zone 5a bottom (SPEC.md 3.2), and
    /// wide enough for beat-to-beat noise in a watch's reading.
    public var heartRateBandFraction: Double
    /// Heuristic: moving time skipped at the start of each stretch, because
    /// heart rate lags a change of effort for the first minutes, so early pace
    /// is faster than the heart rate says. Default 2 minutes (the same reason
    /// as `DecouplingOptions.warmUpSeconds`, over a shorter span because the
    /// runner is already warm when a stretch at LTHR starts).
    public var settleSeconds: Double
    /// Heuristic: the in-band moving time a stretch needs after the settling
    /// period. Default 8 minutes (so a stretch lasts at least 10), long enough
    /// for a tempo segment or a long cruise interval to count.
    public var minimumSeconds: Double
    /// Heuristic: heart rate may leave the band, or a reading may be missing,
    /// for up to this long without ending the stretch. Bridged time doesn't
    /// count toward the stretch's pace, heart rate or minimum. Default 15 s.
    public var maximumExcursionSeconds: Double
    /// Heuristic: after the settling period, at least this share of a
    /// stretch's moving time must be in the band (the rest is bridged
    /// excursions). Default 0.9.
    public var minimumInBandShare: Double
    /// Heuristic: the distance over which grade is measured along a stretch.
    /// Default 200 m: long enough that a meter or two of altimeter noise
    /// moves the grade by about 1% or less, short enough to catch a short hill.
    public var gradeWindowMeters: Double
    /// Heuristic: a stretch counts as flat when no grade window is steeper,
    /// up or down, than this fraction. Default 0.015 (1.5%). This stands in
    /// for grade-adjusted pace (SPEC.md 3.6, #18), which doesn't exist yet;
    /// once it does, hilly stretches can count at their grade-adjusted pace.
    public var maximumGrade: Double
    /// Heuristic: largest change in mean heart rate from the first to the
    /// second half of a stretch's used time, as a fraction of the first half.
    /// Default 0.02 (2%).
    public var maximumHeartRateDrift: Double
    /// Heuristic: largest change in mean pace from the first to the second
    /// half of a stretch's used time, as a fraction of the first half.
    /// Default 0.03 (3%).
    public var maximumPaceDrift: Double
    /// Heuristic: largest time-weighted coefficient of variation of speed over
    /// a stretch's used time, so surges (for example short reps whose average
    /// heart rate sits in the band) don't count as steady. Default
    /// `Decoupling.defaultMaximumSpeedCV`, the repo's existing steady-run limit.
    public var maximumSpeedCV: Double
    /// Each stream is carried forward from its last reading for at most this
    /// long (the `MovingTime` rule). Default `MovingTime.defaultMaximumHoldSeconds`.
    public var maximumHoldSeconds: Double
    /// Heart-rate readings outside this range are treated as missing.
    /// Default the decoupling range, `DecouplingOptions.default.plausibleHeartRate`.
    public var plausibleHeartRate: ClosedRange<Double>
    /// Speed readings outside this range are treated as missing.
    /// Default `BlendedPredictor.plausibleSpeed`.
    public var plausibleSpeed: ClosedRange<Double>

    public init(lookbackDays: Int = 60,
                heartRateBandFraction: Double = 0.03,
                settleSeconds: Double = 2 * 60,
                minimumSeconds: Double = 8 * 60,
                maximumExcursionSeconds: Double = 15,
                minimumInBandShare: Double = 0.9,
                gradeWindowMeters: Double = 200,
                maximumGrade: Double = 0.015,
                maximumHeartRateDrift: Double = 0.02,
                maximumPaceDrift: Double = 0.03,
                maximumSpeedCV: Double = Decoupling.defaultMaximumSpeedCV,
                maximumHoldSeconds: Double = MovingTime.defaultMaximumHoldSeconds,
                plausibleHeartRate: ClosedRange<Double> = DecouplingOptions.default.plausibleHeartRate,
                plausibleSpeed: ClosedRange<Double> = BlendedPredictor.plausibleSpeed) {
        self.lookbackDays = lookbackDays
        self.heartRateBandFraction = heartRateBandFraction
        self.settleSeconds = settleSeconds
        self.minimumSeconds = minimumSeconds
        self.maximumExcursionSeconds = maximumExcursionSeconds
        self.minimumInBandShare = minimumInBandShare
        self.gradeWindowMeters = gradeWindowMeters
        self.maximumGrade = maximumGrade
        self.maximumHeartRateDrift = maximumHeartRateDrift
        self.maximumPaceDrift = maximumPaceDrift
        self.maximumSpeedCV = maximumSpeedCV
        self.maximumHoldSeconds = maximumHoldSeconds
        self.plausibleHeartRate = plausibleHeartRate
        self.plausibleSpeed = plausibleSpeed
    }

    public static let `default` = PaceAtLTHROptions()

    /// Every number finite and in range: times and limits at least 0, the
    /// minimum and the grade window above 0, the band above 0 and under 1, the
    /// share within 0...1, and a positive lookback.
    public var isValid: Bool {
        let nonNegative = [settleSeconds, maximumExcursionSeconds, maximumGrade, maximumHeartRateDrift,
                           maximumPaceDrift, maximumSpeedCV, maximumHoldSeconds]
        let bounds = [plausibleHeartRate.lowerBound, plausibleHeartRate.upperBound,
                      plausibleSpeed.lowerBound, plausibleSpeed.upperBound]
        return lookbackDays > 0
            && nonNegative.allSatisfy { $0.isFinite && $0 >= 0 }
            && minimumSeconds.isFinite && minimumSeconds > 0
            && gradeWindowMeters.isFinite && gradeWindowMeters > 0
            && heartRateBandFraction.isFinite && heartRateBandFraction > 0 && heartRateBandFraction < 1
            && minimumInBandShare.isFinite && (0...1).contains(minimumInBandShare)
            && bounds.allSatisfy(\.isFinite) && plausibleSpeed.lowerBound > 0
    }
}
