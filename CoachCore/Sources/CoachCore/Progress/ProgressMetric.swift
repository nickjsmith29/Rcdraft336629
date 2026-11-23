import Foundation

// MARK: - Metric identity

/// The metrics on the F13 progress dashboard (SPEC.md F13).
public enum ProgressMetricID: Hashable, Sendable {
    /// Easy pace at a fixed heart rate, in seconds per kilometer. The heart
    /// rate is set once from the runner's current zones (or by the caller) and
    /// held fixed across the series, so the trend shows pace and not a moving target.
    case easyPace
    /// Typical aerobic decoupling of steady runs over 40 minutes (SPEC.md 3.3), in percent.
    /// Rated lower-is-better with a floor of 0 (`ProgressPolarity.lowerIsBetterWithFloor`):
    /// a negative value is usually a data artefact, so it rates as no drift.
    case longRunDecoupling
    /// Blended predicted race time for a distance in meters (SPEC.md 3.9), central value in seconds.
    case predictedTime(meters: Double)
    /// Resting heart rate, 7-day average in bpm (SPEC.md 3.4).
    case restingHeartRate
    /// HRV (SDNN), 7-day average in milliseconds (SPEC.md 3.4).
    case hrv
    /// Fastest stretch covering a distance in meters within the trailing window, in seconds.
    case bestEffort(meters: Double)
    /// Mean weekly moving time over the complete weeks before the snapshot, in seconds.
    case weeklyLoad
    /// Actual weekly moving time divided by planned, over the same weeks (1 = as planned).
    case loadVersusPlan
    /// Share of running time with heart rate below the easy ceiling (the top of zone 2), 0 to 1 (SPEC.md 3.1).
    case easyShare
    /// Mean cadence of runs in the complete weeks before the snapshot, steps per minute.
    case cadence

    /// A short plain name for the metric, for summaries, with an unnamed
    /// distance in km.
    public var name: String { name(units: .metric) }

    /// A short plain name for the metric, with an unnamed distance in
    /// `units` ("Best 3.0 km effort" or "Best 1.9 mi effort"); named
    /// distances (mile, 5K, half marathon...) read the same in both.
    public func name(units: UnitPreference) -> String {
        switch self {
        case .easyPace: return "Easy pace at a fixed heart rate"
        case .longRunDecoupling: return "Heart-rate drift on long runs"
        case .predictedTime(let m): return "Predicted \(Self.distanceName(m, units)) time"
        case .restingHeartRate: return "Resting heart rate (7-day average)"
        case .hrv: return "HRV (7-day average)"
        case .bestEffort(let m): return "Best \(Self.distanceName(m, units)) effort"
        case .weeklyLoad: return "Weekly running time"
        case .loadVersusPlan: return "Weekly load versus plan"
        case .easyShare: return "Easy-intensity share"
        case .cadence: return "Cadence"
        }
    }

    static func distanceName(_ meters: Double, _ units: UnitPreference = .metric) -> String {
        let named: [(Double, String)] = [(Distance.mile, "mile"), (Distance.fiveK, "5K"), (Distance.tenK, "10K"),
                                         (Distance.tenMiles, "10-mile"), (Distance.halfMarathon, "half marathon"),
                                         (Distance.marathon, "marathon")]
        if let hit = named.first(where: { abs($0.0 - meters) <= 0.005 * $0.0 }) { return hit.1 }
        return meters.isFinite ? UnitFormatting.distance(meters, units) : "unknown distance"
    }
}

/// The unit a metric's values are in.
public enum ProgressUnit: String, Equatable, Sendable {
    case secondsPerKilometer
    case percent
    case seconds
    case beatsPerMinute
    case milliseconds
    /// A ratio or a share, 0 to 1 for shares.
    case ratio
    case stepsPerMinute

    /// A short suffix for plain text, with pace per km.
    public var symbol: String { symbol(units: .metric) }

    /// A short suffix for plain text: pace is "s/km" or "s/mi" as `units` says.
    public func symbol(units: UnitPreference) -> String {
        switch self {
        case .secondsPerKilometer: return units == .metric ? "s/km" : "s/mi"
        case .percent: return "points"
        case .seconds: return "s"
        case .beatsPerMinute: return "bpm"
        case .milliseconds: return "ms"
        case .ratio: return ""
        case .stepsPerMinute: return "spm"
        }
    }
}

/// Which way is better for a metric.
public enum ProgressPolarity: Equatable, Sendable {
    /// Lower is better (pace in s/km, race times, resting HR).
    case lowerIsBetter
    /// Lower is better down to the floor; a value below it rates as the floor.
    /// Decoupling uses a floor of 0: heart rate rising less than pace over a
    /// steady run is no drift, and a negative value (heart rate falling against
    /// pace) is usually a data artefact, such as a strap settling in or a second
    /// half run downhill, not fitness better than no drift (heuristic, SPEC.md
    /// 3.3). Clamping was chosen over rating by distance from 0, which would
    /// call a move from 0 to -3 "worse" and word it as more drift. Only the
    /// rating uses the floor: `ChangeAssessment.delta` and the values shown stay as measured.
    case lowerIsBetterWithFloor(Double)
    /// Higher is better (HRV).
    case higherIsBetter
    /// Moving into the range, or closer to it, is better; any change inside it is no change.
    case towardRange(ClosedRange<Double>)
    /// Shown with its change, but never rated better or worse.
    case informational
}

/// How big a change must be before it counts (heuristic). A change counts
/// when its size is above `max(absolute, relative x |earlier value|)`.
public struct NoiseThreshold: Equatable, Sendable {
    public var absolute: Double
    /// Fraction of the earlier value, for example 0.02 for 2%.
    public var relative: Double

    public init(absolute: Double = 0, relative: Double = 0) {
        self.absolute = absolute
        self.relative = relative
    }

    /// The threshold for a change from `earlier`.
    public func threshold(from earlier: Double) -> Double {
        max(absolute, relative * abs(earlier))
    }

    var isValid: Bool { absolute.isFinite && relative.isFinite && absolute >= 0 && relative >= 0 }
}

// MARK: - Points

/// What a value was computed from (F13: every value cites the runs or days it came from).
public struct ProgressEvidence: Equatable, Sendable {
    /// Activity ids of the runs, in a stable order.
    public let activityIDs: [String]
    /// Calendar days (00:00 in the runner's time zone) of daily readings, oldest first.
    public let days: [Date]
    /// Ids of planned sessions (weekly load versus plan only).
    public let plannedWorkoutIDs: [String]

    public init(activityIDs: [String] = [], days: [Date] = [], plannedWorkoutIDs: [String] = []) {
        self.activityIDs = activityIDs
        self.days = days
        self.plannedWorkoutIDs = plannedWorkoutIDs
    }

    public static let none = ProgressEvidence()

    public var isEmpty: Bool { activityIDs.isEmpty && days.isEmpty && plannedWorkoutIDs.isEmpty }

    /// Both sets of evidence, without repeats, in this one's order first.
    public func merged(with other: ProgressEvidence) -> ProgressEvidence {
        ProgressEvidence(activityIDs: baselineOrderedUnique(activityIDs + other.activityIDs),
                         days: Array(Set(days + other.days)).sorted(),
                         plannedWorkoutIDs: baselineOrderedUnique(plannedWorkoutIDs + other.plannedWorkoutIDs))
    }
}

/// Why a point of a series has no value.
public enum ProgressGap: Equatable, Sendable {
    /// The baseline for that date couldn't produce the value; the reason (and
    /// any excluded runs) come from `BaselineBuilder`.
    case insufficient(InsufficientData)
    /// None of the complete weeks before the snapshot has a planned session
    /// with volume (weekly load versus plan).
    case noPlannedSessions
    /// A planned session in those weeks has a missing or invalid duration.
    case plannedVolumeUnknown
    /// The blended predictor had no method with enough data; why each was skipped.
    case noPrediction(skipped: [SkippedMethod])
    /// Runs in the window had distance streams, but none covered this distance.
    case noEffortAtDistance

    static func baseline(_ reason: InsufficientReason) -> ProgressGap { .insufficient(InsufficientData(reason)) }
}

/// A value, or why there is none.
public enum ProgressReading: Equatable, Sendable {
    case value(Double)
    case missing(ProgressGap)
}

/// One point of a metric's weekly series: the value as of a date.
public struct ProgressPoint: Equatable, Sendable {
    public let asOf: Date
    public let reading: ProgressReading
    /// A reference band shown with the value: the predicted range for race
    /// times (SPEC.md 3.9 shows a range, not one number) and the 60-day
    /// normal range for resting HR and HRV (SPEC.md 3.4). nil otherwise.
    public let band: ClosedRange<Double>?
    public let evidence: ProgressEvidence

    public init(asOf: Date, reading: ProgressReading, band: ClosedRange<Double>? = nil,
                evidence: ProgressEvidence = .none) {
        self.asOf = asOf
        // A value that isn't finite is never shown; it reads as invalid input.
        if case .value(let v) = reading, !v.isFinite {
            self.reading = .missing(.baseline(.invalidInput))
        } else {
            self.reading = reading
        }
        self.band = band
        self.evidence = evidence
    }

    public var value: Double? {
        if case .value(let v) = reading { return v }
        return nil
    }

    public var gap: ProgressGap? {
        if case .missing(let g) = reading { return g }
        return nil
    }
}

// MARK: - Change

public enum ChangeDirection: Equatable, Sendable {
    case improving
    case worse
    /// The change is within the noise threshold (heuristic).
    case noChange
    /// The metric is informational (`ProgressPolarity.informational`).
    case notRated
}

/// A measured change between two points.
public struct ChangeAssessment: Equatable, Sendable {
    public let earlier: Double
    public let latest: Double
    /// Latest value minus the earlier one, in the metric's unit.
    public let delta: Double
    /// The amount that was rated, signed so that positive is better: `-delta`
    /// when lower is better (after raising both values to the floor, for
    /// `lowerIsBetterWithFloor`), `delta` when higher is better, and for a target
    /// range the drop in distance from the range (so a value that crosses the
    /// range from 5 below to 5 above has a gain of 0, whatever its delta). 0
    /// for informational metrics. Compared with `threshold`.
    public let gain: Double
    /// The noise threshold the gain was compared with.
    public let threshold: Double
    public let direction: ChangeDirection
    /// The target range for `ProgressPolarity.towardRange`, else nil.
    public let target: ClosedRange<Double>?
    /// The floor for `ProgressPolarity.lowerIsBetterWithFloor`, else nil.
    public let floor: Double?

    public init(earlier: Double, latest: Double, gain: Double, threshold: Double,
                direction: ChangeDirection, target: ClosedRange<Double>? = nil, floor: Double? = nil) {
        self.earlier = earlier
        self.latest = latest
        self.delta = latest - earlier
        self.gain = gain
        self.threshold = threshold
        self.direction = direction
        self.target = target
        self.floor = floor
    }

    /// Where the earlier value sits against the target range, or nil without one (or for NaN).
    public var earlierPosition: RangePosition? { earlier.isNaN ? nil : target.map { RangePosition.of(earlier, in: $0) } }
    /// Where the latest value sits against the target range, or nil without one (or for NaN).
    public var latestPosition: RangePosition? { latest.isNaN ? nil : target.map { RangePosition.of(latest, in: $0) } }

    /// True when the value went from below the target range to above it, or
    /// the reverse. Such a change can be rated "no change" (the same distance
    /// on the other side), so the summaries say it crossed.
    public var crossedTarget: Bool {
        switch (earlierPosition, latestPosition) {
        case (.below?, .above?), (.above?, .below?): return true
        default: return false
        }
    }

    /// True when the floor changed the rating: either value is below it.
    public var belowFloor: Bool {
        guard let floor else { return false }
        return earlier < floor || latest < floor
    }

    /// Distance from `value` to `range` (0 inside it; NaN for NaN, so a
    /// missing value never reads as on target).
    public static func distance(_ value: Double, from range: ClosedRange<Double>) -> Double {
        if value.isNaN { return value }
        return value < range.lowerBound ? range.lowerBound - value : (value > range.upperBound ? value - range.upperBound : 0)
    }
}

/// Where a value sits against a target range.
public enum RangePosition: Equatable, Sendable {
    case below
    case within
    case above

    public static func of(_ value: Double, in range: ClosedRange<Double>) -> RangePosition {
        value < range.lowerBound ? .below : (value > range.upperBound ? .above : .within)
    }
}

/// Why a change couldn't be measured.
public enum ChangeGap: Equatable, Sendable {
    case latestMissing(ProgressGap)
    case earlierMissing(ProgressGap)
    /// The dashboard's series doesn't cover that many weeks (or the span is below 1).
    case notInSeries
}

public enum ChangeOutcome: Equatable, Sendable {
    case measured(ChangeAssessment)
    case unavailable(ChangeGap)
}

/// The change of a metric over `weeks` weeks: the latest point against the
/// point `weeks` weeks earlier in the series.
public struct ProgressChange: Equatable, Sendable {
    public let weeks: Int
    public let earlier: ProgressPoint?
    public let latest: ProgressPoint?
    public let outcome: ChangeOutcome

    public var direction: ChangeDirection? {
        if case .measured(let a) = outcome { return a.direction }
        return nil
    }

    /// Latest minus earlier, when measured.
    public var delta: Double? {
        if case .measured(let a) = outcome { return a.delta }
        return nil
    }

    /// The evidence of both points.
    public var evidence: ProgressEvidence {
        (latest?.evidence ?? .none).merged(with: earlier?.evidence ?? .none)
    }

    /// Relative tolerance for comparing a gain with its noise threshold. A gain
    /// within `relativeTolerance x max(1, |earlier|, |latest|)` of the threshold
    /// counts as at the threshold, so as no change. Without it a gain that lands
    /// exactly on the threshold (easy share 73% to 75% against a 2-point
    /// threshold) is rated by floating-point rounding. 1e-9 is far above the
    /// rounding of these sums and far below any change a watch can measure.
    public static let relativeTolerance = 1e-9

    /// Rates a change from `earlier` to `latest` (heuristic noise threshold).
    /// A gain at the threshold, within `relativeTolerance`, is no change.
    public static func assess(earlier: Double, latest: Double,
                              polarity: ProgressPolarity, noise: NoiseThreshold) -> ChangeAssessment {
        let delta = latest - earlier
        let threshold = noise.threshold(from: earlier)
        let gain: Double
        var target: ClosedRange<Double>?
        var floor: Double?
        switch polarity {
        case .lowerIsBetter: gain = -delta
        case .lowerIsBetterWithFloor(let f):
            if f.isFinite {
                floor = f
                // `max` drops a NaN, which would rate a missing value as the floor.
                func raised(_ v: Double) -> Double { v.isNaN ? v : max(v, f) }
                gain = raised(earlier) - raised(latest)
            } else {
                gain = -delta
            }
        case .higherIsBetter: gain = delta
        case .towardRange(let range):
            target = range
            gain = ChangeAssessment.distance(earlier, from: range) - ChangeAssessment.distance(latest, from: range)
        case .informational: gain = 0
        }
        let direction: ChangeDirection
        if case .informational = polarity {
            direction = .notRated
        } else {
            let limit = threshold + relativeTolerance * max(1, abs(earlier), abs(latest))
            direction = gain > limit ? .improving : (gain < -limit ? .worse : .noChange)
        }
        return ChangeAssessment(earlier: earlier, latest: latest, gain: gain, threshold: threshold,
                                direction: direction, target: target, floor: floor)
    }
}

// MARK: - Metric

/// One dashboard card's data: a weekly series (the trend line) and its changes.
public struct ProgressMetric: Equatable, Sendable {
    public let id: ProgressMetricID
    public let unit: ProgressUnit
    public let polarity: ProgressPolarity
    public let noise: NoiseThreshold
    /// One point a week, oldest first; the last is the current value.
    public let series: [ProgressPoint]
    /// The change spans the dashboard reports (`ProgressOptions.changeWeeks`).
    public let changeWeeks: [Int]

    public init(id: ProgressMetricID, unit: ProgressUnit, polarity: ProgressPolarity, noise: NoiseThreshold,
                series: [ProgressPoint], changeWeeks: [Int]) {
        self.id = id
        self.unit = unit
        self.polarity = polarity
        self.noise = noise
        self.series = series
        self.changeWeeks = changeWeeks
    }

    public var latest: ProgressPoint? { series.last }

    /// Changes over each of `changeWeeks` (4 and 12 by default).
    public var changes: [ProgressChange] { changeWeeks.map { change(overWeeks: $0) } }

    /// The latest point against the point `weeks` weeks earlier.
    public func change(overWeeks weeks: Int) -> ProgressChange {
        guard let latest = series.last else {
            return ProgressChange(weeks: weeks, earlier: nil, latest: nil, outcome: .unavailable(.notInSeries))
        }
        guard weeks >= 1, weeks < series.count else {
            return ProgressChange(weeks: weeks, earlier: nil, latest: latest, outcome: .unavailable(.notInSeries))
        }
        let earlier = series[series.count - 1 - weeks]
        let outcome: ChangeOutcome
        switch (earlier.reading, latest.reading) {
        case (_, .missing(let gap)): outcome = .unavailable(.latestMissing(gap))
        case (.missing(let gap), _): outcome = .unavailable(.earlierMissing(gap))
        case (.value(let a), .value(let b)):
            outcome = .measured(ProgressChange.assess(earlier: a, latest: b, polarity: polarity, noise: noise))
        }
        return ProgressChange(weeks: weeks, earlier: earlier, latest: latest, outcome: outcome)
    }
}
